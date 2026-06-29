//! Streaming NZB parser.
//!
//! NZB is a small, regular XML dialect, so rather than pull in libxml2 (as the
//! C++ nzbget does) we scan the document with a tiny tag tokenizer and extract
//! exactly the elements we need: <file> (subject/poster), <group>, and <segment>
//! (number/bytes/message-id). Everything is allocated in the returned arena.

const std = @import("std");
const model = @import("model.zig");

pub const Error = error{ Malformed, OutOfMemory };

pub fn parse(gpa: std.mem.Allocator, xml: []const u8) Error!model.Nzb {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var files: std.ArrayList(model.File) = .empty;

    var cur_groups: std.ArrayList([]const u8) = .empty;
    var cur_segments: std.ArrayList(model.Segment) = .empty;
    var cur_subject: []const u8 = "";
    var cur_poster: []const u8 = "";
    var in_file = false;

    // Pending segment attributes between the <segment ...> tag and its text.
    var seg_number: u32 = 0;
    var seg_bytes: u64 = 0;

    var p: usize = 0;
    while (std.mem.indexOfScalarPos(u8, xml, p, '<')) |lt| {
        const gt = std.mem.indexOfScalarPos(u8, xml, lt + 1, '>') orelse break;
        const inner = xml[lt + 1 .. gt]; // tag contents without < >
        p = gt + 1;

        if (inner.len == 0 or inner[0] == '?' or inner[0] == '!') continue; // decl/comment

        const closing = inner[0] == '/';
        const name = tagName(if (closing) inner[1..] else inner);

        if (!closing and eql(name, "file")) {
            in_file = true;
            cur_groups = .empty;
            cur_segments = .empty;
            cur_subject = try unescape(a, attr(inner, "subject") orelse "");
            cur_poster = try unescape(a, attr(inner, "poster") orelse "");
        } else if (closing and eql(name, "file")) {
            if (in_file) {
                try files.append(a, .{
                    .subject = cur_subject,
                    .poster = cur_poster,
                    .groups = try cur_groups.toOwnedSlice(a),
                    .segments = try cur_segments.toOwnedSlice(a),
                });
            }
            in_file = false;
        } else if (!closing and eql(name, "group")) {
            // <group>text</group>
            if (textUntilClose(xml, p, "group")) |t| {
                try cur_groups.append(a, try unescape(a, t));
            }
        } else if (!closing and eql(name, "segment")) {
            seg_number = if (attr(inner, "number")) |v|
                std.fmt.parseInt(u32, v, 10) catch 0
            else
                0;
            seg_bytes = if (attr(inner, "bytes")) |v|
                std.fmt.parseInt(u64, v, 10) catch 0
            else
                0;
            // Self-closing <segment .../> has no message-id text — skip it.
            if (inner[inner.len - 1] != '/') {
                if (textUntilClose(xml, p, "segment")) |t| {
                    const id = std.mem.trim(u8, t, " \t\r\n");
                    // Resolve entities first, then strip any <...> brackets.
                    const unescaped = try unescape(a, id);
                    try cur_segments.append(a, .{
                        .number = seg_number,
                        .bytes = seg_bytes,
                        .message_id = stripBrackets(unescaped),
                    });
                }
            }
        }
    }

    return .{ .arena = arena, .files = try files.toOwnedSlice(a) };
}

fn tagName(inner: []const u8) []const u8 {
    var end: usize = 0;
    while (end < inner.len and inner[end] != ' ' and inner[end] != '\t' and
        inner[end] != '/' and inner[end] != '>' and inner[end] != '\n' and inner[end] != '\r') : (end += 1)
    {}
    return inner[0..end];
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Extract attribute value: matches `key="..."` or `key='...'` within a tag.
fn attr(inner: []const u8, key: []const u8) ?[]const u8 {
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, inner, idx, key)) |pos| {
        const after = pos + key.len;
        const left_ok = pos == 0 or inner[pos - 1] == ' ' or inner[pos - 1] == '\t';
        if (left_ok and after < inner.len and inner[after] == '=') {
            const q = inner[after + 1];
            if (q == '"' or q == '\'') {
                const vs = after + 2;
                const ve = std.mem.indexOfScalarPos(u8, inner, vs, q) orelse return null;
                return inner[vs..ve];
            }
        }
        idx = pos + 1;
    }
    return null;
}

/// Return the text between the current position and the matching close tag.
fn textUntilClose(xml: []const u8, from: usize, name: []const u8) ?[]const u8 {
    const lt = std.mem.indexOfScalarPos(u8, xml, from, '<') orelse return null;
    _ = name;
    return std.mem.trim(u8, xml[from..lt], " \t\r\n");
}

fn stripBrackets(s: []const u8) []const u8 {
    var r = s;
    if (r.len >= 2 and r[0] == '<' and r[r.len - 1] == '>') r = r[1 .. r.len - 1];
    return r;
}

/// Resolve the five predefined XML entities. Allocates only when needed.
fn unescape(a: std.mem.Allocator, s: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return try a.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            if (std.mem.startsWith(u8, s[i..], "&amp;")) {
                try out.append(a, '&');
                i += 5;
            } else if (std.mem.startsWith(u8, s[i..], "&lt;")) {
                try out.append(a, '<');
                i += 4;
            } else if (std.mem.startsWith(u8, s[i..], "&gt;")) {
                try out.append(a, '>');
                i += 4;
            } else if (std.mem.startsWith(u8, s[i..], "&quot;")) {
                try out.append(a, '"');
                i += 6;
            } else if (std.mem.startsWith(u8, s[i..], "&apos;")) {
                try out.append(a, '\'');
                i += 6;
            } else {
                try out.append(a, s[i]);
                i += 1;
            }
        } else {
            try out.append(a, s[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(a);
}

// --- tests --------------------------------------------------------------------

const testing = std.testing;

const sample =
    \\<?xml version="1.0" encoding="iso-8859-1" ?>
    \\<!DOCTYPE nzb PUBLIC "-//newzBin//DTD NZB 1.1//EN" "http://www.newzbin.com/DTD/nzb/nzb-1.1.dtd">
    \\<nzb xmlns="http://www.newzbin.com/DTD/2003/nzb">
    \\  <file poster="me &amp; you" date="1240256" subject="[1/2] - &quot;movie.part01.rar&quot; yEnc (1/3)">
    \\    <groups>
    \\      <group>alt.binaries.test</group>
    \\      <group>alt.binaries.misc</group>
    \\    </groups>
    \\    <segments>
    \\      <segment bytes="102400" number="1">&lt;abc123@news&gt;</segment>
    \\      <segment bytes="102400" number="2">part2@news</segment>
    \\    </segments>
    \\  </file>
    \\</nzb>
;

test "parse sample nzb" {
    const gpa = testing.allocator;
    var nzb = try parse(gpa, sample);
    defer nzb.deinit();

    try testing.expectEqual(@as(usize, 1), nzb.files.len);
    const f = nzb.files[0];
    try testing.expectEqualStrings("me & you", f.poster);
    try testing.expectEqualStrings("movie.part01.rar", f.fileName());
    try testing.expectEqual(@as(usize, 2), f.groups.len);
    try testing.expectEqualStrings("alt.binaries.test", f.groups[0]);
    try testing.expectEqual(@as(usize, 2), f.segments.len);
    try testing.expectEqualStrings("abc123@news", f.segments[0].message_id);
    try testing.expectEqual(@as(u64, 102400), f.segments[0].bytes);
    try testing.expectEqual(@as(u32, 2), f.segments[1].number);
    try testing.expectEqualStrings("part2@news", f.segments[1].message_id);
    try testing.expectEqual(@as(u64, 204800), nzb.totalEncodedBytes());
    try testing.expectEqual(@as(usize, 2), nzb.segmentCount());
}

test "parse empty/garbage is not a crash" {
    const gpa = testing.allocator;
    var nzb = try parse(gpa, "not really xml");
    defer nzb.deinit();
    try testing.expectEqual(@as(usize, 0), nzb.files.len);
}
