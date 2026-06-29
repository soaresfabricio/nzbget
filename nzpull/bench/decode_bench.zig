//! NZpull microbenchmarks.  Run with: zig build bench
//!
//! Covers the CPU-hot paths across representative workloads:
//!   - yEnc decode (native SIMD vs scalar) on text / binary / worst-case payloads
//!   - CRC-32 throughput
//!   - NZB parser throughput
//!
//! Throughput is reported in MiB/s over the *decoded* (or parsed) byte count so
//! numbers are comparable across workloads regardless of escape overhead.

const std = @import("std");
const nzpull = @import("nzpull");
const yenc = nzpull.yenc;
const crc32 = nzpull.crc32;

const Writer = *std.Io.Writer;

/// yEnc-encode `data` into a single-part body (used to feed the decoder).
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

const Workload = struct {
    name: []const u8,
    data: []u8,
    body: []u8,

    fn deinit(self: Workload, gpa: std.mem.Allocator) void {
        gpa.free(self.data);
        gpa.free(self.body);
    }
};

fn makeWorkload(gpa: std.mem.Allocator, name: []const u8, size: usize, kind: enum { text, binary, worst }) !Workload {
    const data = try gpa.alloc(u8, size);
    var rng = std.Random.DefaultPrng.init(0xBEEF);
    switch (kind) {
        // Printable ASCII: encodes with zero escapes (best case for SIMD).
        .text => for (data) |*p| {
            p.* = ' ' + (rng.random().int(u8) % 95);
        },
        // Uniform random bytes: ~1.6% of bytes hit the escaped set (realistic).
        .binary => rng.random().bytes(data),
        // Every byte is one that must be escaped (pathological worst case).
        .worst => for (data) |*p| {
            p.* = (@as(u8, 0) -% 42) +% (rng.random().int(u8) & 0); // decodes to NUL -> escaped
        },
    }
    return .{ .name = name, .data = data, .body = try encode(gpa, data) };
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const stdout = std.fs.File.stdout();
    var ob: [4096]u8 = undefined;
    var fw = stdout.writer(&ob);
    const o = &fw.interface;

    try o.print("NZpull benchmark  ({s})\n\n", .{nzpull.cpu.description()});

    const size = 16 * 1024 * 1024;
    const iters = 20;

    const workloads = [_]Workload{
        try makeWorkload(gpa, "text   (0% esc)", size, .text),
        try makeWorkload(gpa, "binary (~2% esc)", size, .binary),
        try makeWorkload(gpa, "worst  (100% esc)", size, .worst),
    };
    defer for (workloads) |w| w.deinit(gpa);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try o.print("yEnc decode (MiB/s of decoded output):\n", .{});
    try o.print("  {s:<18} {s:>12} {s:>12} {s:>8}\n", .{ "workload", "native", "scalar", "speedup" });
    for (workloads) |w| {
        // Correctness cross-check before timing.
        out.clearRetainingCapacity();
        _ = try yenc.decodeBody(gpa, w.body, &out);
        const decoded_len = out.items.len;
        const native = try benchDecode(gpa, w.body, &out, decoded_len, iters, true);
        const scalar = try benchDecode(gpa, w.body, &out, decoded_len, iters, false);
        try o.print("  {s:<18} {d:>10.1}   {d:>10.1}   {d:>6.2}x\n", .{ w.name, native, scalar, native / scalar });
    }

    // CRC-32.
    {
        const data = workloads[1].data;
        var timer = try std.time.Timer.start();
        var acc: u32 = 0;
        for (0..iters) |_| acc ^= crc32.hash(data);
        std.mem.doNotOptimizeAway(acc);
        const rate = mibps(data.len, iters, timer.read());
        try o.print("\ncrc-32: {d:.1} MiB/s\n", .{rate});
    }

    // NZB parser.
    {
        const nzb_text = try makeNzb(gpa, 500, 100); // 500 files x 100 segments
        defer gpa.free(nzb_text);
        var timer = try std.time.Timer.start();
        const piters = 200;
        var seg_total: usize = 0;
        for (0..piters) |_| {
            var nzb = try nzpull.parser.parse(gpa, nzb_text);
            seg_total += nzb.segmentCount();
            nzb.deinit();
        }
        std.mem.doNotOptimizeAway(seg_total);
        const rate = mibps(nzb_text.len, piters, timer.read());
        try o.print("nzb parse: {d:.1} MiB/s  ({d} bytes, 50k segments)\n", .{ rate, nzb_text.len });
    }

    try o.flush();
}

fn benchDecode(
    gpa: std.mem.Allocator,
    body: []const u8,
    out: *std.ArrayList(u8),
    decoded_len: usize,
    iters: usize,
    comptime simd: bool,
) !f64 {
    var timer = try std.time.Timer.start();
    for (0..iters) |_| {
        out.clearRetainingCapacity();
        _ = if (simd)
            try yenc.decodeBody(gpa, body, out)
        else
            try yenc.decodeBodyScalar(gpa, body, out);
    }
    return mibps(decoded_len, iters, timer.read());
}

fn mibps(bytes: usize, iters: usize, ns: u64) f64 {
    const total = @as(f64, @floatFromInt(bytes * iters));
    const secs = @as(f64, @floatFromInt(ns)) / 1e9;
    return (total / (1024.0 * 1024.0)) / secs;
}

fn makeNzb(gpa: std.mem.Allocator, files: usize, segs: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(gpa, "<?xml version=\"1.0\"?>\n<nzb xmlns=\"http://www.newzbin.com/DTD/2003/nzb\">\n");
    for (0..files) |f| {
        try buf.writer(gpa).print(
            "  <file poster=\"p\" date=\"1\" subject=\"[{d}] - &quot;file{d}.rar&quot; yEnc\">\n    <groups><group>alt.binaries.test</group></groups>\n    <segments>\n",
            .{ f, f },
        );
        for (0..segs) |s| {
            try buf.writer(gpa).print(
                "      <segment bytes=\"768000\" number=\"{d}\">&lt;part{d}.{d}@news&gt;</segment>\n",
                .{ s + 1, f, s },
            );
        }
        try buf.appendSlice(gpa, "    </segments>\n  </file>\n");
    }
    try buf.appendSlice(gpa, "</nzb>\n");
    return buf.toOwnedSlice(gpa);
}
