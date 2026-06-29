const std = @import("std");
const nzpull = @import("nzpull");
const crc32 = nzpull.crc32;

test "canonical CRC-32 check values" {
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32.hash("123456789"));
    try std.testing.expectEqual(@as(u32, 0x00000000), crc32.hash(""));
    try std.testing.expectEqual(@as(u32, 0xE8B7BE43), crc32.hash("a"));
    try std.testing.expectEqual(@as(u32, 0x352441C2), crc32.hash("abc"));
}

test "combine matches direct over many random splits" {
    const gpa = std.testing.allocator;
    const data = try gpa.alloc(u8, 8192);
    defer gpa.free(data);
    var rng = std.Random.DefaultPrng.init(0xC0FFEE);
    rng.random().bytes(data);

    const full = crc32.hash(data);
    var split: usize = 1;
    while (split < data.len) : (split += 257) {
        const c1 = crc32.hash(data[0..split]);
        const c2 = crc32.hash(data[split..]);
        try std.testing.expectEqual(full, crc32.combine(c1, c2, data.len - split));
    }
}
