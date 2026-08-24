//! AIZigOS kernel assembly point: subsystem init and the init process.
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

pub const version = "0.1.0-stage1";

// --- static table sizes (the kernel budget) -------------------------------

const max_ram = 1 << 30; // 1 GiB of addressable physical memory
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

// --- trap handler ---------------------------------------------------------

fn onTrap(kind: hal.types.TrapKind, esr: u64, addr: u64) void {
    switch (kind) {
        .timer => {
            const now = hal.nowNs();
            scheduler.tick(now);
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
    frames = pmm.Pmm.init(&frame_bitmap, hal.page_size, map) catch |e| {
        klog.err("failed to bring up the PMM: {s}", .{@errorName(e)});
        hal.halt();
    };
    const st = frames.stats();
    klog.info("physical memory: {d} KiB free of {d} KiB", .{
        st.free_frames * st.page_size / 1024,
        st.total_frames * st.page_size / 1024,
    });
}

/// The initial handout of rights: init gets the root tokens everything
/// else is later derived from (FR-2.1).
fn initCapabilities(init_pid: proc.Pid) !void {
    const now = hal.nowNs();
    _ = try registry.issueRoot(init_pid, .{ .kind = .directory }, .{
        .read = true,
        .write = true,
        .list = true,
        .create = true,
        .delete = true,
        .grant = true,
        .revoke = true,
    }, .{ .fs = cap.Path.from("/") }, .{ .purpose = "filesystem root for init" }, now);

    _ = try registry.issueRoot(init_pid, .{ .kind = .device }, .{
        .read = true,
        .write = true,
        .grant = true,
        .revoke = true,
    }, .{ .device = .any }, .{ .purpose = "devices for init" }, now);

    klog.info("root capabilities issued: {d}", .{registry.count()});
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

export fn kmain() callconv(.c) void {
    hal.init();
    hal.setTrapHandler(onTrap);
    banner();

    initMemory();
    registry = Registry.init();
    ipc = Ipc.init();
    processes = ProcTable.init();
    initScheduling();

    const init_pid = processes.create(.{ .name = "init", .class = .interactive }) catch |e| {
        klog.err("failed to create init: {s}", .{@errorName(e)});
        hal.halt();
    };
    initCapabilities(init_pid) catch |e| {
        klog.err("capability handout failed: {s}", .{@errorName(e)});
        hal.halt();
    };
    _ = processes.addThread(&scheduler, init_pid, "init.main") catch |e| {
        klog.err("failed to create the init thread: {s}", .{@errorName(e)});
        hal.halt();
    };

    klog.info("processes: {d}, runnable tasks: {d}", .{ processes.count(), scheduler.runnableCount() });
    klog.info("kernel ready, handing control to the scheduler", .{});

    hal.armTimer(scheduler.tune.quantum_ns);
    hal.interruptsEnable();
    idleLoop();
}

/// Until the scheduler has real user threads the kernel spins an idle loop:
/// the timer tick drives the scheduler and idling sleeps according to the
/// current power profile.
fn idleLoop() noreturn {
    while (true) {
        const now = hal.nowNs();
        if (scheduler.need_resched) {
            if (scheduler.schedule(now)) |tid| {
                klog.debug("on CPU: {s}", .{scheduler.task(tid).?.nameText()});
            }
        }
        if (scheduler.shouldDeepIdle()) {
            hal.deepIdle(scheduler.tune.quantum_ns);
        } else {
            hal.idle();
        }
    }
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
