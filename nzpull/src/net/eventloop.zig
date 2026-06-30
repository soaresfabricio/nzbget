//! Thin wrapper over `std.os.linux.IoUring` for the async download engine.
//!
//! Keeps the NNTP/state-machine logic (io_engine.zig, async_conn.zig) free of
//! raw io_uring bookkeeping. Each queued op carries an opaque `user_data` value
//! the caller uses to route completions (we encode a pointer + a small op tag).
//! Linux-only; callers fall back to the thread engine when `init` fails.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

pub const Cqe = linux.io_uring_cqe;

pub const Loop = struct {
    ring: linux.IoUring,

    pub fn init(entries: u16) !Loop {
        return .{ .ring = try linux.IoUring.init(entries, 0) };
    }

    pub fn deinit(self: *Loop) void {
        self.ring.deinit();
    }

    /// Queue a TCP connect. `addr` must outlive the operation.
    pub fn connect(self: *Loop, ud: u64, fd: posix.fd_t, addr: *const posix.sockaddr, len: posix.socklen_t) !void {
        _ = try self.ring.connect(ud, fd, addr, len);
    }

    pub fn recv(self: *Loop, ud: u64, fd: posix.fd_t, buf: []u8) !void {
        _ = try self.ring.recv(ud, fd, .{ .buffer = buf }, 0);
    }

    pub fn send(self: *Loop, ud: u64, fd: posix.fd_t, buf: []const u8) !void {
        _ = try self.ring.send(ud, fd, buf, 0);
    }

    /// Submit all queued SQEs without waiting.
    pub fn submit(self: *Loop) !void {
        _ = try self.ring.submit();
    }

    /// Submit queued SQEs, then block until at least one completion is available,
    /// and copy ready completions into `cqes`. Returns the number copied.
    pub fn submitAndReap(self: *Loop, cqes: []Cqe) !u32 {
        _ = try self.ring.submit_and_wait(1);
        return try self.ring.copy_cqes(cqes, 0);
    }
};

/// Create a non-blocking-capable TCP socket for the given address family.
pub fn tcpSocket(family: u32) !posix.fd_t {
    return posix.socket(family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
}

/// An eventfd used by worker threads to wake the (blocked) loop.
pub const EventFd = struct {
    fd: posix.fd_t,

    pub fn init() !EventFd {
        const rc = linux.eventfd(0, linux.EFD.CLOEXEC);
        return .{ .fd = @intCast(rc) };
    }

    pub fn deinit(self: EventFd) void {
        posix.close(self.fd);
    }

    /// Increment the counter, waking any pending read on the eventfd.
    pub fn signal(self: EventFd) void {
        const one: u64 = 1;
        _ = posix.write(self.fd, std.mem.asBytes(&one)) catch {};
    }
};
