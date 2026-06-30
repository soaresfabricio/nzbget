//! Bounded pool of reusable, growable byte buffers for raw article bodies.
//!
//! Bounds the *count* of outstanding buffers (memory ≈ sum of in-use article
//! sizes); when all are checked out, `acquire` returns null — that's the
//! backpressure signal the event loop uses to stop reading until the decode pool
//! returns a buffer. Thread-safe (the loop acquires; decode workers release).

const std = @import("std");

pub const Buffer = std.ArrayList(u8);

pub const BufPool = struct {
    gpa: std.mem.Allocator,
    mtx: std.Thread.Mutex = .{},
    free: std.ArrayList(*Buffer) = .empty,
    max: usize,
    created: usize = 0,

    pub fn init(gpa: std.mem.Allocator, max: usize) BufPool {
        return .{ .gpa = gpa, .max = max };
    }

    pub fn deinit(self: *BufPool) void {
        for (self.free.items) |b| {
            b.deinit(self.gpa);
            self.gpa.destroy(b);
        }
        self.free.deinit(self.gpa);
    }

    /// Get a cleared buffer, or null if the pool is exhausted (backpressure).
    pub fn acquire(self: *BufPool) ?*Buffer {
        self.mtx.lock();
        defer self.mtx.unlock();
        if (self.free.pop()) |b| {
            b.clearRetainingCapacity();
            return b;
        }
        if (self.created >= self.max) return null;
        const b = self.gpa.create(Buffer) catch return null;
        b.* = .empty;
        self.created += 1;
        return b;
    }

    /// Return a buffer to the pool for reuse.
    pub fn release(self: *BufPool, b: *Buffer) void {
        self.mtx.lock();
        defer self.mtx.unlock();
        // free list capacity is bounded by `created`, so this append is reserved.
        self.free.append(self.gpa, b) catch {
            b.deinit(self.gpa);
            self.gpa.destroy(b);
            self.created -= 1;
        };
    }
};

test "bufpool bounds and reuses" {
    const gpa = std.testing.allocator;
    var p = BufPool.init(gpa, 2);
    defer p.deinit();

    const a = p.acquire().?;
    const b = p.acquire().?;
    try std.testing.expect(p.acquire() == null); // exhausted at max=2
    try a.appendSlice(gpa, "hello");
    p.release(a);
    const c = p.acquire().?; // reuses a's storage, cleared
    try std.testing.expectEqual(@as(usize, 0), c.items.len);
    p.release(b);
    p.release(c);
}
