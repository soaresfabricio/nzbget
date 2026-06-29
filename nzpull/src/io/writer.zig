//! Output file handling: open once, write each decoded segment at its byte offset
//! via positional writes (`pwrite`), which are safe to issue concurrently from
//! multiple worker threads as long as the byte ranges don't overlap — matching
//! nzbget's "direct write" mode and letting us skip a final concatenation pass.

const std = @import("std");

pub const OutputFile = struct {
    file: std.fs.File,
    high_water: std.atomic.Value(u64) = .init(0),

    pub fn create(dir: std.fs.Dir, name: []const u8) !OutputFile {
        const file = try dir.createFile(name, .{ .truncate = true });
        return .{ .file = file };
    }

    pub fn writeAt(self: *OutputFile, offset: u64, data: []const u8) !void {
        try self.file.pwriteAll(data, offset);
        // Track furthest extent for an optional final truncate / reporting.
        const end = offset + data.len;
        var cur = self.high_water.load(.monotonic);
        while (end > cur) {
            const r = self.high_water.cmpxchgWeak(cur, end, .monotonic, .monotonic);
            if (r == null) break;
            cur = r.?;
        }
    }

    pub fn finalize(self: *OutputFile) void {
        self.file.sync() catch {};
        self.file.close();
    }
};

/// Reduce an arbitrary subject-derived name to a safe single path component.
pub fn sanitizeName(buf: []u8, name: []const u8) []const u8 {
    const base = std.fs.path.basename(name);
    var n: usize = 0;
    for (base) |c| {
        if (n == buf.len) break;
        buf[n] = switch (c) {
            '/', '\\', 0 => '_',
            else => c,
        };
        n += 1;
    }
    if (n == 0) {
        const fallback = "unnamed.bin";
        @memcpy(buf[0..fallback.len], fallback);
        return buf[0..fallback.len];
    }
    return buf[0..n];
}
