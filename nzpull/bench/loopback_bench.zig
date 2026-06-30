//! Loopback network benchmark: an in-process TCP NNTP server serves a canned
//! yEnc article for every BODY request; we run both the thread engine and the
//! io_uring engine at varying connection counts and report MiB/s + segments/s.
//!
//! This isolates the engine (network loop + pipelining + decode offload) from any
//! real network, so the numbers reflect per-op overhead and concurrency scaling.

const std = @import("std");
const nzpull = @import("nzpull");

const seg_len = 512 * 1024;
const n_segs = 512; // ~256 MiB decoded per run

var g_payload: []u8 = undefined; // canned "222..\r\n" + body + ".\r\n"

fn buildPayload(gpa: std.mem.Allocator) !void {
    const data = try gpa.alloc(u8, seg_len);
    defer gpa.free(data);
    var rng = std.Random.DefaultPrng.init(0xABCD);
    rng.random().bytes(data);

    var p: std.ArrayList(u8) = .empty;
    const w = p.writer(gpa);
    try w.writeAll("222 0 body follows\r\n");
    try w.print("=ybegin line=128 size={d} name=b.bin\r\n", .{seg_len});
    var line: [600]u8 = undefined;
    var n: usize = 0;
    for (data) |b| {
        const e = b +% 42;
        if (e == 0 or e == '\r' or e == '\n' or e == '=') {
            line[n] = '=';
            line[n + 1] = e +% 64;
            n += 2;
        } else {
            line[n] = e;
            n += 1;
        }
        if (n >= 128) {
            try emitLine(w, line[0..n]);
            n = 0;
        }
    }
    if (n > 0) try emitLine(w, line[0..n]);
    try w.print("=yend size={d} crc32={x:0>8}\r\n.\r\n", .{ seg_len, nzpull.crc32.hash(data) });
    g_payload = try p.toOwnedSlice(gpa);
}

fn emitLine(w: anytype, line: []const u8) !void {
    if (line.len > 0 and line[0] == '.') try w.writeAll(".");
    try w.writeAll(line);
    try w.writeAll("\r\n");
}

const Server = struct {
    gpa: std.mem.Allocator,
    listener: std.net.Server,
    stop: std.atomic.Value(bool) = .init(false),

    fn run(self: *Server) void {
        while (!self.stop.load(.acquire)) {
            const conn = self.listener.accept() catch return;
            const t = std.Thread.spawn(.{}, handle, .{ self, conn.stream }) catch {
                conn.stream.close();
                continue;
            };
            t.detach();
        }
    }

    fn handle(self: *Server, stream: std.net.Stream) void {
        defer stream.close();
        stream.writeAll("200 welcome\r\n") catch return;
        var buf: [16 * 1024]u8 = undefined;
        var acc: std.ArrayList(u8) = .empty;
        defer acc.deinit(self.gpa);
        while (true) {
            const n = stream.read(&buf) catch return;
            if (n == 0) return;
            acc.appendSlice(self.gpa, buf[0..n]) catch return;
            while (std.mem.indexOf(u8, acc.items, "\r\n")) |nl| {
                const line = acc.items[0..nl];
                if (std.mem.startsWith(u8, line, "BODY ")) {
                    stream.writeAll(g_payload) catch return;
                } else if (std.mem.startsWith(u8, line, "AUTHINFO USER")) {
                    stream.writeAll("381 pass\r\n") catch return;
                } else if (std.mem.startsWith(u8, line, "AUTHINFO PASS")) {
                    stream.writeAll("281 ok\r\n") catch return;
                }
                const rem = acc.items.len - (nl + 2);
                std.mem.copyForwards(u8, acc.items[0..rem], acc.items[nl + 2 ..]);
                acc.items.len = rem;
            }
        }
    }
};

fn makeNzb(gpa: std.mem.Allocator) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    const w = b.writer(gpa);
    try w.writeAll("<?xml version=\"1.0\"?>\n<nzb>\n  <file subject=\"&quot;bench.bin&quot;\">\n    <groups><group>g</group></groups>\n    <segments>\n");
    for (0..n_segs) |i| {
        try w.print("      <segment bytes=\"700000\" number=\"{d}\">s{d}@t</segment>\n", .{ i + 1, i });
    }
    try w.writeAll("    </segments>\n  </file>\n</nzb>\n");
    return b.toOwnedSlice(gpa);
}

fn runEngine(gpa: std.mem.Allocator, comptime iouring: bool, nzb_text: []const u8, port: u16, conns: u32, depth: u32, o: anytype) !void {
    var nzb = try nzpull.parser.parse(gpa, nzb_text);
    defer nzb.deinit();

    var tmp = try std.fs.cwd().makeOpenPath(".bench_out", .{});
    defer tmp.close();

    const cfg = nzpull.client.ServerConfig{
        .host = "127.0.0.1",
        .port = port,
        .user = "u",
        .pass = "p",
        .connections = conns,
        .pipeline_depth = depth,
    };

    var timer = try std.time.Timer.start();
    const stats = if (iouring)
        try nzpull.io_engine.download(gpa, nzb, tmp, cfg)
    else
        try nzpull.client.download(gpa, nzb, tmp, cfg);
    const secs = @as(f64, @floatFromInt(timer.read())) / 1e9;

    const mib = @as(f64, @floatFromInt(stats.bytes_written)) / (1024.0 * 1024.0);
    try o.print("  {s:<8} conns={d:<3} depth={d}: {d:8.1} MiB/s  {d:8.0} seg/s  (ok={d} fail={d})\n", .{
        if (iouring) "iouring" else "threads",
        conns,
        depth,
        mib / secs,
        @as(f64, @floatFromInt(stats.segments_ok)) / secs,
        stats.segments_ok,
        stats.segments_failed,
    });
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const stdout = std.fs.File.stdout();
    var ob: [4096]u8 = undefined;
    var fw = stdout.writer(&ob);
    const o = &fw.interface;

    try buildPayload(gpa);
    defer gpa.free(g_payload);
    const nzb_text = try makeNzb(gpa);
    defer gpa.free(nzb_text);

    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = Server{ .gpa = gpa, .listener = try addr.listen(.{ .reuse_address = true }) };
    const port = server.listener.listen_address.getPort();
    const srv_thread = try std.Thread.spawn(.{}, Server.run, .{&server});
    // The accept loop dies with the process; don't join (accept() won't unblock).
    srv_thread.detach();

    const have_iouring = blk: {
        var p = nzpull.eventloop.Loop.init(8) catch break :blk false;
        p.deinit();
        break :blk true;
    };

    try o.print("NZpull loopback benchmark  ({d} segs x {d} KiB = {d} MiB)\n", .{
        n_segs, seg_len / 1024, n_segs * seg_len / (1024 * 1024),
    });
    try o.flush();

    const configs = [_][2]u32{ .{ 16, 8 }, .{ 64, 8 } };
    for (configs) |c| {
        try runEngine(gpa, false, nzb_text, port, c[0], c[1], o);
        try o.flush();
        if (have_iouring) {
            try runEngine(gpa, true, nzb_text, port, c[0], c[1], o);
            try o.flush();
        }
    }

    std.fs.cwd().deleteTree(".bench_out") catch {};
}
