//! Compile-time CPU feature selection for the SIMD codec paths.
//!
//! Zig's `@Vector` lowers to the best instruction set the *build target* enables,
//! so the practical knob is the vector width. We pick it from the target features
//! (AVX2 → 32-byte lanes, SSE2/NEON → 16-byte lanes) via the std helper, which is
//! resolved at comptime. A runtime override hook is left for a future dynamic
//! dispatch layer (build for a baseline, branch to a wider kernel when detected).

const std = @import("std");
const builtin = @import("builtin");

/// Lanes for byte-wide SIMD on the current target. Falls back to 16 (a width
/// every supported arch handles well) when the target gives no hint.
pub const byte_lanes: usize = std.simd.suggestVectorLength(u8) orelse 16;

/// Human-readable description of the chosen backend, for --version / logs.
pub fn description() []const u8 {
    return std.fmt.comptimePrint("simd: {s} {d}-byte lanes", .{
        @tagName(builtin.cpu.arch),
        byte_lanes,
    });
}
