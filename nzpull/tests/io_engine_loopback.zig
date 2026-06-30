//! End-to-end test of the io_uring engine against an in-process TCP NNTP server
//! serving canned yEnc articles. Verifies assembled output bytes and Stats.

const std = @import("std");
const nzpull = @import("nzpull");

const files = 2;
const segs_per_file = 2;
const seg_len = 100;
const file_len = segs_per_file * seg_len;

fn segId(buf: []u8, fi: usize, si: usize) []const u8 {
    return std.fmt.bufPrint(buf, "f{d}s{d}@t", .{ fi, si }) catch unreachable;
}

/// Deterministic payload for file `fi`, segment `si`.
fn fillSegment(out: *[seg_len]u8, fi: usize, si: usize) void {
    for (out, 0..) |*b, i| b.* = @truncate((fi * 131 + si * 31 + i * 7 + 3));
}

/// yEnc-encode a part into `w` (header..trailer), dot-stuffing line starts.
fn encodeBody(w: anytype, data: []const u8, begin1: usize, total: usize, name: []const u8) !void {
    try w.print("=ybegin part=1 total={d} line=128 size={d} name={s}\r\n", .{ segs_per_file, total, name });
    try w.print("=ypart begin={d} end={d}\r\n", .{ begin1, begin1 + data.len - 1 });
    var line: [512]u8 = undefined;
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
    try w.print("=yend size={d} part=1 pcrc32={x:0>8}\r\n", .{ data.len, nzpull.crc32.hash(data) });
}

fn emitLine(w: anytype, line: []const u8) !void {
    if (line.len > 0 and line[0] == '.') try w.writeAll("."); // dot-stuff
    try w.writeAll(line);
    try w.writeAll("\r\n");
}

const Server = struct {
    gpa: std.mem.Allocator,
    listener: std.net.Server,
    bodies: std.StringHashMap([]u8),
    handlers: std.ArrayList(std.Thread) = .empty,

    fn port(self: *Server) u16 {
        return self.listener.listen_address.getPort();
    }

    fn acceptN(self: *Server, n: usize) void {
        for (0..n) |_| {
            const conn = self.listener.accept() catch return;
            const t = std.Thread.spawn(.{}, handle, .{ self, conn.stream }) catch {
                conn.stream.close();
                continue;
            };
            self.handlers.append(self.gpa, t) catch {};
        }
    }

    fn handle(self: *Server, stream: std.net.Stream) void {
        defer stream.close();
        stream.writeAll("200 welcome\r\n") catch return;
        var buf: [4096]u8 = undefined;
        var acc: std.ArrayList(u8) = .empty;
        defer acc.deinit(self.gpa);
        while (true) {
            const n = stream.read(&buf) catch return;
            if (n == 0) return;
            acc.appendSlice(self.gpa, buf[0..n]) catch return;
            while (std.mem.indexOf(u8, acc.items, "\r\n")) |nl| {
                const line = self.gpa.dupe(u8, acc.items[0..nl]) catch return;
                defer self.gpa.free(line);
                const remaining = acc.items.len - (nl + 2);
                std.mem.copyForwards(u8, acc.items[0..remaining], acc.items[nl + 2 ..]);
                acc.items.len = remaining;
                self.respond(stream, line) catch return;
            }
        }
    }

    fn respond(self: *Server, stream: std.net.Stream, line: []const u8) !void {
        if (std.mem.startsWith(u8, line, "AUTHINFO USER")) {
            try stream.writeAll("381 pass\r\n");
        } else if (std.mem.startsWith(u8, line, "AUTHINFO PASS")) {
            try stream.writeAll("281 ok\r\n");
        } else if (std.mem.startsWith(u8, line, "BODY ")) {
            const id = std.mem.trim(u8, line["BODY ".len..], " <>");
            if (self.bodies.get(id)) |body| {
                try stream.writeAll("222 0 body follows\r\n");
                try stream.writeAll(body);
                try stream.writeAll(".\r\n");
            } else {
                try stream.writeAll("430 no such article\r\n");
            }
        } else if (std.mem.startsWith(u8, line, "QUIT")) {
            try stream.writeAll("205 bye\r\n");
        }
    }
};

test "io_uring engine downloads and assembles via loopback" {
    const gpa = std.testing.allocator;

    // Skip if io_uring isn't available in this environment.
    var probe = nzpull.eventloop.Loop.init(8) catch return error.SkipZigTest;
    probe.deinit();

    // Build expected payloads, the server body map, and an NZB referencing them.
    var bodies = std.StringHashMap([]u8).init(gpa);
    var expected: [files][file_len]u8 = undefined;

    var nzb_text: std.ArrayList(u8) = .empty;
    defer nzb_text.deinit(gpa);
    const nw = nzb_text.writer(gpa);
    try nw.writeAll("<?xml version=\"1.0\"?>\n<nzb>\n");

    for (0..files) |fi| {
        try nw.print("  <file subject=\"&quot;file{d}.bin&quot;\">\n    <groups><group>g</group></groups>\n    <segments>\n", .{fi});
        for (0..segs_per_file) |si| {
            var seg: [seg_len]u8 = undefined;
            fillSegment(&seg, fi, si);
            @memcpy(expected[fi][si * seg_len ..][0..seg_len], &seg);

            var name_buf: [32]u8 = undefined;
            const fname = try std.fmt.bufPrint(&name_buf, "file{d}.bin", .{fi});
            var body: std.ArrayList(u8) = .empty;
            try encodeBody(body.writer(gpa), &seg, si * seg_len + 1, file_len, fname);

            var id_buf: [32]u8 = undefined;
            const id = segId(&id_buf, fi, si);
            try bodies.put(try gpa.dupe(u8, id), try body.toOwnedSlice(gpa));
            try nw.print("      <segment bytes=\"160\" number=\"{d}\">{s}</segment>\n", .{ si + 1, id });
        }
        try nw.writeAll("    </segments>\n  </file>\n");
    }
    try nw.writeAll("</nzb>\n");

    defer {
        var it = bodies.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        bodies.deinit();
    }

    // Start the loopback server.
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = Server{
        .gpa = gpa,
        .listener = try addr.listen(.{ .reuse_address = true }),
        .bodies = bodies,
    };
    defer {
        for (server.handlers.items) |t| t.join();
        server.handlers.deinit(gpa);
        server.listener.deinit();
    }
    const n_conns: u32 = 2;
    const accept_thread = try std.Thread.spawn(.{}, Server.acceptN, .{ &server, n_conns });
    defer accept_thread.join();

    // Output dir.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var nzb = try nzpull.parser.parse(gpa, nzb_text.items);
    defer nzb.deinit();

    const cfg = nzpull.client.ServerConfig{
        .host = "127.0.0.1",
        .port = server.port(),
        .user = "u",
        .pass = "p",
        .connections = n_conns,
        .pipeline_depth = 2,
    };

    const stats = try nzpull.io_engine.download(gpa, nzb, tmp.dir, cfg);

    try std.testing.expectEqual(@as(u64, files * segs_per_file), stats.segments_ok);
    try std.testing.expectEqual(@as(u64, 0), stats.segments_failed);
    try std.testing.expectEqual(@as(u64, 0), stats.crc_errors);

    // Verify assembled files are byte-identical.
    for (0..files) |fi| {
        var name_buf: [32]u8 = undefined;
        const fname = try std.fmt.bufPrint(&name_buf, "file{d}.bin", .{fi});
        const content = try tmp.dir.readFileAlloc(gpa, fname, 1 << 20);
        defer gpa.free(content);
        try std.testing.expectEqualSlices(u8, &expected[fi], content);
    }
}
