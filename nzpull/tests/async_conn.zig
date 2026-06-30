//! Unit tests for the io_uring engine's response state machine, driven directly
//! with scripted byte streams (no sockets).

const std = @import("std");
const nzpull = @import("nzpull");
const AsyncConn = nzpull.async_conn.AsyncConn;
const Completed = nzpull.async_conn.Completed;
const BufPool = nzpull.bufpool.BufPool;

const Harness = struct {
    gpa: std.mem.Allocator,
    pool: BufPool,
    conn: AsyncConn,
    completed: std.ArrayList(Completed) = .empty,
    not_found: u64 = 0,

    fn init(gpa: std.mem.Allocator) Harness {
        return .{ .gpa = gpa, .pool = BufPool.init(gpa, 16), .conn = AsyncConn.init(gpa) };
    }
    fn deinit(self: *Harness) void {
        for (self.completed.items) |c| self.pool.release(c.raw);
        self.completed.deinit(self.gpa);
        self.conn.deinit();
        self.pool.deinit();
    }
    fn feed(self: *Harness, bytes: []const u8) !void {
        try self.conn.onBytes(&self.pool, bytes, &self.completed, &self.not_found);
    }
};

test "single body, split across feeds, dot-unstuffed" {
    const gpa = std.testing.allocator;
    var h = Harness.init(gpa);
    defer h.deinit();

    try h.conn.pushRequest(7);
    // Deliberately split mid-line between feeds.
    try h.feed("222 0 body fol");
    try h.feed("lows\r\n=ybegin line=128 size=3 name=x\r\n");
    try h.feed("..dotted\r\nDATA\r\n");
    try h.feed(".\r\n");

    try std.testing.expectEqual(@as(usize, 1), h.completed.items.len);
    try std.testing.expectEqual(@as(u32, 7), h.completed.items[0].file_index);
    const body = h.completed.items[0].raw.items;
    // Lines are stored unstuffed, separated by '\n'.
    try std.testing.expect(std.mem.indexOf(u8, body, ".dotted\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "DATA\n") != null);
    try std.testing.expectEqual(@as(u64, 0), h.not_found);
    try std.testing.expectEqual(@as(usize, 0), h.conn.inFlight());
}

test "pipelined FIFO with a 430 in the middle" {
    const gpa = std.testing.allocator;
    var h = Harness.init(gpa);
    defer h.deinit();

    // Three requests in flight, FIFO order: ok, missing, ok.
    try h.conn.pushRequest(1);
    try h.conn.pushRequest(2);
    try h.conn.pushRequest(3);

    try h.feed("222 0 body follows\r\nAAA\r\n.\r\n");
    try h.feed("430 no such article\r\n");
    try h.feed("222 0 body follows\r\nCCC\r\n.\r\n");

    try std.testing.expectEqual(@as(usize, 2), h.completed.items.len);
    try std.testing.expectEqual(@as(u32, 1), h.completed.items[0].file_index);
    try std.testing.expectEqual(@as(u32, 3), h.completed.items[1].file_index);
    try std.testing.expectEqual(@as(u64, 1), h.not_found);
    try std.testing.expectEqual(@as(usize, 0), h.conn.inFlight());
}

test "backpressure: pool exhaustion blocks then resumes" {
    const gpa = std.testing.allocator;
    var h = Harness.init(gpa);
    h.pool = BufPool.init(gpa, 1); // only one buffer available
    defer h.deinit();

    try h.conn.pushRequest(10);
    try h.conn.pushRequest(11);

    // First body acquires the only buffer; second 222 can't get one → blocked.
    try h.feed("222 0 body follows\r\nONE\r\n.\r\n222 0 body follows\r\nTWO\r\n.\r\n");
    try std.testing.expect(h.conn.isBlocked());
    try std.testing.expectEqual(@as(usize, 1), h.completed.items.len);

    // Free the first buffer and resume — the second body should now complete.
    const first = h.completed.items[0];
    h.pool.release(first.raw);
    h.completed.clearRetainingCapacity();

    try h.conn.resume_(&h.pool, &h.completed, &h.not_found);
    try std.testing.expect(!h.conn.isBlocked());
    try std.testing.expectEqual(@as(usize, 1), h.completed.items.len);
    try std.testing.expectEqual(@as(u32, 11), h.completed.items[0].file_index);
}
