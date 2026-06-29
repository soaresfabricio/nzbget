//! Decode throughput benchmark: native SIMD vs scalar yEnc, plus CRC-32.
//! Run with: zig build bench

const std = @import("std");
const nzpull = @import("nzpull");
const yenc = nzpull.yenc;
const crc32 = nzpull.crc32;

fn encode(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(gpa, "=ybegin line=128 size=0 name=bench.bin\r\n");
    var col: usize = 0;
    for (data) |b| {
        const e = b +% 42;
        if (e == 0 or e == '\r' or e == '\n' or e == '=') {
            try buf.append(gpa, '=');
            try buf.append(gpa, e +% 64);
            col += 2;
        } else {
            try buf.append(gpa, e);
            col += 1;
        }
        if (col >= 128) {
            try buf.appendSlice(gpa, "\r\n");
            col = 0;
        }
    }
    try buf.appendSlice(gpa, "\r\n=yend size=0\r\n");
    return buf.toOwnedSlice(gpa);
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const stdout = std.fs.File.stdout();
    var ob: [1024]u8 = undefined;
    var w = stdout.writer(&ob);
    const o = &w.interface;

    // ~16 MiB of realistic-ish binary data (random => ~2% escapes).
    const size = 16 * 1024 * 1024;
    const data = try gpa.alloc(u8, size);
    defer gpa.free(data);
    var rng = std.Random.DefaultPrng.init(0xBEEF);
    rng.random().bytes(data);

    const body = try encode(gpa, data);
    defer gpa.free(body);

    try o.print("NZpull decode benchmark  ({s})\n", .{nzpull.cpu.description()});
    try o.print("payload: {d:.1} MiB ({d:.1} MiB encoded)\n", .{
        @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0),
        @as(f64, @floatFromInt(body.len)) / (1024.0 * 1024.0),
    });

    const iters = 20;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    // Warm up + correctness cross-check.
    {
        out.clearRetainingCapacity();
        _ = try yenc.decodeBody(gpa, body, &out);
        const ref = out.items.len;
        out.clearRetainingCapacity();
        _ = try yenc.decodeBodyScalar(gpa, body, &out);
        std.debug.assert(out.items.len == ref);
    }

    try bench(o, "native (simd)", gpa, body, &out, size, iters, true);
    try bench(o, "scalar       ", gpa, body, &out, size, iters, false);

    // CRC-32 throughput.
    {
        var timer = try std.time.Timer.start();
        var acc: u32 = 0;
        for (0..iters) |_| acc ^= crc32.hash(data);
        const ns = timer.read();
        std.mem.doNotOptimizeAway(acc);
        try printRate(o, "crc32        ", size, iters, ns);
    }

    try o.flush();
}

fn bench(
    o: anytype,
    name: []const u8,
    gpa: std.mem.Allocator,
    body: []const u8,
    out: *std.ArrayList(u8),
    bytes: usize,
    iters: usize,
    comptime simd: bool,
) !void {
    var timer = try std.time.Timer.start();
    for (0..iters) |_| {
        out.clearRetainingCapacity();
        _ = if (simd)
            try yenc.decodeBody(gpa, body, out)
        else
            try yenc.decodeBodyScalar(gpa, body, out);
    }
    const ns = timer.read();
    try printRate(o, name, bytes, iters, ns);
}

fn printRate(o: anytype, name: []const u8, bytes: usize, iters: usize, ns: u64) !void {
    const total = @as(f64, @floatFromInt(bytes * iters));
    const secs = @as(f64, @floatFromInt(ns)) / 1e9;
    const mibps = (total / (1024.0 * 1024.0)) / secs;
    try o.print("  {s}: {d:8.1} MiB/s\n", .{ name, mibps });
}
