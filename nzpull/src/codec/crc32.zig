//! IEEE CRC-32 (reflected, polynomial 0xEDB88820) — the variant yEnc uses in its
//! `crc32=`/`pcrc32=` trailers. NOT CRC-32C, so the SSE4.2 `crc32` instruction is
//! unusable here; the SIMD route is PCLMULQDQ folding (future optimization). This
//! module ships a correct, fast slice-by-8 table implementation plus `combine()`
//! so the assembler can stitch per-segment CRCs without rehashing whole files.

const std = @import("std");

pub const poly: u32 = 0xEDB88320;

/// Slice-by-8 lookup tables, generated at comptime.
const tables: [8][256]u32 = blk: {
    @setEvalBranchQuota(20000);
    var t: [8][256]u32 = undefined;
    for (0..256) |n| {
        var c: u32 = @intCast(n);
        for (0..8) |_| {
            c = if (c & 1 != 0) poly ^ (c >> 1) else c >> 1;
        }
        t[0][n] = c;
    }
    for (0..256) |n| {
        var c = t[0][n];
        for (1..8) |k| {
            c = t[0][c & 0xff] ^ (c >> 8);
            t[k][n] = c;
        }
    }
    break :blk t;
};

/// Streaming CRC-32 accumulator.
pub const Crc32 = struct {
    state: u32 = 0xFFFFFFFF,

    pub fn init() Crc32 {
        return .{};
    }

    pub fn update(self: *Crc32, data: []const u8) void {
        var crc = self.state;
        var buf = data;
        // Slice-by-8: consume 8 bytes per iteration.
        while (buf.len >= 8) {
            const w0 = crc ^ std.mem.readInt(u32, buf[0..4], .little);
            const w1 = std.mem.readInt(u32, buf[4..8], .little);
            crc = tables[7][w0 & 0xff] ^
                tables[6][(w0 >> 8) & 0xff] ^
                tables[5][(w0 >> 16) & 0xff] ^
                tables[4][(w0 >> 24) & 0xff] ^
                tables[3][w1 & 0xff] ^
                tables[2][(w1 >> 8) & 0xff] ^
                tables[1][(w1 >> 16) & 0xff] ^
                tables[0][(w1 >> 24) & 0xff];
            buf = buf[8..];
        }
        for (buf) |b| {
            crc = tables[0][(crc ^ b) & 0xff] ^ (crc >> 8);
        }
        self.state = crc;
    }

    pub fn final(self: *const Crc32) u32 {
        return self.state ^ 0xFFFFFFFF;
    }
};

/// One-shot convenience.
pub fn hash(data: []const u8) u32 {
    var c = Crc32.init();
    c.update(data);
    return c.final();
}

// --- CRC combine (GF(2) matrix exponentiation, à la zlib crc32_combine) -------

fn gf2MatrixTimes(mat: *const [32]u32, vec: u32) u32 {
    var sum: u32 = 0;
    var v = vec;
    var i: usize = 0;
    while (v != 0) : (i += 1) {
        if (v & 1 != 0) sum ^= mat[i];
        v >>= 1;
    }
    return sum;
}

fn gf2MatrixSquare(square: *[32]u32, mat: *const [32]u32) void {
    for (0..32) |n| square[n] = gf2MatrixTimes(mat, mat[n]);
}

/// Combine `crc1` (over a leading block) with `crc2` (over a following block of
/// `len2` bytes) into the CRC of the concatenation — without touching the data.
pub fn combine(crc1: u32, crc2: u32, len2_in: u64) u32 {
    if (len2_in == 0) return crc1;

    var even: [32]u32 = undefined; // even-power-of-two zeros operator
    var odd: [32]u32 = undefined; // odd-power-of-two zeros operator

    // Put operator for one zero bit in `odd`.
    odd[0] = poly;
    var row: u32 = 1;
    for (1..32) |n| {
        odd[n] = row;
        row <<= 1;
    }

    gf2MatrixSquare(&even, &odd); // operator for two zero bits
    gf2MatrixSquare(&odd, &even); // operator for four zero bits

    var crc: u32 = crc1;
    var len2 = len2_in;
    // Apply len2 zeros to crc1 (first square will repeat at this point).
    while (true) {
        gf2MatrixSquare(&even, &odd);
        if (len2 & 1 != 0) crc = gf2MatrixTimes(&even, crc);
        len2 >>= 1;
        if (len2 == 0) break;

        gf2MatrixSquare(&odd, &even);
        if (len2 & 1 != 0) crc = gf2MatrixTimes(&odd, crc);
        len2 >>= 1;
        if (len2 == 0) break;
    }

    return crc ^ crc2;
}

test "crc32 known vectors" {
    try std.testing.expectEqual(@as(u32, 0x00000000), hash(""));
    // "123456789" -> 0xCBF43926 is the canonical CRC-32 check value.
    try std.testing.expectEqual(@as(u32, 0xCBF43926), hash("123456789"));
    // "The quick brown fox jumps over the lazy dog"
    try std.testing.expectEqual(@as(u32, 0x414FA339), hash("The quick brown fox jumps over the lazy dog"));
}

test "crc32 streaming equals one-shot" {
    const data = "The quick brown fox jumps over the lazy dog";
    var c = Crc32.init();
    c.update(data[0..10]);
    c.update(data[10..]);
    try std.testing.expectEqual(hash(data), c.final());
}

test "crc32 combine equals direct" {
    const data = "The quick brown fox jumps over the lazy dog";
    const split = 17;
    const c1 = hash(data[0..split]);
    const c2 = hash(data[split..]);
    const combined = combine(c1, c2, data.len - split);
    try std.testing.expectEqual(hash(data), combined);
}
