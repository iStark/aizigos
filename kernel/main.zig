//! AIZigOS kernel assembly point: subsystem init and the first interface.
//!
//! The kernel allocates nothing dynamically: every table is static and its
//! size is part of the FR-1.5 budget (`zig build size-audit`).

const std = @import("std");
const builtin = @import("builtin");

const hal = @import("hal/hal.zig");
const klog = @import("klog.zig");
const pmm = @import("mm/pmm.zig");
const vmm = @import("mm/vmm.zig");
const cap = @import("cap/cap.zig");
const sched = @import("sched/sched.zig");
const power = @import("sched/power.zig");
const ipc_mod = @import("ipc/ipc.zig");
const proc = @import("proc/process.zig");
const shell = @import("shell.zig");

pub const version = "0.1.0-stage1";

// --- static table sizes (the kernel budget) -------------------------------

const max_ram = 2 << 30; // 2 GiB of addressable physical memory
const bitmap_bytes = max_ram / hal.page_size / 8;

const max_processes = 32;
const max_tasks = 64;
const max_capabilities = 256;
const audit_entries = 256;
const max_endpoints = 32;
const ipc_queue_depth = 8;
const max_ipc_waiters = 32;

pub const Registry = cap.Registry(max_capabilities, audit_entries);
pub const Scheduler = sched.Scheduler(max_tasks);
pub const Ipc = ipc_mod.Ipc(max_endpoints, ipc_queue_depth, max_ipc_waiters);
pub const ProcTable = proc.Table(max_processes);

var frame_bitmap: [bitmap_bytes]u8 = undefined;

pub var frames: pmm.Pmm = undefined;
pub var registry: Registry = undefined;
pub var scheduler: Scheduler = undefined;
pub var ipc: Ipc = undefined;
pub var processes: ProcTable = undefined;

/// The shell owns the user's rights and hands slices of them to agents.
pub var shell_pid: proc.Pid = 0;
pub var agent_pid: proc.Pid = 0;
pub var shell_home_cap: cap.CapId = 0;

// --- trap handler ---------------------------------------------------------

fn onTrap(kind: hal.types.TrapKind, esr: u64, addr: u64) void {
    switch (kind) {
        .timer => {
            scheduler.tick(hal.nowNs());
            hal.armTimer(scheduler.tune.quantum_ns);
        },
        .syscall => {
            // Stage 2: decode the call number and check the caller's capability.
            klog.debug("syscall (esr=0x{x})", .{esr});
        },
        .page_fault => {
            klog.err("page fault at 0x{x} (esr=0x{x})", .{ addr, esr });
            hal.halt();
        },
        else => klog.warn("trap {s}: esr=0x{x} addr=0x{x}", .{ @tagName(kind), esr, addr }),
    }
}

// --- initialisation -------------------------------------------------------

fn banner() void {
    klog.raw("\n");
    klog.info("AIZigOS {s} - microkernel in Zig {s}", .{ version, builtin.zig_version_string });
    klog.info("HAL target: {s}, page {d} bytes", .{ hal.target_name, hal.page_size });
}

fn initMemory() void {
    const map = hal.memoryMap();
    // A machine with more RAM than the static bitmap covers boots with less of
    // it rather than not at all.
    frames = pmm.Pmm.initCapped(&frame_bitmap, hal.page_size, map) catch |e| {
        klog.err("failed to bring up the PMM: {s}", .{@errorName(e)});
        hal.halt();
    };
    const st = frames.stats();
    klog.info("physical memory: {d} KiB free of {d} KiB in {d} regions", .{
        st.free_frames * st.page_size / 1024,
        st.total_frames * st.page_size / 1024,
        map.len,
    });
}

fn initScheduling() void {
    scheduler = Scheduler.init();
    // Assume AC power at boot; the profile will follow the sensors once the
    // battery driver exists (stage 2).
    _ = scheduler.updatePower(.{ .on_ac = true, .battery_present = false });
    klog.info("power profile: {s}, quantum {d} us", .{
        scheduler.governor.current.label(),
        scheduler.tune.quantum_ns / 1000,
    });
}

/// The first processes and the initial handout of rights (FR-2.1).
fn initUserland() !void {
    const now = hal.nowNs();

    shell_pid = try processes.create(.{ .name = "ai-shell", .class = .interactive });
    _ = try processes.addThread(&scheduler, shell_pid, "shell.main");

    agent_pid = try processes.create(.{ .name = "agent", .class = .background });
    _ = try processes.addThread(&scheduler, agent_pid, "agent.main");

    const indexer = try processes.create(.{ .name = "semantic-index", .class = .background });
    _ = try processes.addThread(&scheduler, indexer, "index.worker");

    _ = try registry.issueRoot(shell_pid, .{ .kind = .directory }, .{
        .read = true,
        .write = true,
        .list = true,
        .create = true,
        .delete = true,
        .grant = true,
        .revoke = true,
    }, .{ .fs = cap.Path.from("/") }, .{ .purpose = "filesystem root" }, now);

    shell_home_cap = try registry.issueRoot(shell_pid, .{ .kind = .directory }, .{
        .read = true,
        .write = true,
        .list = true,
        .create = true,
        .grant = true,
        .revoke = true,
    }, .{ .fs = cap.Path.from("/home/user") }, .{ .purpose = "user home directory" }, now);

    _ = try registry.issueRoot(shell_pid, .{ .kind = .device }, .{
        .read = true,
        .write = true,
        .grant = true,
        .revoke = true,
    }, .{ .device = .any }, .{ .purpose = "devices" }, now);

    klog.info("processes: {d}, runnable tasks: {d}, capabilities: {d}", .{
        processes.count(),
        scheduler.runnableCount(),
        registry.count(),
    });
}

export fn kmain() callconv(.c) void {
    hal.init();
    hal.setTrapHandler(onTrap);
    banner();

    initMemory();
    registry = Registry.init();
    ipc = Ipc.init();
    processes = ProcTable.init();
    initScheduling();

    initUserland() catch |e| {
        klog.err("userland init failed: {s}", .{@errorName(e)});
        hal.halt();
    };

    klog.info("kernel ready", .{});
    hal.armTimer(scheduler.tune.quantum_ns);
    hal.interruptsEnable();

    shell.start();
    idleLoop();
}

/// Until user threads are switched for real (stage 2), the kernel's own loop
/// drives the shell: the timer tick advances the scheduler, and between ticks
/// the CPU sleeps the way the current power profile asks it to.
fn idleLoop() noreturn {
    while (true) {
        shell.poll();
        if (scheduler.need_resched) {
            _ = scheduler.schedule(hal.nowNs());
        }
        hal.idle();
    }
}

// --- entry points ---------------------------------------------------------

/// UEFI hands control to `main`; ELF targets enter through `_start` in the HAL.
pub const main = if (builtin.os.tag == .uefi) uefiMain else {};

fn uefiMain() noreturn {
    kmain();
    hal.halt();
}

// --- panic ----------------------------------------------------------------

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    klog.raw("\n[panic] ");
    klog.raw(msg);
    klog.raw("\n");
    if (first_trace_addr) |addr| klog.err("address: 0x{x}", .{addr});
    hal.halt();
}

pub const panic = std.debug.FullPanic(panicHandler);
