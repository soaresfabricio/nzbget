//! io_uring download engine (Linux, TCP only).
//!
//! One thread runs a single io_uring loop driving all connections; yEnc decode +
//! CRC + disk write are offloaded to a `DecodePool`. Each connection keeps up to
//! `pipeline_depth` BODY requests in flight. The connect + AUTHINFO handshake is
//! done synchronously per connection (rare, sequential), after which the bare
//! socket fd is driven by the loop. Backpressure: when the buffer pool is empty a
//! connection pauses reads until a decode worker frees a buffer (eventfd wakeup).
//!
//! TLS is not supported here — callers route --tls to the thread engine.

const std = @import("std");
const posix = std.posix;
const model = @import("../nzb/model.zig");
const nntp = @import("nntp.zig");
const transport = @import("transport.zig");
const client = @import("client.zig");
const eventloop = @import("eventloop.zig");
const async_conn = @import("async_conn.zig");
const decode_pool = @import("decode_pool.zig");
const bufpool = @import("../util/bufpool.zig");

const ServerConfig = client.ServerConfig;
const Stats = client.Stats;
const AsyncConn = async_conn.AsyncConn;

const recv_size = 256 * 1024;
const kind_recv: u64 = 0;
const kind_send: u64 = 1;
const eventfd_ud: u64 = std.math.maxInt(u64);

fn ud(ci: usize, kind: u64) u64 {
    return (@as(u64, ci) << 2) | kind;
}

const ConnState = struct {
    fd: posix.fd_t,
    ac: AsyncConn,
    send_buf: std.ArrayList(u8) = .empty,
    send_off: usize = 0,
    sending: bool = false,
    recving: bool = false,
    recv_paused: bool = false, // waiting on a free buffer
    closed: bool = false,
    recv_buf: [recv_size]u8 = undefined,
};

const Engine = struct {
    gpa: std.mem.Allocator,
    loop: *eventloop.Loop,
    pool: *bufpool.BufPool,
    dpool: *decode_pool.DecodePool,
    conns: []ConnState,
    jobs: []const client.Job,
    next_job: usize = 0,
    depth: usize,
    open_conns: usize,
    evt: eventloop.EventFd,
    evt_buf: [8]u8 = undefined,
    completed: std.ArrayList(async_conn.Completed) = .empty,
    not_found: u64 = 0,
    conn_drop_failed: u64 = 0,
    wake_flag: *std.atomic.Value(bool),

    fn nextJob(self: *Engine) ?client.Job {
        if (self.next_job >= self.jobs.len) return null;
        defer self.next_job += 1;
        return self.jobs[self.next_job];
    }

    fn armEventFd(self: *Engine) !void {
        try self.loop.recv(eventfd_ud, self.evt.fd, &self.evt_buf);
    }

    /// Keep a connection's pipeline full and a recv outstanding; close it when its
    /// work is fully drained.
    fn service(self: *Engine, ci: usize) !void {
        const c = &self.conns[ci];
        if (c.closed) return;

        // Refill the request window.
        if (!c.sending) {
            c.send_buf.clearRetainingCapacity();
            var added: usize = 0;
            while (c.ac.inFlight() < self.depth) {
                const job = self.nextJob() orelse break;
                try c.send_buf.writer(self.gpa).print("BODY <{s}>\r\n", .{job.message_id});
                try c.ac.pushRequest(job.file_index);
                added += 1;
            }
            if (added > 0) {
                c.send_off = 0;
                c.sending = true;
                try self.loop.send(ud(ci, kind_send), c.fd, c.send_buf.items);
            }
        }

        // Keep a recv outstanding whenever we expect response bytes.
        if (!c.recving and !c.recv_paused and c.ac.inFlight() > 0) {
            c.recving = true;
            try self.loop.recv(ud(ci, kind_recv), c.fd, &c.recv_buf);
        }

        // Fully drained: nothing in flight, nothing to send, no jobs left.
        if (!c.sending and !c.recving and c.ac.inFlight() == 0 and self.next_job >= self.jobs.len) {
            posix.close(c.fd);
            c.closed = true;
            self.open_conns -= 1;
        }
    }

    fn dropConn(self: *Engine, ci: usize) void {
        const c = &self.conns[ci];
        if (c.closed) return;
        // Any still-outstanding requests are lost.
        self.conn_drop_failed += c.ac.inFlight();
        posix.close(c.fd);
        c.closed = true;
        self.open_conns -= 1;
    }

    fn drainCompleted(self: *Engine) void {
        for (self.completed.items) |comp| {
            self.dpool.submit(.{ .raw = comp.raw, .file_index = comp.file_index });
        }
        self.completed.clearRetainingCapacity();
    }

    /// Recompute whether any connection is paused and publish it so decode workers
    /// know whether they must wake the loop.
    fn updateWakeFlag(self: *Engine) void {
        var any = false;
        for (self.conns) |*c| {
            if (!c.closed and c.recv_paused) {
                any = true;
                break;
            }
        }
        self.wake_flag.store(any, .release);
    }

    fn handle(self: *Engine, cqe: eventloop.Cqe) !void {
        if (cqe.user_data == eventfd_ud) {
            try self.armEventFd();
            // A buffer may have freed up: resume paused connections, then service all.
            for (self.conns, 0..) |*c, ci| {
                if (c.closed) continue;
                if (c.recv_paused) {
                    try c.ac.resume_(self.pool, &self.completed, &self.not_found);
                    self.drainCompleted();
                    if (!c.ac.isBlocked()) c.recv_paused = false;
                }
                try self.service(ci);
            }
            self.updateWakeFlag();
            return;
        }

        const ci: usize = @intCast(cqe.user_data >> 2);
        const kind = cqe.user_data & 3;
        const c = &self.conns[ci];
        if (c.closed) return;

        if (kind == kind_recv) {
            c.recving = false;
            if (cqe.res <= 0) {
                self.dropConn(ci);
                return;
            }
            const n: usize = @intCast(cqe.res);
            try c.ac.onBytes(self.pool, c.recv_buf[0..n], &self.completed, &self.not_found);
            self.drainCompleted();
            if (c.ac.isBlocked()) {
                c.recv_paused = true;
                self.wake_flag.store(true, .release);
                // Immediately retry once: a worker may have freed a buffer in the
                // window between the failed acquire and setting the flag.
                try c.ac.resume_(self.pool, &self.completed, &self.not_found);
                self.drainCompleted();
                if (!c.ac.isBlocked()) {
                    c.recv_paused = false;
                    self.updateWakeFlag();
                }
            }
            try self.service(ci);
        } else { // kind_send
            if (cqe.res <= 0) {
                self.dropConn(ci);
                return;
            }
            const sent = c.send_off + @as(usize, @intCast(cqe.res));
            if (sent < c.send_buf.items.len) {
                // Short send: queue the remainder.
                c.send_off = sent;
                try self.loop.send(ud(ci, kind_send), c.fd, c.send_buf.items[sent..]);
            } else {
                c.sending = false;
                try self.service(ci);
            }
        }
    }
};

/// Connect + greet + authenticate synchronously, returning the bare socket fd and
/// any bytes already buffered past the handshake.
fn handshake(gpa: std.mem.Allocator, cfg: ServerConfig, leftover_out: *std.ArrayList(u8)) !posix.fd_t {
    const t = try transport.TcpTransport.connect(gpa, cfg.host, cfg.port);
    var ok = false;
    defer if (!ok) t.deinit(gpa);

    var conn = nntp.Connection.init(t.ioStream());
    try conn.readGreeting();
    if (cfg.user) |u| try conn.authenticate(u, cfg.pass orelse "");
    try leftover_out.appendSlice(gpa, conn.leftover());
    ok = true;
    return t.detach(gpa);
}

pub fn download(
    gpa: std.mem.Allocator,
    nzb: model.Nzb,
    out_dir: std.fs.Dir,
    cfg: ServerConfig,
) !Stats {
    var targets = try client.prepareTargets(gpa, nzb, out_dir);
    defer targets.deinit(gpa);
    errdefer targets.finalize();

    const n_conns = @max(1, cfg.connections);
    const depth = @max(1, cfg.pipeline_depth);

    var loop = try eventloop.Loop.init(256);
    defer loop.deinit();

    const evt = try eventloop.EventFd.init();
    defer evt.deinit();

    // Bound outstanding raw buffers: one per connection mid-body plus a decode
    // backlog. This is the memory cap and the backpressure point.
    var pool = bufpool.BufPool.init(gpa, n_conns + 2 * n_conns * depth);
    defer pool.deinit();

    var wake = std.atomic.Value(bool).init(false);

    const cpu = std.Thread.getCpuCount() catch 4;
    const n_workers = @max(1, cpu -| 1);
    const dpool = try decode_pool.DecodePool.init(gpa, targets.outputs, &pool, evt, &wake, n_workers);
    defer dpool.deinit();

    var conns = try gpa.alloc(ConnState, n_conns);
    defer gpa.free(conns);

    var engine = Engine{
        .gpa = gpa,
        .loop = &loop,
        .pool = &pool,
        .dpool = dpool,
        .conns = conns,
        .jobs = targets.jobs,
        .depth = depth,
        .open_conns = 0,
        .evt = evt,
        .wake_flag = &wake,
    };
    defer engine.completed.deinit(gpa);

    // Establish connections (synchronous handshake), seed any leftover bytes.
    var established: usize = 0;
    errdefer for (conns[0..established]) |*c| {
        if (!c.closed) posix.close(c.fd);
        c.ac.deinit();
        c.send_buf.deinit(gpa);
    };
    for (conns) |*c| {
        var leftover: std.ArrayList(u8) = .empty;
        defer leftover.deinit(gpa);
        const fd = handshake(gpa, cfg, &leftover) catch break;
        c.* = .{ .fd = fd, .ac = AsyncConn.init(gpa) };
        if (leftover.items.len > 0) {
            try c.ac.onBytes(&pool, leftover.items, &engine.completed, &engine.not_found);
            engine.drainCompleted();
        }
        established += 1;
        engine.open_conns += 1;
    }
    if (established == 0) return error.ConnectFailed;

    // Prime the loop: arm the eventfd and fill each connection's window.
    try engine.armEventFd();
    for (0..established) |ci| try engine.service(ci);

    var cqes: [256]eventloop.Cqe = undefined;
    while (engine.open_conns > 0) {
        const n = try loop.submitAndReap(&cqes);
        for (cqes[0..n]) |cqe| try engine.handle(cqe);
    }

    // Wait for the decode pool to finish writing before finalizing.
    while (!dpool.idle()) std.Thread.yield() catch {};

    for (conns[0..established]) |*c| {
        c.ac.deinit();
        c.send_buf.deinit(gpa);
    }

    targets.finalize();

    var stats = dpool.snapshot();
    stats.segments_failed += engine.not_found + engine.conn_drop_failed;
    return stats;
}
