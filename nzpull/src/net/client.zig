//! Concurrent download engine.
//!
//! v1 model: a pool of N worker threads, each owning one NNTP connection, pulling
//! segments from a shared lock-free-ish work queue. Each worker *pipelines* up to
//! `pipeline_depth` BODY commands before reading the responses in order — the key
//! throughput win over nzbget's one-command-at-a-time connections. Articles are
//! fetched by Message-ID (no GROUP needed), SIMD-decoded, and written at offset.
//!
//! This blocking-socket-with-pipelining design is the first increment; the planned
//! evolution is a single io_uring event loop driving all sockets (see README).

const std = @import("std");
const model = @import("../nzb/model.zig");
const nntp = @import("nntp.zig");
const transport = @import("transport.zig");
const yenc = @import("../codec/yenc.zig");
const writer = @import("../io/writer.zig");
const build_options = @import("build_options");

pub const ServerConfig = struct {
    host: []const u8,
    port: u16 = 119,
    user: ?[]const u8 = null,
    pass: ?[]const u8 = null,
    tls: bool = false,
    connections: u32 = 8,
    pipeline_depth: u32 = 4,
};

pub const Stats = struct {
    segments_ok: u64 = 0,
    segments_failed: u64 = 0,
    bytes_written: u64 = 0,
    crc_errors: u64 = 0,
};

const Job = struct {
    file_index: u32,
    message_id: []const u8,
};

const Shared = struct {
    gpa: std.mem.Allocator,
    cfg: ServerConfig,
    jobs: []const Job,
    next: std.atomic.Value(usize) = .init(0),
    outputs: []writer.OutputFile,
    stats_mtx: std.Thread.Mutex = .{},
    stats: Stats = .{},
    first_error: ?anyerror = null,

    fn pull(self: *Shared) ?Job {
        const i = self.next.fetchAdd(1, .monotonic);
        if (i >= self.jobs.len) return null;
        return self.jobs[i];
    }

    fn record(self: *Shared, delta: Stats) void {
        self.stats_mtx.lock();
        defer self.stats_mtx.unlock();
        self.stats.segments_ok += delta.segments_ok;
        self.stats.segments_failed += delta.segments_failed;
        self.stats.bytes_written += delta.bytes_written;
        self.stats.crc_errors += delta.crc_errors;
    }

    fn noteError(self: *Shared, err: anyerror) void {
        self.stats_mtx.lock();
        defer self.stats_mtx.unlock();
        if (self.first_error == null) self.first_error = err;
    }
};

pub fn download(
    gpa: std.mem.Allocator,
    nzb: model.Nzb,
    out_dir: std.fs.Dir,
    cfg: ServerConfig,
) !Stats {
    // Build output files (one per NZB file) and a flat job list.
    var outputs = try gpa.alloc(writer.OutputFile, nzb.files.len);
    defer gpa.free(outputs);
    var opened: usize = 0;
    errdefer for (outputs[0..opened]) |*o| o.finalize();

    var jobs: std.ArrayList(Job) = .empty;
    defer jobs.deinit(gpa);

    var name_buf: [512]u8 = undefined;
    for (nzb.files, 0..) |f, fi| {
        const name = writer.sanitizeName(&name_buf, f.fileName());
        outputs[fi] = try writer.OutputFile.create(out_dir, name);
        opened += 1;
        for (f.segments) |s| {
            try jobs.append(gpa, .{ .file_index = @intCast(fi), .message_id = s.message_id });
        }
    }

    var shared = Shared{
        .gpa = gpa,
        .cfg = cfg,
        .jobs = jobs.items,
        .outputs = outputs,
    };

    const n_threads = @max(1, cfg.connections);
    const threads = try gpa.alloc(std.Thread, n_threads);
    defer gpa.free(threads);

    var spawned: usize = 0;
    for (0..n_threads) |_| {
        threads[spawned] = std.Thread.spawn(.{}, worker, .{&shared}) catch break;
        spawned += 1;
    }
    for (threads[0..spawned]) |t| t.join();

    for (outputs) |*o| o.finalize();

    if (shared.first_error) |err| {
        // Surface connection-level failures, but only if nothing succeeded.
        if (shared.stats.segments_ok == 0) return err;
    }
    return shared.stats;
}

fn worker(shared: *Shared) void {
    runWorker(shared) catch |err| shared.noteError(err);
}

fn runWorker(shared: *Shared) !void {
    const gpa = shared.gpa;
    const cfg = shared.cfg;

    // Establish the connection + transport.
    var tcp: ?*transport.TcpTransport = null;
    var tls: ?*transport.TlsTransport = null;
    defer if (tcp) |t| t.deinit(gpa);
    defer if (tls) |t| t.deinit(gpa);

    var io: nntp.IoStream = undefined;
    if (cfg.tls) {
        const t = try transport.TlsTransport.connect(gpa, cfg.host, cfg.port);
        tls = t;
        io = t.ioStream();
    } else {
        const t = try transport.TcpTransport.connect(gpa, cfg.host, cfg.port);
        tcp = t;
        io = t.ioStream();
    }

    var conn = nntp.Connection.init(io);
    try conn.readGreeting();
    if (cfg.user) |u| try conn.authenticate(u, cfg.pass orelse "");
    defer conn.quit();

    const depth = @max(1, cfg.pipeline_depth);
    var batch = try gpa.alloc(Job, depth);
    defer gpa.free(batch);

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(gpa);

    while (true) {
        // Fill a pipeline batch.
        var n: usize = 0;
        while (n < depth) : (n += 1) {
            batch[n] = shared.pull() orelse break;
        }
        if (n == 0) break;

        // Write phase: issue all BODY commands back-to-back.
        for (batch[0..n]) |job| try conn.sendBody(job.message_id);

        // Read phase: consume responses in order.
        for (batch[0..n]) |job| {
            raw.clearRetainingCapacity();
            const status = try conn.readBody(gpa, &raw);
            if (status != .ok) {
                shared.record(.{ .segments_failed = 1 });
                continue;
            }
            decoded.clearRetainingCapacity();
            const res = try yenc.decodeBody(gpa, raw.items, &decoded);
            if (!res.crcOk()) {
                shared.record(.{ .segments_failed = 1, .crc_errors = 1 });
                continue;
            }
            try shared.outputs[job.file_index].writeAt(res.fileOffset(), decoded.items);
            shared.record(.{ .segments_ok = 1, .bytes_written = res.bytes_written });
        }
    }
}
