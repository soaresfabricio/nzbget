//! Drives the NNTP protocol state machine against a scripted in-memory server,
//! exercising greeting, the AUTHINFO flow, multiline body framing + dot-unstuffing,
//! and the not-found path — all without a real socket.

const std = @import("std");
const nzpull = @import("nzpull");
const nntp = nzpull.nntp;

const MockStream = struct {
    server_out: []const u8, // bytes the "server" will send, in read order
    rpos: usize = 0,
    client_in: std.ArrayList(u8) = .empty, // captures client writes
    gpa: std.mem.Allocator,

    fn readFn(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *MockStream = @ptrCast(@alignCast(ptr));
        const remaining = self.server_out[self.rpos..];
        if (remaining.len == 0) return 0;
        const n = @min(buf.len, remaining.len);
        @memcpy(buf[0..n], remaining[0..n]);
        self.rpos += n;
        return n;
    }

    fn writeFn(ptr: *anyopaque, buf: []const u8) anyerror!usize {
        const self: *MockStream = @ptrCast(@alignCast(ptr));
        try self.client_in.appendSlice(self.gpa, buf);
        return buf.len;
    }

    fn ioStream(self: *MockStream) nntp.IoStream {
        return .{ .ptr = self, .readFn = readFn, .writeFn = writeFn };
    }
};

test "full protocol flow over mock" {
    const gpa = std.testing.allocator;

    const script =
        "200 welcome\r\n" ++ // greeting
        "381 password required\r\n" ++ // after AUTHINFO USER
        "281 authenticated\r\n" ++ // after AUTHINFO PASS
        // BODY #1: ok, with a dot-stuffed line and a literal-dot line
        "222 0 <a@x> body follows\r\n" ++
        "first line\r\n" ++
        "..dotted\r\n" ++ // dot-stuffed -> ".dotted"
        "last\r\n" ++
        ".\r\n" ++
        // BODY #2: missing
        "430 no such article\r\n";

    var mock = MockStream{ .server_out = script, .gpa = gpa };
    defer mock.client_in.deinit(gpa);

    var conn = nntp.Connection.init(mock.ioStream());
    try conn.readGreeting();
    try conn.authenticate("user", "secret");

    // Pipelined: issue both BODY requests, then read both responses.
    try conn.sendBody("a@x");
    try conn.sendBody("b@y");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const s1 = try conn.readBody(gpa, &out);
    try std.testing.expectEqual(nntp.Connection.BodyStatus.ok, s1);
    try std.testing.expectEqualStrings("first line\n.dotted\nlast\n", out.items);

    const s2 = try conn.readBody(gpa, &out);
    try std.testing.expectEqual(nntp.Connection.BodyStatus.not_found, s2);

    // Verify the client emitted the expected commands.
    const sent = mock.client_in.items;
    try std.testing.expect(std.mem.indexOf(u8, sent, "AUTHINFO USER user\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "AUTHINFO PASS secret\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "BODY <a@x>\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "BODY <b@y>\r\n") != null);
}
