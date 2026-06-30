//! NZpull CLI.
//!
//! Usage:
//!   nzpull <file.nzb> [options]
//!
//! Options:
//!   --out DIR        output directory (default: .)
//!   --host HOST      news server host         (env NZPULL_HOST)
//!   --port PORT      server port (default 119, or 563 with --tls)
//!   --user USER      username                 (env NZPULL_USER)
//!   --pass PASS      password                 (env NZPULL_PASS)
//!   --tls            use TLS (port defaults to 563)
//!   --conn N         connections (default 8)
//!   --depth D        pipeline depth per connection (default 4)
//!   --info           parse the NZB and print a summary only (no download)

const std = @import("std");
const builtin = @import("builtin");
const nzpull = @import("nzpull");

const Args = struct {
    nzb_path: ?[]const u8 = null,
    out: []const u8 = ".",
    host: ?[]const u8 = null,
    port: ?u16 = null,
    user: ?[]const u8 = null,
    pass: ?[]const u8 = null,
    tls: bool = false,
    conn: u32 = 8,
    depth: u32 = 4,
    engine: []const u8 = "threads",
    info_only: bool = false,
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);

    var env = try std.process.getEnvMap(gpa);
    defer env.deinit();

    var args = Args{};
    args.host = env.get("NZPULL_HOST");
    args.user = env.get("NZPULL_USER");
    args.pass = env.get("NZPULL_PASS");

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--out")) {
            i += 1;
            args.out = argv[i];
        } else if (std.mem.eql(u8, a, "--host")) {
            i += 1;
            args.host = argv[i];
        } else if (std.mem.eql(u8, a, "--port")) {
            i += 1;
            args.port = try std.fmt.parseInt(u16, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--user")) {
            i += 1;
            args.user = argv[i];
        } else if (std.mem.eql(u8, a, "--pass")) {
            i += 1;
            args.pass = argv[i];
        } else if (std.mem.eql(u8, a, "--tls")) {
            args.tls = true;
        } else if (std.mem.eql(u8, a, "--conn")) {
            i += 1;
            args.conn = try std.fmt.parseInt(u32, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--depth")) {
            i += 1;
            args.depth = try std.fmt.parseInt(u32, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--engine")) {
            i += 1;
            args.engine = argv[i];
        } else if (std.mem.eql(u8, a, "--info")) {
            args.info_only = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try printUsage();
            return;
        } else if (a.len > 0 and a[0] != '-') {
            args.nzb_path = a;
        }
    }

    const stdout = std.fs.File.stdout();
    var out_buf: [4096]u8 = undefined;
    var w = stdout.writer(&out_buf);
    const o = &w.interface;

    if (args.nzb_path == null) {
        try printUsage();
        return error.MissingNzbPath;
    }

    // Read and parse the NZB.
    const xml = std.fs.cwd().readFileAlloc(gpa, args.nzb_path.?, 256 * 1024 * 1024) catch |err| {
        try o.print("error: cannot read {s}: {s}\n", .{ args.nzb_path.?, @errorName(err) });
        try o.flush();
        return err;
    };
    defer gpa.free(xml);

    var nzb = try nzpull.parser.parse(gpa, xml);
    defer nzb.deinit();

    try o.print("NZpull 0.1.0  ({s})\n", .{nzpull.cpu.description()});
    try o.print("parsed: {d} file(s), {d} segment(s), {d:.1} MiB encoded\n", .{
        nzb.files.len,
        nzb.segmentCount(),
        @as(f64, @floatFromInt(nzb.totalEncodedBytes())) / (1024.0 * 1024.0),
    });

    if (args.info_only or args.host == null) {
        if (args.host == null and !args.info_only)
            try o.print("no --host/NZPULL_HOST set; printing summary only.\n", .{});
        for (nzb.files) |f| {
            try o.print("  - {s}  ({d} segs)\n", .{ f.fileName(), f.segments.len });
        }
        try o.flush();
        return;
    }

    // Prepare output directory.
    std.fs.cwd().makePath(args.out) catch {};
    var out_dir = try std.fs.cwd().openDir(args.out, .{});
    defer out_dir.close();

    const port: u16 = args.port orelse (if (args.tls) @as(u16, 563) else 119);
    const cfg = nzpull.client.ServerConfig{
        .host = args.host.?,
        .port = port,
        .user = args.user,
        .pass = args.pass,
        .tls = args.tls,
        .connections = args.conn,
        .pipeline_depth = args.depth,
    };

    // Engine selection. The io_uring engine is Linux/TCP-only; TLS, non-Linux, or
    // an unavailable ring all route to the thread engine.
    var use_iouring = std.mem.eql(u8, args.engine, "iouring");
    if (use_iouring and builtin.os.tag != .linux) {
        try o.print("note: io_uring engine is Linux-only; using thread engine\n", .{});
        use_iouring = false;
    }
    if (use_iouring and cfg.tls) {
        try o.print("note: io_uring engine does not support TLS; using thread engine\n", .{});
        use_iouring = false;
    }
    if (use_iouring) {
        if (nzpull.eventloop.Loop.init(8)) |probe| {
            var p = probe;
            p.deinit();
        } else |err| {
            try o.print("note: io_uring unavailable ({s}); using thread engine\n", .{@errorName(err)});
            use_iouring = false;
        }
    }

    try o.print("downloading from {s}:{d} ({d} conns, depth {d}, {s}{s})...\n", .{
        cfg.host, cfg.port, cfg.connections, cfg.pipeline_depth,
        if (use_iouring) "io_uring" else "threads",
        if (cfg.tls) ", tls" else "",
    });
    try o.flush();

    var timer = try std.time.Timer.start();
    const stats = if (use_iouring)
        try nzpull.io_engine.download(gpa, nzb, out_dir, cfg)
    else
        try nzpull.client.download(gpa, nzb, out_dir, cfg);
    const elapsed_ns = timer.read();
    const secs = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const mib = @as(f64, @floatFromInt(stats.bytes_written)) / (1024.0 * 1024.0);

    try o.print("done: {d} ok, {d} failed ({d} crc), {d:.1} MiB in {d:.2}s = {d:.1} MiB/s\n", .{
        stats.segments_ok, stats.segments_failed, stats.crc_errors, mib, secs,
        if (secs > 0) mib / secs else 0,
    });
    try o.flush();
}

fn printUsage() !void {
    const stdout = std.fs.File.stdout();
    var buf: [2048]u8 = undefined;
    var w = stdout.writer(&buf);
    const o = &w.interface;
    try o.writeAll(
        \\NZpull — high-performance Zig NZB downloader
        \\
        \\Usage: nzpull <file.nzb> [options]
        \\
        \\  --out DIR     output directory (default: .)
        \\  --host HOST   news server host         (env NZPULL_HOST)
        \\  --port PORT   server port (default 119, 563 with --tls)
        \\  --user USER   username                 (env NZPULL_USER)
        \\  --pass PASS   password                 (env NZPULL_PASS)
        \\  --tls         use TLS
        \\  --conn N      connections (default 8)
        \\  --depth D     pipeline depth per connection (default 4)
        \\  --engine E    threads (default) or iouring (Linux, non-TLS)
        \\  --info        parse and summarize only, no download
        \\
    );
    try o.flush();
}
