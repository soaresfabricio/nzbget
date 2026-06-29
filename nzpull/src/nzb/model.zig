//! In-memory representation of a parsed NZB. All slices are owned by the arena
//! held in `Nzb`; freeing the arena frees the whole structure.

const std = @import("std");

pub const Segment = struct {
    /// 1-based part index within the file.
    number: u32,
    /// Encoded size in bytes as declared in the NZB (an estimate; the decoded
    /// size comes from the article itself).
    bytes: u64,
    /// Usenet Message-ID, without surrounding angle brackets.
    message_id: []const u8,
};

pub const File = struct {
    subject: []const u8,
    poster: []const u8 = "",
    groups: [][]const u8 = &.{},
    segments: []Segment = &.{},

    /// Sum of declared segment byte sizes.
    pub fn encodedBytes(self: File) u64 {
        var total: u64 = 0;
        for (self.segments) |s| total += s.bytes;
        return total;
    }

    /// Best-effort filename: the text inside the first pair of double quotes in
    /// the subject (the de-facto yEnc/Usenet convention), else the whole subject.
    pub fn fileName(self: File) []const u8 {
        if (std.mem.indexOfScalar(u8, self.subject, '"')) |start| {
            if (std.mem.indexOfScalarPos(u8, self.subject, start + 1, '"')) |end| {
                return self.subject[start + 1 .. end];
            }
        }
        return self.subject;
    }
};

pub const Nzb = struct {
    arena: std.heap.ArenaAllocator,
    files: []File,

    pub fn deinit(self: *Nzb) void {
        self.arena.deinit();
    }

    pub fn totalEncodedBytes(self: Nzb) u64 {
        var total: u64 = 0;
        for (self.files) |f| total += f.encodedBytes();
        return total;
    }

    pub fn segmentCount(self: Nzb) usize {
        var n: usize = 0;
        for (self.files) |f| n += f.segments.len;
        return n;
    }
};
