//! NNTP protocol layer.
//!
//! Built over `IoStream`, a tiny read/write vtable, so the exact same protocol
//! code runs over plain TCP, TLS, or an in-memory mock (see tests/nntp_mock.zig).
//! Supports the subset NZpull needs: greeting, AUTHINFO USER/PASS, GROUP, BODY,
//! QUIT — plus multiline body framing with dot-unstuffing. Command *pipelining*
//! is expressed by separating `sendBody` (write) from `readBody` (read): a caller
//! may issue several `sendBody`s before reading the matching `readBody`s in order.

const std = @import("std");

pub const Error = error{
    ConnectionClosed,
    LineTooLong,
    ProtocolError,
    AuthFailed,
    OutOfMemory,
    WriteFailed,
    ReadFailed,
};

/// Minimal stream abstraction: read into / write from byte buffers. Concrete
/// transports (TCP, TLS) and the test mock implement these two functions.
pub const IoStream = struct {
    ptr: *anyopaque,
    readFn: *const fn (ptr: *anyopaque, buf: []u8) anyerror!usize,
    writeFn: *const fn (ptr: *anyopaque, buf: []const u8) anyerror!usize,

    fn read(self: IoStream, buf: []u8) Error!usize {
        return self.readFn(self.ptr, buf) catch return Error.ReadFailed;
    }

    fn writeAll(self: IoStream, buf: []const u8) Error!void {
        var off: usize = 0;
        while (off < buf.len) {
            const n = self.writeFn(self.ptr, buf[off..]) catch return Error.WriteFailed;
            if (n == 0) return Error.ConnectionClosed;
            off += n;
        }
    }
};

pub const Response = struct {
    code: u16,
    text: []const u8, // points into the connection's line buffer; copy if kept
};

const line_buf_size = 64 * 1024;

pub const Connection = struct {
    stream: IoStream,
    buf: [line_buf_size]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    active_group: ?[]const u8 = null,
    group_storage: [256]u8 = undefined,

    pub fn init(stream: IoStream) Connection {
        return .{ .stream = stream };
    }

    /// Read one CRLF-terminated line, returned without the trailing CRLF. The
    /// slice is valid until the next read call.
    fn readLine(self: *Connection) Error![]const u8 {
        while (true) {
            // Look for LF in the buffered region.
            if (std.mem.indexOfScalarPos(u8, self.buf[0..self.end], self.start, '\n')) |nl| {
                var line = self.buf[self.start..nl];
                if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
                self.start = nl + 1;
                return line;
            }
            // Compact then refill.
            if (self.start > 0) {
                std.mem.copyForwards(u8, self.buf[0..], self.buf[self.start..self.end]);
                self.end -= self.start;
                self.start = 0;
            }
            if (self.end == self.buf.len) return Error.LineTooLong;
            const n = try self.stream.read(self.buf[self.end..]);
            if (n == 0) return Error.ConnectionClosed;
            self.end += n;
        }
    }

    fn readResponse(self: *Connection) Error!Response {
        const line = try self.readLine();
        if (line.len < 3) return Error.ProtocolError;
        const code = std.fmt.parseInt(u16, line[0..3], 10) catch return Error.ProtocolError;
        return .{ .code = code, .text = if (line.len > 4) line[4..] else "" };
    }

    fn writeCommand(self: *Connection, comptime fmt: []const u8, args: anytype) Error!void {
        var tmp: [512]u8 = undefined;
        const cmd = std.fmt.bufPrint(&tmp, fmt ++ "\r\n", args) catch return Error.LineTooLong;
        try self.stream.writeAll(cmd);
    }

    /// Read the welcome banner. 200 (posting allowed) / 201 (read-only) are OK.
    pub fn readGreeting(self: *Connection) Error!void {
        const r = try self.readResponse();
        if (r.code != 200 and r.code != 201) return Error.ProtocolError;
    }

    pub fn authenticate(self: *Connection, user: []const u8, pass: []const u8) Error!void {
        try self.writeCommand("AUTHINFO USER {s}", .{user});
        var r = try self.readResponse();
        if (r.code == 281) return; // accepted without password
        if (r.code != 381) return Error.AuthFailed;
        try self.writeCommand("AUTHINFO PASS {s}", .{pass});
        r = try self.readResponse();
        if (r.code != 281) return Error.AuthFailed;
    }

    /// Switch newsgroup, skipping the command if already selected (mirrors
    /// nzbget's active-group caching).
    pub fn selectGroup(self: *Connection, group: []const u8) Error!void {
        if (self.active_group) |g| if (std.mem.eql(u8, g, group)) return;
        try self.writeCommand("GROUP {s}", .{group});
        const r = try self.readResponse();
        if (r.code != 211) return Error.ProtocolError;
        if (group.len <= self.group_storage.len) {
            @memcpy(self.group_storage[0..group.len], group);
            self.active_group = self.group_storage[0..group.len];
        }
    }

    /// Pipelining write half: queue a BODY request. `message_id` is bracket-less
    /// (as stored in the NZB); brackets are added here.
    pub fn sendBody(self: *Connection, message_id: []const u8) Error!void {
        try self.writeCommand("BODY <{s}>", .{message_id});
    }

    pub const BodyStatus = enum { ok, not_found, other };

    /// Pipelining read half: read the response to the next outstanding BODY. On
    /// `.ok`, the dot-unstuffed yEnc body (lines separated by '\n') is appended
    /// to `out`. On any error response the body block is absent.
    pub fn readBody(
        self: *Connection,
        gpa: std.mem.Allocator,
        out: *std.ArrayList(u8),
    ) Error!BodyStatus {
        const r = try self.readResponse();
        switch (r.code) {
            222 => {}, // body follows
            430, 423 => return .not_found, // no such article / no such number
            else => return .other,
        }
        try self.readDataBlock(gpa, out);
        return .ok;
    }

    /// Read a multiline data block terminated by a lone ".", undoing dot-stuffing.
    fn readDataBlock(self: *Connection, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
        while (true) {
            const line = try self.readLine();
            if (isBodyTerminator(line)) return;
            try out.appendSlice(gpa, unstuff(line));
            try out.append(gpa, '\n');
        }
    }

    pub fn quit(self: *Connection) void {
        self.writeCommand("QUIT", .{}) catch {};
    }

    /// Bytes received past the last consumed line (normally empty after a
    /// handshake). The async engine carries these over when it takes the fd.
    pub fn leftover(self: *const Connection) []const u8 {
        return self.buf[self.start..self.end];
    }
};

/// A multiline data block ends with a line containing a single ".".
pub fn isBodyTerminator(line: []const u8) bool {
    return line.len == 1 and line[0] == '.';
}

/// Undo NNTP dot-stuffing: a line beginning with "." had one prepended.
pub fn unstuff(line: []const u8) []const u8 {
    if (line.len >= 1 and line[0] == '.') return line[1..];
    return line;
}

/// Parse a 3-digit NNTP status code from a response line (0 if malformed).
pub fn statusCode(line: []const u8) u16 {
    if (line.len < 3) return 0;
    return std.fmt.parseInt(u16, line[0..3], 10) catch 0;
}
