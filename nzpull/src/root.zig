//! NZpull core library — a high-performance Zig NZB downloader.
//! Public surface re-exported for the CLI, tests, and benchmarks.

pub const model = @import("nzb/model.zig");
pub const parser = @import("nzb/parser.zig");

pub const crc32 = @import("codec/crc32.zig");
pub const yenc = @import("codec/yenc.zig");
pub const cpu = @import("codec/cpu.zig");

pub const nntp = @import("net/nntp.zig");
pub const transport = @import("net/transport.zig");
pub const client = @import("net/client.zig");

pub const writer = @import("io/writer.zig");

test {
    // Pull in tests from every module.
    @import("std").testing.refAllDeclsRecursive(@This());
}
