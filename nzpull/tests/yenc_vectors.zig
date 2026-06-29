const std = @import("std");
const nzpull = @import("nzpull");
const yenc = nzpull.yenc;

// A hand-built single-part yEnc body. "NZpull" encodes as each byte +42:
//   N(0x4E)->0x78 'x'  Z(0x5A)->0x84  p(0x70)->0x9A  u(0x75)->0x9F
//   l(0x6C)->0x96  l(0x6C)->0x96
// none of these collide with the escaped set (NUL/CR/LF/'='), so no escapes.
const body =
    "=ybegin line=128 size=6 name=greeting.bin\r\n" ++
    "\x78\x84\x9a\x9f\x96\x96\r\n" ++
    "=yend size=6 crc32=00000000\r\n";

test "decode known single-part body" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const res = try yenc.decodeBody(gpa, body, &out);
    try std.testing.expectEqualStrings("NZpull", out.items);
    try std.testing.expectEqualStrings("greeting.bin", res.header.name);
    try std.testing.expectEqual(@as(u64, 6), res.bytes_written);
    // Computed CRC should match the real CRC-32 of "NZpull".
    try std.testing.expectEqual(nzpull.crc32.hash("NZpull"), res.crc32);
}

test "scalar and simd agree on a random payload" {
    const gpa = std.testing.allocator;
    const payload = try gpa.alloc(u8, 50_000);
    defer gpa.free(payload);
    var rng = std.Random.DefaultPrng.init(7);
    rng.random().bytes(payload);

    // Build an encoded body using the library's own decode-inverse is not public,
    // so encode inline (mirrors the yEnc rules).
    var enc: std.ArrayList(u8) = .empty;
    defer enc.deinit(gpa);
    try enc.appendSlice(gpa, "=ybegin line=128 size=50000 name=r.bin\r\n");
    var col: usize = 0;
    for (payload) |b| {
        const e = b +% 42;
        if (e == 0 or e == '\r' or e == '\n' or e == '=') {
            try enc.append(gpa, '=');
            try enc.append(gpa, e +% 64);
            col += 2;
        } else {
            try enc.append(gpa, e);
            col += 1;
        }
        if (col >= 128) {
            try enc.appendSlice(gpa, "\r\n");
            col = 0;
        }
    }
    try enc.appendSlice(gpa, "\r\n=yend size=50000\r\n");

    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    _ = try yenc.decodeBody(gpa, enc.items, &a);
    _ = try yenc.decodeBodyScalar(gpa, enc.items, &b);
    try std.testing.expectEqualSlices(u8, payload, a.items);
    try std.testing.expectEqualSlices(u8, a.items, b.items);
}
