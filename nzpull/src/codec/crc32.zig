//! IEEE CRC-32 (reflected, polynomial 0xEDB88320) — the variant yEnc uses in its
//! `crc32=`/`pcrc32=` trailers. NOT CRC-32C, so the SSE4.2 `crc32` instruction is
//! unusable here; the SIMD route is PCLMULQDQ carry-less folding.
//!
//! `hash()` uses a fold-by-128 PCLMULQDQ loop on x86_64 (when the CPU has the
//! `pclmul` feature), falling back to a slice-by-8 table otherwise. All fold
//! constants are derived at comptime from the polynomial (no magic numbers) and
//! verified against the scalar implementation in tests. `combine()` stitches
//! per-segment CRCs without rehashing whole files.

const std = @import("std");
const builtin = @import("builtin");

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

/// One-shot CRC-32. Uses the PCLMULQDQ fold loop on capable x86_64, else the
/// scalar slice-by-8 path.
pub fn hash(data: []const u8) u32 {
    if (have_pclmul and data.len >= 32) return foldHash(data);
    var c = Crc32.init();
    c.update(data);
    return c.final();
}

// --- PCLMULQDQ fold-by-128 -----------------------------------------------------

const have_pclmul = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .pclmul);

/// Normal-domain x^n mod P (P = x^32 + 0x04C11DB7), used to derive fold consts.
fn xnModP(n: usize) u32 {
    var r: u32 = 1;
    for (0..n) |_| {
        const hi = (r >> 31) & 1;
        r = (r << 1) ^ (if (hi == 1) @as(u32, 0x04C11DB7) else 0);
    }
    return r;
}

fn reflect32(v: u32) u32 {
    var r: u32 = 0;
    for (0..32) |i| {
        if ((v >> @intCast(i)) & 1 == 1) r |= @as(u32, 1) << @intCast(31 - i);
    }
    return r;
}

/// Reflected fold constant for distance `n` bits: reflect32(x^n mod P) << 1.
fn foldK(comptime n: usize) u64 {
    @setEvalBranchQuota(20000);
    return @as(u64, reflect32(xnModP(n))) << 1;
}

/// Carry-less multiply of the low 64 bits of two operands via PCLMULQDQ.
inline fn clmul(a: u64, b: u64) u128 {
    const va: @Vector(2, u64) = .{ a, 0 };
    const vb: @Vector(2, u64) = .{ b, 0 };
    const r = asm ("pclmulqdq $0, %[b], %[a]"
        : [a] "=x" (-> @Vector(2, u64)),
        : [_] "0" (va),
          [b] "x" (vb),
    );
    return @bitCast(r);
}

fn lo64(x: u128) u64 {
    return @truncate(x);
}
fn hi64(x: u128) u64 {
    return @truncate(x >> 64);
}

fn rd128(p: []const u8) u128 {
    return std.mem.readInt(u128, p[0..16], .little);
}

// Fold constants, bound as container-level consts so the comptime derivation
// (a 500+ iteration loop) runs once at compile time rather than per call.
const K128_LO: u64 = foldK(128 + 32); // fold by 128, low/high halves
const K128_HI: u64 = foldK(128 - 64 + 32);
const K256_LO: u64 = foldK(256 + 32); // collapse distances for fold-by-4
const K256_HI: u64 = foldK(256 - 64 + 32);
const K384_LO: u64 = foldK(384 + 32);
const K384_HI: u64 = foldK(384 - 64 + 32);
const K512_LO: u64 = foldK(512 + 32); // fold-by-4 main step (512-bit advance)
const K512_HI: u64 = foldK(512 - 64 + 32);

/// Fold a 128-bit accumulator forward by `dist` bits (no new data added). The
/// +32 offset on the exponents accounts for the x^32 appended by CRC.
inline fn foldDist(a: u128, comptime klo: u64, comptime khi: u64) u128 {
    return clmul(lo64(a), klo) ^ clmul(hi64(a), khi);
}

/// Fold a 128-bit accumulator forward by 128 bits and add the next block.
inline fn foldNext(a: u128, next: u128) u128 {
    return foldDist(a, K128_LO, K128_HI) ^ next;
}

/// PCLMULQDQ CRC. Uses four independent 128-bit accumulators (fold-by-4, 64 bytes
/// per iteration) to hide clmul latency, collapses them, processes the remaining
/// 16-byte blocks, then reduces the final 128 bits with the scalar table (once).
fn foldHash(data: []const u8) u32 {
    var p = data;
    var acc: u128 = undefined;

    if (p.len >= 64) {
        // Inject the initial CRC into the first accumulator's low 32 bits.
        var a0: u128 = rd128(p[0..]) ^ 0xFFFFFFFF;
        var a1: u128 = rd128(p[16..]);
        var a2: u128 = rd128(p[32..]);
        var a3: u128 = rd128(p[48..]);
        p = p[64..];
        while (p.len >= 64) : (p = p[64..]) {
            // Fold each accumulator forward by 512 bits and add its new block.
            a0 = clmul(lo64(a0), K512_LO) ^ clmul(hi64(a0), K512_HI) ^ rd128(p[0..]);
            a1 = clmul(lo64(a1), K512_LO) ^ clmul(hi64(a1), K512_HI) ^ rd128(p[16..]);
            a2 = clmul(lo64(a2), K512_LO) ^ clmul(hi64(a2), K512_HI) ^ rd128(p[32..]);
            a3 = clmul(lo64(a3), K512_LO) ^ clmul(hi64(a3), K512_HI) ^ rd128(p[48..]);
        }
        // Collapse a0..a3 into one 128-bit value (a3 is the newest/highest).
        acc = a3 ^ foldDist(a0, K384_LO, K384_HI) ^
            foldDist(a1, K256_LO, K256_HI) ^ foldDist(a2, K128_LO, K128_HI);
    } else {
        acc = rd128(p[0..]) ^ 0xFFFFFFFF;
        p = p[16..];
    }

    // Remaining whole 16-byte blocks.
    while (p.len >= 16) : (p = p[16..]) acc = foldNext(acc, rd128(p));

    // The fold preserves CRC-equivalence, so the running CRC equals the table
    // CRC over the 16 bytes of `acc` (init 0). Runs once per call.
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &bytes, acc, .little);
    var crc: u32 = 0;
    for (bytes) |b| crc = tables[0][(crc ^ b) & 0xff] ^ (crc >> 8);
    for (p) |b| crc = tables[0][(crc ^ b) & 0xff] ^ (crc >> 8); // tail (< 16)
    return crc ^ 0xFFFFFFFF;
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

test "crc32 pclmul fold matches scalar for all lengths" {
    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u8, 1024);
    defer gpa.free(buf);
    var rng = std.Random.DefaultPrng.init(0x1234);
    rng.random().bytes(buf);

    var len: usize = 0;
    while (len <= 600) : (len += 1) {
        // Scalar reference (bypasses the pclmul dispatch in `hash`).
        var c = Crc32.init();
        c.update(buf[0..len]);
        const want = c.final();
        // `hash` takes the pclmul path when available for len >= 32.
        try std.testing.expectEqual(want, hash(buf[0..len]));
    }
}

test "crc32 combine equals direct" {
    const data = "The quick brown fox jumps over the lazy dog";
    const split = 17;
    const c1 = hash(data[0..split]);
    const c2 = hash(data[split..]);
    const combined = combine(c1, c2, data.len - split);
    try std.testing.expectEqual(hash(data), combined);
}
