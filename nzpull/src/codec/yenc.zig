//! yEnc decoder.
//!
//! yEnc encodes each byte as `(b + 42) mod 256`, escaping the few bytes that would
//! be unsafe on Usenet (NUL, CR, LF, '=') as `'=' , (b + 64 + 42) mod 256`. The
//! decoder therefore subtracts 42 from every byte, except the byte following an
//! '=' which has an extra 64 subtracted. CR/LF (line framing) are dropped.
//!
//! The common case — a run of bytes with no escape — is a single vector subtract.
//! Escapes are rare, so chunks containing '=' fall back to a scalar walk. A pure
//! scalar reference (`decodeBodyScalar`) backs the SIMD path in tests and the
//! `-Ddecoder=scalar` build.

const std = @import("std");
const cpu = @import("cpu.zig");
const Crc32 = @import("crc32.zig").Crc32;

pub const Error = error{ MalformedHeader, OutOfMemory };

pub const Header = struct {
    name: []const u8 = "",
    size: u64 = 0,
    part: ?u32 = null,
    total: ?u32 = null,
    begin: ?u64 = null, // 1-based byte offset of this part within the file
    end: ?u64 = null,
};

pub const DecodeResult = struct {
    header: Header,
    /// Number of decoded bytes appended to the output buffer.
    bytes_written: usize,
    /// CRC-32 of the decoded bytes of this part.
    crc32: u32,
    /// Expected CRC from the `=yend` trailer (pcrc32 for multipart, else crc32).
    expected_crc32: ?u32,
    /// `size=` reported in the `=yend` trailer, if present.
    end_size: ?u64,

    pub fn crcOk(self: DecodeResult) bool {
        return if (self.expected_crc32) |e| e == self.crc32 else true;
    }

    /// 0-based byte offset where this part's data belongs in the output file.
    pub fn fileOffset(self: DecodeResult) u64 {
        return if (self.header.begin) |b| b - 1 else 0;
    }
};

const lanes = cpu.byte_lanes;
const Vec = @Vector(lanes, u8);

/// SIMD decode of a full yEnc article body into `out`. Returns part metadata and
/// the freshly computed CRC over the decoded bytes.
pub fn decodeBody(
    gpa: std.mem.Allocator,
    body: []const u8,
    out: *std.ArrayList(u8),
) Error!DecodeResult {
    return decodeImpl(gpa, body, out, true);
}

/// Scalar reference decoder. Same contract as `decodeBody`.
pub fn decodeBodyScalar(
    gpa: std.mem.Allocator,
    body: []const u8,
    out: *std.ArrayList(u8),
) Error!DecodeResult {
    return decodeImpl(gpa, body, out, false);
}

fn decodeImpl(
    gpa: std.mem.Allocator,
    body: []const u8,
    out: *std.ArrayList(u8),
    comptime simd: bool,
) Error!DecodeResult {
    var header: Header = .{};
    var expected_crc: ?u32 = null;
    var end_size: ?u64 = null;
    const start_len = out.items.len;
    var crc = Crc32.init();
    var pending_escape = false;

    // Decoded output is always <= encoded body length, so one reservation up
    // front lets the inner loops write with `assumeCapacity` (no bounds checks).
    try out.ensureUnusedCapacity(gpa, body.len);

    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw_line| {
        // Strip a trailing CR (CRLF framing).
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "=ybegin")) {
            try parseBegin(line, &header);
        } else if (std.mem.startsWith(u8, line, "=ypart")) {
            parsePart(line, &header);
        } else if (std.mem.startsWith(u8, line, "=yend")) {
            parseEnd(line, &expected_crc, &end_size);
            break;
        } else {
            // Data line: decode into the pre-reserved tail of `out`.
            const before = out.items.len;
            if (simd) {
                decodeLineSimd(line, out, &pending_escape);
            } else {
                decodeLineScalar(line, out, &pending_escape);
            }
            crc.update(out.items[before..]);
        }
    }

    return .{
        .header = header,
        .bytes_written = out.items.len - start_len,
        .crc32 = crc.final(),
        .expected_crc32 = expected_crc,
        .end_size = end_size,
    };
}

/// Decode an arbitrary byte range, carrying an escape across the boundary.
/// Shared by the scalar decoder, the SIMD tail, and dense-escape lanes.
inline fn decodeScalarRange(
    bytes: []const u8,
    out: *std.ArrayList(u8),
    pending_escape: *bool,
) void {
    for (bytes) |b| {
        if (pending_escape.*) {
            out.appendAssumeCapacity(b -% 106); // -64 -42
            pending_escape.* = false;
        } else if (b == '=') {
            pending_escape.* = true;
        } else {
            out.appendAssumeCapacity(b -% 42);
        }
    }
}

fn decodeLineScalar(
    line: []const u8,
    out: *std.ArrayList(u8),
    pending_escape: *bool,
) void {
    decodeScalarRange(line, out, pending_escape);
}

/// Integer bitmask: bit i set iff lane byte i equals '='. AVX2/SSE/NEON lower
/// the comparison to a single instruction; the bitcast is the movemask.
const LaneMask = std.meta.Int(.unsigned, lanes);

fn decodeLineSimd(
    line: []const u8,
    out: *std.ArrayList(u8),
    pending_escape: *bool,
) void {
    var i: usize = 0;
    const eq_splat: Vec = @splat('=');
    const sub42: Vec = @splat(42);

    while (i + lanes <= line.len) {
        // A dangling escape from the previous lane consumes one byte first.
        if (pending_escape.*) {
            out.appendAssumeCapacity(line[i] -% 106);
            pending_escape.* = false;
            i += 1;
            continue;
        }
        const chunk: Vec = line[i..][0..lanes].*;
        const eqmask: LaneMask = @bitCast(chunk == eq_splat);
        // Always subtract 42 across the whole lane; escapes get a +(-64) fixup.
        const decoded: Vec = chunk -% sub42;
        if (eqmask == 0) {
            // Hot path: no escapes — emit the whole lane.
            out.appendSliceAssumeCapacity(&@as([lanes]u8, decoded));
            i += lanes;
            continue;
        }
        if (@popCount(eqmask) * 4 > lanes) {
            // Dense escapes: the per-escape compaction loop loses to a tight
            // scalar walk — take it (keeps SIMD from regressing on such data).
            decodeScalarRange(line[i..][0..lanes], out, pending_escape);
            i += lanes;
            continue;
        }
        // Sparse escapes: emit the decoded lane minus the '=' markers, applying
        // the extra -64 to each byte that followed a '='. Clean runs between
        // escapes are copied in bulk, located via the bitmask.
        emitWithEscapes(&@as([lanes]u8, decoded), eqmask, out, pending_escape);
        i += lanes;
    }

    // Scalar tail (and any line shorter than a lane).
    decodeScalarRange(line[i..], out, pending_escape);
}

/// Emit one lane that contains at least one '='. `decoded` is the lane already
/// reduced by 42; `raw` is the original lane (to detect the '=' positions). Clean
/// runs between escapes are copied in bulk; each escaped pair becomes one byte.
inline fn emitWithEscapes(
    decoded: *const [lanes]u8,
    eqmask_in: LaneMask,
    out: *std.ArrayList(u8),
    pending_escape: *bool,
) void {
    var pos: usize = 0;
    var eqmask = eqmask_in;
    while (eqmask != 0) {
        const e: usize = @ctz(eqmask); // index of next '='
        // Copy the clean run [pos, e) verbatim.
        if (e > pos) out.appendSliceAssumeCapacity(decoded[pos..e]);
        if (e + 1 < lanes) {
            // The byte after '=' is escaped: it was reduced by 42, now -64 more.
            out.appendAssumeCapacity(decoded[e + 1] -% 64);
            pos = e + 2;
            // Consume this '=' and the escaped byte's bit (the latter can't be a
            // real '=' in a valid stream, but stay robust to malformed input).
            const consumed = (@as(LaneMask, 1) << @intCast(e)) |
                (@as(LaneMask, 1) << @intCast(e + 1));
            eqmask &= ~consumed;
        } else {
            // '=' is the last byte of the lane: the escape straddles into the
            // next lane — remember it and stop.
            pending_escape.* = true;
            pos = lanes;
            break;
        }
    }
    if (pos < lanes) out.appendSliceAssumeCapacity(decoded[pos..lanes]);
}

// --- header / trailer parsing -------------------------------------------------

fn fieldU64(line: []const u8, key: []const u8) ?u64 {
    // Find " key=" (or "key=" at start) and parse the following integer token.
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, line, idx, key)) |pos| {
        const after = pos + key.len;
        // Ensure the match is preceded by start/space and followed by '='.
        const left_ok = pos == 0 or line[pos - 1] == ' ';
        if (left_ok and after < line.len and line[after] == '=') {
            const val_start = after + 1;
            var val_end = val_start;
            while (val_end < line.len and line[val_end] != ' ') : (val_end += 1) {}
            return std.fmt.parseInt(u64, line[val_start..val_end], 10) catch null;
        }
        idx = pos + 1;
    }
    return null;
}

fn fieldHex(line: []const u8, key: []const u8) ?u32 {
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, line, idx, key)) |pos| {
        const after = pos + key.len;
        const left_ok = pos == 0 or line[pos - 1] == ' ';
        if (left_ok and after < line.len and line[after] == '=') {
            const val_start = after + 1;
            var val_end = val_start;
            while (val_end < line.len and line[val_end] != ' ') : (val_end += 1) {}
            return std.fmt.parseInt(u32, line[val_start..val_end], 16) catch null;
        }
        idx = pos + 1;
    }
    return null;
}

fn parseBegin(line: []const u8, header: *Header) Error!void {
    header.part = if (fieldU64(line, "part")) |p| @intCast(p) else null;
    header.total = if (fieldU64(line, "total")) |t| @intCast(t) else null;
    header.size = fieldU64(line, "size") orelse 0;
    // name= runs to end of line (filenames may contain spaces).
    if (std.mem.indexOf(u8, line, "name=")) |pos| {
        header.name = std.mem.trimRight(u8, line[pos + 5 ..], " \r");
    }
}

fn parsePart(line: []const u8, header: *Header) void {
    header.begin = fieldU64(line, "begin");
    header.end = fieldU64(line, "end");
}

fn parseEnd(line: []const u8, expected_crc: *?u32, end_size: *?u64) void {
    end_size.* = fieldU64(line, "size");
    // Prefer pcrc32 (this part) over crc32 (whole file) for per-part validation.
    if (fieldHex(line, "pcrc32")) |c| {
        expected_crc.* = c;
    } else if (fieldHex(line, "crc32")) |c| {
        expected_crc.* = c;
    }
}

// --- tests --------------------------------------------------------------------

const testing = std.testing;

/// Encode bytes as a single-part yEnc body (for round-trip tests).
fn encode(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    const crc = @import("crc32.zig").hash(data);
    try buf.writer(gpa).print("=ybegin line=128 size={d} name=test.bin\r\n", .{data.len});
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
    try buf.writer(gpa).print("\r\n=yend size={d} crc32={x:0>8}\r\n", .{ data.len, crc });
    return buf.toOwnedSlice(gpa);
}

fn roundTrip(data: []const u8) !void {
    const gpa = testing.allocator;
    const body = try encode(gpa, data);
    defer gpa.free(body);

    inline for (.{ true, false }) |use_simd| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        const res = if (use_simd)
            try decodeBody(gpa, body, &out)
        else
            try decodeBodyScalar(gpa, body, &out);
        try testing.expectEqualSlices(u8, data, out.items);
        try testing.expect(res.crcOk());
        try testing.expectEqual(data.len, res.bytes_written);
    }
}

test "yenc round-trip: simple ascii" {
    try roundTrip("Hello, Usenet! The quick brown fox.");
}

test "yenc round-trip: all 256 byte values (exercises escapes)" {
    var data: [256]u8 = undefined;
    for (&data, 0..) |*p, i| p.* = @intCast(i);
    try roundTrip(&data);
}

test "yenc round-trip: large buffer crosses lanes and lines" {
    const gpa = testing.allocator;
    const data = try gpa.alloc(u8, 100_000);
    defer gpa.free(data);
    var rng = std.Random.DefaultPrng.init(0xfeed);
    rng.random().bytes(data);
    try roundTrip(data);
}

test "yenc detects crc mismatch" {
    const gpa = testing.allocator;
    var body = try encode(gpa, "payload");
    defer gpa.free(body);
    // Corrupt the trailing crc hex digit.
    body[body.len - 3] = if (body[body.len - 3] == '0') '1' else '0';
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const res = try decodeBody(gpa, body, &out);
    try testing.expect(!res.crcOk());
}

test "yenc multipart header parse" {
    const gpa = testing.allocator;
    const body =
        "=ybegin part=2 total=5 line=128 size=500000 name=big file.rar\r\n" ++
        "=ypart begin=128001 end=256000\r\n" ++
        "\x6a\x6b\x6c\r\n" ++ // 'B','C','D' encoded (0x6a-42=0x40='@'...)
        "=yend size=128000 part=2 pcrc32=00000000\r\n";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const res = try decodeBody(gpa, body, &out);
    try testing.expectEqualStrings("big file.rar", res.header.name);
    try testing.expectEqual(@as(?u32, 2), res.header.part);
    try testing.expectEqual(@as(?u64, 128001), res.header.begin);
    try testing.expectEqual(@as(u64, 128000), res.fileOffset());
}
