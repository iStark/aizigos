//! Processes: an address space, capability ownership and threads.
//!
//! A process is the unit of isolation (FR-1.2) and of token ownership (FR-2.1).
//! On termination the kernel frees memory AND revokes all of its tokens,
//! including the ones it derived for others; otherwise delegated access would
//! outlive the agent that granted it.

const std = @import("std");
const vmm = @import("../mm/vmm.zig");
const pmm = @import("../mm/pmm.zig");
const cap = @import("../cap/cap.zig");
const sched = @import("../sched/sched.zig");

pub const Pid = cap.ProcId;

pub const Error = error{
    TableFull,
    NoSuchProcess,
    TooManyThreads,
    SpaceInitFailed,
};

pub const State = enum(u8) { starting, running, stopped, zombie };

pub const max_threads_per_process = 4;

pub const Process = struct {
    pid: Pid = 0,
    parent: Pid = 0,
    name: [24]u8 = @splat(0),
    name_len: u8 = 0,
    state: State = .zombie,
    used: bool = false,
    space: vmm.AddressSpace = .{},
    threads: [max_threads_per_process]sched.Tid = @splat(0),
    thread_count: u8 = 0,
    /// Default scheduling class for the threads of this process.
    class: sched.Class = .normal,

    pub fn nameText(self: *const Process) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Spawn = struct {
    name: []const u8 = "",
    parent: Pid = 0,
    class: sched.Class = .normal,
};

pub const ThreadSpec = struct {
    name: []const u8 = "",
    entry: usize = 0,
    arg: usize = 0,
    stack_top: u64 = 0,
    stack_base: u64 = 0,
    stack_pages: usize = 0,
};

pub fn Table(comptime max_processes: usize) type {
    return struct {
        const Self = @This();

        procs: [max_processes]Process = @splat(.{}),
        next_pid: Pid = 1,

        pub fn init() Self {
            return .{};
        }

        pub fn get(self: *Self, pid: Pid) ?*Process {
            for (&self.procs) |*p| {
                if (p.used and p.pid == pid) return p;
            }
            return null;
        }

        pub fn create(self: *Self, spawn: Spawn) Error!Pid {
            for (&self.procs) |*p| {
                if (p.used) continue;
                p.* = .{
                    .pid = self.next_pid,
                    .parent = spawn.parent,
                    .state = .starting,
                    .used = true,
                    .class = spawn.class,
                };
                const n = @min(spawn.name.len, p.name.len);
                @memcpy(p.name[0..n], spawn.name[0..n]);
                p.name_len = @intCast(n);
                p.space.init() catch {
                    p.* = .{};
                    return Error.SpaceInitFailed;
                };
                self.next_pid += 1;
                return p.pid;
            }
            return Error.TableFull;
        }

        /// Create a thread of the process and enqueue it in the scheduler.
        pub fn addThread(self: *Self, scheduler: anytype, pid: Pid, spec: ThreadSpec) !sched.Tid {
            const p = self.get(pid) orelse return Error.NoSuchProcess;
            if (p.thread_count == max_threads_per_process) return Error.TooManyThreads;
            const tid = try scheduler.spawn(.{
                .name = spec.name,
                .class = p.class,
                .entry = spec.entry,
                .arg = spec.arg,
                .stack_top = spec.stack_top,
                .stack_base = spec.stack_base,
                .stack_pages = spec.stack_pages,
            });
            p.threads[p.thread_count] = tid;
            p.thread_count += 1;
            p.state = .running;
            return tid;
        }

        /// Terminate: drop threads, free memory, revoke every token.
        pub fn terminate(
            self: *Self,
            scheduler: anytype,
            registry: anytype,
            frames: *pmm.Pmm,
            pid: Pid,
            now_ns: u64,
        ) Error!usize {
            const p = self.get(pid) orelse return Error.NoSuchProcess;
            var i: usize = 0;
            while (i < p.thread_count) : (i += 1) {
                const tid = p.threads[i];
                // The stack goes back to the PMM: the scheduler only tracks it.
                if (scheduler.task(tid)) |t| {
                    if (t.stack_pages != 0) {
                        frames.freeContiguous(t.stack_base, t.stack_pages) catch {};
                    }
                }
                scheduler.exit(tid) catch {};
            }
            p.thread_count = 0;
            p.space.deinit(frames);
            const revoked = registry.revokeAllOf(pid, now_ns);
            p.state = .zombie;
            p.used = false;
            return revoked;
        }

        /// Which process a thread belongs to. A capability check needs a
        /// subject, and the subject of a system call is the caller's process.
        pub fn ownerOf(self: *Self, tid: sched.Tid) ?Pid {
            for (&self.procs) |*p| {
                if (!p.used) continue;
                var i: usize = 0;
                while (i < p.thread_count) : (i += 1) {
                    if (p.threads[i] == tid) return p.pid;
                }
            }
            return null;
        }

        pub fn count(self: *const Self) usize {
            var n: usize = 0;
            for (&self.procs) |*p| {
                if (p.used) n += 1;
            }
            return n;
        }
    };
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;
const hal = @import("../hal/hal.zig");
const types = @import("../hal/types.zig");

const TestTable = Table(8);
const TestSched = sched.Scheduler(16);
const TestRegistry = cap.Registry(32, 64);

const test_regions = [_]types.MemRegion{
    .{ .base = 0x0000, .len = 0x1000, .kind = .reserved },
    .{ .base = 0x1000, .len = 0x20000, .kind = .usable },
};

test "proc: creating a process yields an isolated address space" {
    var storage: [64]u8 = undefined;
    var frames = try pmm.Pmm.init(&storage, hal.page_size, &test_regions);
    var table = TestTable.init();

    const a = try table.create(.{ .name = "shell" });
    const b = try table.create(.{ .name = "agent" });
    try testing.expectEqual(@as(usize, 2), table.count());

    const va: u64 = 0x5000_0000;
    try table.get(a).?.space.mapAnonymous(&frames, va, 1, .{ .write = true, .user = true });
    try table.get(b).?.space.mapAnonymous(&frames, va, 1, .{ .write = true, .user = true });
    try testing.expect(table.get(a).?.space.translate(va).? != table.get(b).?.space.translate(va).?);
}

test "proc: termination frees memory and revokes the process's tokens" {
    var storage: [64]u8 = undefined;
    var frames = try pmm.Pmm.init(&storage, hal.page_size, &test_regions);
    var table = TestTable.init();
    var scheduler = TestSched.init();
    var registry = TestRegistry.init();

    const pid = try table.create(.{ .name = "agent", .class = .background });
    const tid = try table.addThread(&scheduler, pid, .{ .name = "agent.main" });
    try table.get(pid).?.space.mapAnonymous(&frames, 0x6000_0000, 3, .{ .write = true, .user = true });

    const obj = cap.Object{ .kind = .directory };
    const root = try registry.issueRoot(pid, obj, .{ .read = true, .grant = true }, .{ .fs = cap.Path.from("/home/user/Documents") }, .{}, 0);
    // The agent had already delegated a token to a helper.
    const child = try registry.derive(root, pid, 99, .{ .read = true }, .{ .fs = cap.Path.from("/home/user/Documents") }, .{}, 0);

    const free_before = frames.stats().free_frames;
    const revoked = try table.terminate(&scheduler, &registry, &frames, pid, 1000);

    try testing.expect(revoked >= 2); // the token itself and the derived one
    try testing.expectEqual(free_before + 3, frames.stats().free_frames);
    try testing.expectEqual(@as(?*sched.Task, null), scheduler.task(tid));
    try testing.expectEqual(cap.State.revoked, registry.get(child).?.state);
    try testing.expectEqual(@as(usize, 0), table.count());
}

test "proc: the per-process thread limit holds" {
    var table = TestTable.init();
    var scheduler = TestSched.init();
    const pid = try table.create(.{ .name = "svc" });
    for (0..max_threads_per_process) |i| {
        _ = try table.addThread(&scheduler, pid, .{ .name = if (i == 0) "svc.main" else "svc.worker" });
    }
    try testing.expectError(Error.TooManyThreads, table.addThread(&scheduler, pid, .{ .name = "svc.extra" }));
}
