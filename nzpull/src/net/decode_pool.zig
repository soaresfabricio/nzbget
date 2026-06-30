//! Offloaded decode/write worker pool for the io_uring engine.
//!
//! The event loop submits raw (dot-unstuffed) article bodies; workers SIMD-decode
//! + CRC-verify them and pwrite to the output file at the segment offset, then
//! return the buffer to the pool and wake the loop via eventfd (a freed buffer may
//! unblock a back-pressured connection). Keeping this off the loop thread means a
//! slow disk or a busy core never stalls the network.

const std = @import("std");
const yenc = @import("../codec/yenc.zig");
const writer = @import("../io/writer.zig");
const bufpool = @import("../util/bufpool.zig");
const eventloop = @import("eventloop.zig");
const Stats = @import("client.zig").Stats;

pub const Task = struct {
    raw: *bufpool.Buffer,
    file_index: u32,
};

pub const DecodePool = struct {
    gpa: std.mem.Allocator,
    outputs: []writer.OutputFile,
    pool: *bufpool.BufPool,
    evt: eventloop.EventFd,

    mtx: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    queue: std.ArrayList(Task) = .empty,
    qhead: usize = 0,
    shutdown: bool = false,
    outstanding: std.atomic.Value(usize) = .init(0),

    ok: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(u64) = .init(0),
    crc_err: std.atomic.Value(u64) = .init(0),
    bytes: std.atomic.Value(u64) = .init(0),

    workers: []std.Thread = &.{},

    pub fn init(
        gpa: std.mem.Allocator,
        outputs: []writer.OutputFile,
        pool: *bufpool.BufPool,
        evt: eventloop.EventFd,
        n_workers: usize,
    ) !*DecodePool {
        const self = try gpa.create(DecodePool);
        self.* = .{ .gpa = gpa, .outputs = outputs, .pool = pool, .evt = evt };
        self.workers = try gpa.alloc(std.Thread, n_workers);
        var spawned: usize = 0;
        errdefer {
            self.requestShutdown();
            for (self.workers[0..spawned]) |t| t.join();
            gpa.free(self.workers);
            self.queue.deinit(gpa);
            gpa.destroy(self);
        }
        for (0..n_workers) |_| {
            self.workers[spawned] = try std.Thread.spawn(.{}, worker, .{self});
            spawned += 1;
        }
        return self;
    }

    /// Hand a raw article body off for decoding. Takes ownership of `task.raw`.
    pub fn submit(self: *DecodePool, task: Task) void {
        _ = self.outstanding.fetchAdd(1, .monotonic);
        self.mtx.lock();
        self.queue.append(self.gpa, task) catch {
            // Out of memory enqueuing: account as failure, return the buffer.
            self.mtx.unlock();
            self.pool.release(task.raw);
            _ = self.outstanding.fetchSub(1, .monotonic);
            _ = self.failed.fetchAdd(1, .monotonic);
            return;
        };
        self.mtx.unlock();
        self.cond.signal();
    }

    /// True when no tasks are queued or in flight.
    pub fn idle(self: *DecodePool) bool {
        return self.outstanding.load(.acquire) == 0;
    }

    fn requestShutdown(self: *DecodePool) void {
        self.mtx.lock();
        self.shutdown = true;
        self.mtx.unlock();
        self.cond.broadcast();
    }

    pub fn deinit(self: *DecodePool) void {
        self.requestShutdown();
        for (self.workers) |t| t.join();
        self.gpa.free(self.workers);
        self.queue.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn snapshot(self: *DecodePool) Stats {
        return .{
            .segments_ok = self.ok.load(.acquire),
            .segments_failed = self.failed.load(.acquire),
            .crc_errors = self.crc_err.load(.acquire),
            .bytes_written = self.bytes.load(.acquire),
        };
    }

    fn worker(self: *DecodePool) void {
        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(self.gpa);

        while (true) {
            self.mtx.lock();
            while (self.qhead == self.queue.items.len and !self.shutdown) {
                self.cond.wait(&self.mtx);
            }
            if (self.qhead == self.queue.items.len and self.shutdown) {
                self.mtx.unlock();
                return;
            }
            const task = self.queue.items[self.qhead];
            self.qhead += 1;
            if (self.qhead == self.queue.items.len) {
                self.queue.clearRetainingCapacity();
                self.qhead = 0;
            }
            self.mtx.unlock();

            self.process(task, &decoded);
            self.pool.release(task.raw);
            _ = self.outstanding.fetchSub(1, .release);
            self.evt.signal();
        }
    }

    fn process(self: *DecodePool, task: Task, decoded: *std.ArrayList(u8)) void {
        decoded.clearRetainingCapacity();
        const res = yenc.decodeBody(self.gpa, task.raw.items, decoded) catch {
            _ = self.failed.fetchAdd(1, .monotonic);
            return;
        };
        if (!res.crcOk()) {
            _ = self.failed.fetchAdd(1, .monotonic);
            _ = self.crc_err.fetchAdd(1, .monotonic);
            return;
        }
        self.outputs[task.file_index].writeAt(res.fileOffset(), decoded.items) catch {
            _ = self.failed.fetchAdd(1, .monotonic);
            return;
        };
        _ = self.ok.fetchAdd(1, .monotonic);
        _ = self.bytes.fetchAdd(res.bytes_written, .monotonic);
    }
};
