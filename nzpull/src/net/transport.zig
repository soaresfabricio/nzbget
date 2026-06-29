//! Concrete transports that present an `nntp.IoStream` to the protocol layer.
//!
//! - `TcpTransport`: plain TCP (port 119). Fully supported.
//! - `TlsTransport`: TLS over TCP (port 563) via `std.crypto.tls.Client`.
//!   NOTE: the std client is TLS 1.3 only. Many Usenet providers still offer
//!   only TLS 1.2, so this path is best-effort; the planned long-term fix is a
//!   C TLS binding (BoringSSL/OpenSSL) — see README "TLS".

const std = @import("std");
const nntp = @import("nntp.zig");

pub const Error = error{ ConnectFailed, TlsHandshakeFailed, OutOfMemory };

pub const TcpTransport = struct {
    stream: std.net.Stream,

    pub fn connect(gpa: std.mem.Allocator, host: []const u8, port: u16) Error!*TcpTransport {
        const stream = std.net.tcpConnectToHost(gpa, host, port) catch return Error.ConnectFailed;
        const self = gpa.create(TcpTransport) catch return Error.OutOfMemory;
        self.* = .{ .stream = stream };
        return self;
    }

    pub fn deinit(self: *TcpTransport, gpa: std.mem.Allocator) void {
        self.stream.close();
        gpa.destroy(self);
    }

    fn readFn(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *TcpTransport = @ptrCast(@alignCast(ptr));
        return self.stream.read(buf);
    }

    fn writeFn(ptr: *anyopaque, buf: []const u8) anyerror!usize {
        const self: *TcpTransport = @ptrCast(@alignCast(ptr));
        try self.stream.writeAll(buf);
        return buf.len;
    }

    pub fn ioStream(self: *TcpTransport) nntp.IoStream {
        return .{ .ptr = self, .readFn = readFn, .writeFn = writeFn };
    }
};

pub const TlsTransport = struct {
    sock: std.net.Stream,
    reader_buf: [64 * 1024]u8 = undefined,
    writer_buf: [64 * 1024]u8 = undefined,
    tls_read_buf: [64 * 1024]u8 = undefined,
    tls_write_buf: [64 * 1024]u8 = undefined,
    sock_reader: std.net.Stream.Reader,
    sock_writer: std.net.Stream.Writer,
    client: std.crypto.tls.Client,

    pub fn connect(gpa: std.mem.Allocator, host: []const u8, port: u16) Error!*TlsTransport {
        const sock = std.net.tcpConnectToHost(gpa, host, port) catch return Error.ConnectFailed;
        const self = gpa.create(TlsTransport) catch return Error.OutOfMemory;
        errdefer gpa.destroy(self);
        self.sock = sock;
        // Pin the struct: the readers/writers and the TLS client store pointers
        // into these fields, so `self` must not move after this point.
        self.sock_reader = sock.reader(&self.reader_buf);
        self.sock_writer = sock.writer(&self.writer_buf);
        self.client = std.crypto.tls.Client.init(
            self.sock_reader.interface(),
            &self.sock_writer.interface,
            .{
                .host = .{ .explicit = host },
                // We cannot ship a CA bundle portably here; skip CA verification
                // for now (documented limitation). A real deployment must verify.
                .ca = .no_verification,
                .read_buffer = &self.tls_read_buf,
                .write_buffer = &self.tls_write_buf,
            },
        ) catch return Error.TlsHandshakeFailed;
        return self;
    }

    pub fn deinit(self: *TlsTransport, gpa: std.mem.Allocator) void {
        self.client.end() catch {};
        self.sock.close();
        gpa.destroy(self);
    }

    fn readFn(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *TlsTransport = @ptrCast(@alignCast(ptr));
        return self.client.reader.readSliceShort(buf);
    }

    fn writeFn(ptr: *anyopaque, buf: []const u8) anyerror!usize {
        const self: *TlsTransport = @ptrCast(@alignCast(ptr));
        try self.client.writer.writeAll(buf);
        try self.client.writer.flush();
        return buf.len;
    }

    pub fn ioStream(self: *TlsTransport) nntp.IoStream {
        return .{ .ptr = self, .readFn = readFn, .writeFn = writeFn };
    }
};
