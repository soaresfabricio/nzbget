//! Per-connection NNTP response state machine for the io_uring engine.
//!
//! Pure logic: feed it received bytes via `onBytes`, and it emits completed
//! articles (raw, dot-unstuffed yEnc bodies in pooled buffers) and counts
//! not-found responses. No sockets here — the engine (io_engine.zig) does I/O and
//! the unit tests drive this directly with scripted byte streams.
//!
//! Responses for pipelined `BODY` requests arrive in FIFO order, so a single
//! queue of file indices (`flight`) matches each response to its target file.

const std = @import("std");
const nntp = @import("nntp.zig");
const bufpool = @import("../util/bufpool.zig");
const BufPool = bufpool.BufPool;
const Buffer = bufpool.Buffer;

pub const Completed = struct {
    raw: *Buffer,
    file_index: u32,
};

pub const AsyncConn = struct {
    gpa: std.mem.Allocator,
    /// Only the partial trailing line carries across reads (kept small); the bulk
    /// of each recv buffer is parsed in place, so received bytes are copied just
    /// once — into the article buffer — rather than into an intermediate buffer.
    carry: std.ArrayList(u8) = .empty,
    flight: std.ArrayList(u32) = .empty, // outstanding request file indices (FIFO)
    flight_head: usize = 0,
    parse_state: enum { status, body } = .status,
    cur_raw: ?*Buffer = null, // body currently being accumulated
    /// Set when a 222 arrived but the buffer pool was exhausted; the engine must
    /// pause reads on this connection and resume (call `resume_`) once a buffer
    /// frees up.
    needs_buffer: bool = false,

    pub fn init(gpa: std.mem.Allocator) AsyncConn {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *AsyncConn) void {
        self.carry.deinit(self.gpa);
        self.flight.deinit(self.gpa);
    }

    pub fn inFlight(self: *const AsyncConn) usize {
        return self.flight.items.len - self.flight_head;
    }

    pub fn isBlocked(self: *const AsyncConn) bool {
        return self.needs_buffer;
    }

    /// Record that a BODY request for `file_index` has been sent.
    pub fn pushRequest(self: *AsyncConn, file_index: u32) !void {
        try self.flight.append(self.gpa, file_index);
    }

    fn popRequest(self: *AsyncConn) u32 {
        const v = self.flight.items[self.flight_head];
        self.flight_head += 1;
        if (self.flight_head == self.flight.items.len) {
            self.flight.clearRetainingCapacity();
            self.flight_head = 0;
        }
        return v;
    }

    /// Feed freshly received bytes and advance parsing. The bulk of `new` is
    /// parsed in place; only an unfinished trailing line is copied into `carry`.
    pub fn onBytes(self: *AsyncConn, pool: *BufPool, new: []const u8, completed: *std.ArrayList(Completed), not_found: *u64) !void {
        self.needs_buffer = false;
        var off: usize = 0;

        if (self.carry.items.len > 0) {
            // Complete the carried partial line using bytes up to the next newline.
            const nl = std.mem.indexOfScalar(u8, new, '\n') orelse {
                try self.carry.appendSlice(self.gpa, new); // still partial
                return;
            };
            try self.carry.appendSlice(self.gpa, new[0 .. nl + 1]);
            const c = try self.consume(pool, self.carry.items, completed, not_found);
            if (self.needs_buffer) {
                // Blocked on the carried line: retain it and stash the rest of new.
                self.dropFront(c);
                try self.carry.appendSlice(self.gpa, new[nl + 1 ..]);
                return;
            }
            self.carry.clearRetainingCapacity();
            off = nl + 1;
        }

        // Parse the remainder of `new` directly.
        const c2 = try self.consume(pool, new[off..], completed, not_found);
        const rem = new[off + c2 ..];
        if (rem.len > 0) try self.carry.appendSlice(self.gpa, rem);
    }

    /// Resume after the pool was exhausted (no new bytes), once a buffer is free.
    pub fn resume_(self: *AsyncConn, pool: *BufPool, completed: *std.ArrayList(Completed), not_found: *u64) !void {
        self.needs_buffer = false;
        const c = try self.consume(pool, self.carry.items, completed, not_found);
        self.dropFront(c);
    }

    fn dropFront(self: *AsyncConn, n: usize) void {
        if (n == 0) return;
        const remaining = self.carry.items.len - n;
        std.mem.copyForwards(u8, self.carry.items[0..remaining], self.carry.items[n..]);
        self.carry.items.len = remaining;
    }

    /// Process complete lines in `buf`; return the number of bytes consumed (up to
    /// the last fully-processed line, or the start of a line that blocked on the
    /// buffer pool). Sets `needs_buffer` when it blocks.
    fn consume(self: *AsyncConn, pool: *BufPool, buf: []const u8, completed: *std.ArrayList(Completed), not_found: *u64) !usize {
        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, buf, pos, '\n')) |nl| {
            var line = buf[pos..nl];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

            switch (self.parse_state) {
                .status => {
                    const code = nntp.statusCode(line);
                    if (code == 222) {
                        // Acquire the body buffer before consuming this line so we
                        // can cleanly resume here if the pool is exhausted.
                        const raw = pool.acquire() orelse {
                            self.needs_buffer = true;
                            return pos;
                        };
                        self.cur_raw = raw;
                        self.parse_state = .body;
                    } else {
                        _ = self.popRequest(); // 430/423/other: no body follows
                        not_found.* += 1;
                    }
                },
                .body => {
                    if (nntp.isBodyTerminator(line)) {
                        const fi = self.popRequest();
                        try completed.append(self.gpa, .{ .raw = self.cur_raw.?, .file_index = fi });
                        self.cur_raw = null;
                        self.parse_state = .status;
                    } else {
                        const data = nntp.unstuff(line);
                        try self.cur_raw.?.appendSlice(self.gpa, data);
                        try self.cur_raw.?.append(self.gpa, '\n');
                    }
                },
            }
            pos = nl + 1;
        }
        return pos;
    }
};
