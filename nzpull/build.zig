const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -Ddecoder=native|scalar|rapidyenc selects the yEnc/CRC backend.
    // (rapidyenc is reserved for a future C binding; native/scalar are built in.)
    const decoder = b.option(
        []const u8,
        "decoder",
        "yEnc/CRC backend: native (default), scalar, rapidyenc",
    ) orelse "native";

    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "decoder", decoder);

    // Core library module: all of NZpull's logic, importable by exe/tests/bench.
    const core = b.addModule("nzpull", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    core.addOptions("build_options", build_opts);

    // CLI executable.
    const exe = b.addExecutable(.{
        .name = "nzpull",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nzpull", .module = core }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the nzpull CLI");
    run_step.dependOn(&run_cmd.step);

    // Tests: run all `test` blocks reachable from the core module plus the
    // dedicated tests/ files.
    const test_step = b.step("test", "Run unit tests");

    const core_tests = b.addTest(.{ .root_module = core });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    const test_files = [_][]const u8{
        "tests/yenc_vectors.zig",
        "tests/crc32_vectors.zig",
        "tests/nntp_mock.zig",
    };
    for (test_files) |tf| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(tf),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "nzpull", .module = core }},
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Benchmark: decode throughput, native vs scalar.
    const bench = b.addExecutable(.{
        .name = "nzpull-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/decode_bench.zig"),
            .target = target,
            // Benchmarks are meaningless in Debug; force ReleaseFast.
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "nzpull", .module = core }},
        }),
    });
    const bench_run = b.addRunArtifact(bench);
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Run the decode benchmark (ReleaseFast)");
    bench_step.dependOn(&bench_run.step);
}
