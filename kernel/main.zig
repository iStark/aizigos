//! AIZigOS kernel assembly point: subsystem init, threads and the first
//! interface.
//!
//! The kernel allocates nothing dynamically: every table is static and its
//! size is part of the FR-1.5 budget (`zig build size-audit`). Thread stacks
//! are the one exception, and they come from the physical frame allocator.

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
const syscall = @import("syscall.zig");
const user = @import("user.zig");
const gui = @import("gui.zig");
const netmod = @import("net/net.zig");
const heap = @import("mm/heap.zig");
const libc = @import("libc_port.zig");

pub const version = "0.2.0-stage2";

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

/// 64 KiB per kernel thread. It was briefly four times that, because loops
/// like `for (registry.slots)` copied whole tables onto the stack — fifty
/// kilobytes for one statement. `ps` reports the high water mark of every
/// thread now, so the next such mistake is visible instead of fatal.
const kernel_stack_pages = 16;

pub const Registry = cap.Registry(max_capabilities, audit_entries);
pub const Scheduler = sched.Scheduler(max_tasks);
pub const Ipc = ipc_mod.Ipc(max_endpoints, ipc_queue_depth, max_ipc_waiters);
pub const ProcTable = proc.Table(max_processes);

var frame_bitmap: [bitmap_bytes]u8 = undefined;

pub var frames: pmm.Pmm = undefined;
pub var kernel_heap: heap.Heap = undefined;
pub var registry: Registry = undefined;
pub var scheduler: Scheduler = undefined;
pub var ipc: Ipc = undefined;
pub var processes: ProcTable = undefined;

/// The shell owns the user's rights and hands slices of them to agents.
pub var shell_pid: proc.Pid = 0;
pub var agent_pid: proc.Pid = 0;
pub var shell_home_cap: cap.CapId = 0;

/// The network stack and the buffers it borrows for one frame at a time.
pub var net: netmod.Stack = .{};
pub var net_cap: cap.CapId = 0;
var net_rx: [netmod.max_frame]u8 = undefined;
var net_tx: [netmod.max_frame]u8 = undefined;

/// Work the background thread has completed. Visible in `ps`, and it stops
/// growing the moment the power profile forbids background tasks.
pub var indexer_rounds: u64 = 0;

// --- context switching ----------------------------------------------------

/// Where the boot thread's state lives. It is also the idle thread: when the
/// scheduler has nothing to run, control comes back here.
var boot_ctx: hal.Context = .{};
/// Scratch save area for a task that exited while it was running; nobody will
/// ever resume from it.
var dead_ctx: hal.Context = .{};

/// Whose registers are on the CPU right now. The scheduler's `current` is not
/// enough: blocking and sleeping clear it before the switch happens, and the
/// state of the thread leaving the CPU has to be saved into *its* context, not
/// into whatever the scheduler thinks is current.
var current_ctx: *hal.Context = &boot_ctx;

/// Hand the CPU to whatever the scheduler picks. Safe from thread context and
/// from inside an interrupt handler: interrupts are off across the switch, and
/// the guard is restored on the stack of whichever thread resumes here.
pub fn reschedule() void {
    const guard = hal.IrqGuard.acquire();
    defer guard.release();

    const next_tid = scheduler.schedule(hal.nowNs());
    const to: *hal.Context = if (next_tid) |t|
        (scheduler.contextOf(t) orelse &dead_ctx)
    else
        &boot_ctx;
    if (to == current_ctx) return;

    const from = current_ctx;
    current_ctx = to;
    hal.ctxSwitch(from, to);
}

/// Give up the rest of the current time slice.
pub fn yield() void {
    scheduler.yield(hal.nowNs());
    reschedule();
}

// --- trap handler ---------------------------------------------------------

fn onTrap(kind: hal.types.TrapKind, esr: u64, addr: u64, from_user: bool) void {
    switch (kind) {
        .timer => {
            scheduler.tick(hal.nowNs());
            hal.armTimer(scheduler.tune.quantum_ns);
            // Preemption proper: the interrupted task's registers are saved
            // into its context and another task continues on its own stack.
            if (scheduler.need_resched) reschedule();
        },
        .syscall => {
            // The HAL routes real system calls straight to the dispatcher; this
            // only fires for a trap that looked like one but carried no handler.
            klog.warn("stray syscall trap (esr=0x{x})", .{esr});
        },
        .page_fault, .undefined_instruction, .fault_other => {
            if (from_user) {
                killCurrentThread(kind, addr, esr);
            } else {
                klog.err("kernel fault {s} at 0x{x} (esr=0x{x})", .{ @tagName(kind), addr, esr });
                hal.halt();
            }
        },
        else => klog.warn("trap {s}: esr=0x{x} addr=0x{x}", .{ @tagName(kind), esr, addr }),
    }
}

/// A program that faults is a program that stops, not a machine that stops.
/// The thread is removed from the scheduler and the CPU goes to whatever runs
/// next; the shell is still there afterwards.
fn killCurrentThread(kind: hal.types.TrapKind, addr: u64, esr: u64) void {
    const tid = scheduler.current orelse {
        klog.err("user fault with no current thread", .{});
        hal.halt();
    };
    const name = if (scheduler.task(tid)) |t| t.nameText() else "?";
    klog.err("user thread {d} ({s}) killed: {s} at 0x{x} (esr=0x{x})", .{
        tid,
        name,
        @tagName(kind),
        addr,
        esr,
    });
    scheduler.exit(tid) catch {};
    // Nothing to return to: pick someone else and never come back here.
    current_ctx = &dead_ctx;
    reschedule();
}

// --- threads --------------------------------------------------------------

/// Sleep for a while, letting anything else that is runnable have the CPU.
pub fn sleepMs(ms: u64) void {
    const tid = scheduler.current orelse return;
    scheduler.sleep(tid, hal.nowNs() + ms * 1_000_000) catch return;
    reschedule();
}

fn shellThread(arg: usize) callconv(.c) void {
    _ = arg;
    // A machine with a screen boots into the desktop; one without keeps the
    // serial console, which is all a headless target ever had.
    if (gui.available()) {
        if (!gui.enter()) klog.warn("the framebuffer is too small for the desktop", .{});
    }
    shell.start();
    while (true) {
        // Spinning on input would starve every lower-priority task: an
        // interactive thread that never blocks is indistinguishable from a
        // busy one. Waking on the device interrupt is stage 2c.
        const traffic = netPoll();
        const busy = if (gui.active()) gui.poll() else shell.poll();
        if (busy or traffic) yield() else sleepMs(5);
    }
}

/// A stand-in for the semantic indexer of FR-3.3: it burns a slice of CPU,
/// counts a round and yields. Its real value today is that `ps` shows the
/// scheduler actually giving it time, and that `power critical` stops it dead
/// without the thread knowing anything about power management.
fn indexerThread(arg: usize) callconv(.c) void {
    _ = arg;
    while (true) {
        var spin: u32 = 0;
        var mix: u64 = 0;
        while (spin < 200_000) : (spin += 1) mix +%= spin;
        indexer_rounds +%= 1 + (mix & 0);
        yield();
    }
}

/// Runs the user program. The thread starts in the kernel, sets up the
/// mapping and then drops privilege; from that point it only comes back
/// through the system call gate.
fn userThread(arg: usize) callconv(.c) void {
    const program: user.Program = @enumFromInt(arg);
    const tid = scheduler.current orelse return;
    const t = scheduler.task(tid) orelse return;
    const kernel_stack_top = t.stack_base + t.stack_pages * hal.page_size;
    user.run(&frames, kernel_stack_top, program) catch |e| {
        klog.err("could not start the user program: {s}", .{@errorName(e)});
    };
}

/// The user thread that is running, if any.
var user_tid: ?sched.Tid = null;

pub const UserError = error{AlreadyRunning};

/// Give the agent process something to actually run.
///
/// One at a time: every user program is mapped into the same address space at
/// the same address, so starting a second one would rewrite the code the first
/// is executing. Per-process address spaces are what lifts this.
pub fn startUserProgram(program: user.Program) !sched.Tid {
    if (user_tid) |tid| {
        if (scheduler.task(tid) != null) return UserError.AlreadyRunning;
    }
    const name = switch (program) {
        .hello => "agent.user",
        .faulting => "agent.bad",
    };
    const tid = try spawnThread(agent_pid, name, userThread, @intFromEnum(program));
    user_tid = tid;
    return tid;
}

/// Stacks are filled with this before a thread runs, so how much of one has
/// ever been touched can be measured instead of guessed at.
const stack_poison: u8 = 0xA5;

/// How many bytes of a thread's stack have been used at their deepest.
pub fn stackHighWater(tid: sched.Tid) usize {
    const t = scheduler.task(tid) orelse return 0;
    if (t.stack_pages == 0) return 0;
    const size = t.stack_pages * hal.page_size;
    const bytes: [*]const u8 = @ptrFromInt(t.stack_base);
    var untouched: usize = 0;
    while (untouched < size and bytes[untouched] == stack_poison) : (untouched += 1) {}
    return size - untouched;
}

fn spawnThread(
    pid: proc.Pid,
    name: []const u8,
    entry: *const fn (usize) callconv(.c) void,
    arg: usize,
) !sched.Tid {
    const base = try frames.allocContiguous(kernel_stack_pages);
    const stack: [*]u8 = @ptrFromInt(base);
    @memset(stack[0 .. kernel_stack_pages * hal.page_size], stack_poison);
    return processes.addThread(&scheduler, pid, .{
        .name = name,
        .entry = @intFromPtr(entry),
        .arg = arg,
        .stack_base = base,
        .stack_pages = kernel_stack_pages,
        .stack_top = base + kernel_stack_pages * hal.page_size,
    });
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
    kernel_heap = heap.Heap.init(&frames);
    libc.attach(&kernel_heap);

    const st = frames.stats();
    klog.info("physical memory: {d} KiB free of {d} KiB in {d} regions", .{
        st.free_frames * st.page_size / 1024,
        st.total_frames * st.page_size / 1024,
        map.len,
    });
}

fn initNetwork() void {
    const mac = hal.netAddress() orelse {
        klog.info("network: no interface on this machine", .{});
        return;
    };
    net = .{ .config = .{ .mac = mac } };
    klog.info("network: {x}:{x}:{x}:{x}:{x}:{x} as 10.0.2.15, gateway 10.0.2.2", .{
        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
    });
}

/// Move whatever the card has received through the stack, and send whatever
/// the stack answers with. Returns true when there was traffic.
pub fn netPoll() bool {
    if (hal.netAddress() == null) return false;
    var busy = false;
    while (hal.netReceive(&net_rx)) |len| {
        busy = true;
        const reply = net.receive(net_rx[0..len], hal.nowNs(), &net_tx);
        if (reply > 0) _ = hal.netSend(net_tx[0..reply]);
    }
    return busy;
}

/// Ask the network who owns an address, then wait a little for the answer.
fn resolve(target: netmod.Ip4) ?netmod.Mac {
    if (net.lookup(target)) |mac| return mac;
    var attempt: usize = 0;
    while (attempt < 10) : (attempt += 1) {
        const len = net.buildArpRequest(target, &net_tx);
        _ = hal.netSend(net_tx[0..len]);
        var waited: usize = 0;
        while (waited < 10) : (waited += 1) {
            sleepMs(10);
            _ = netPoll();
            if (net.lookup(target)) |mac| return mac;
        }
    }
    return null;
}

/// One echo request and the wait for its answer, in nanoseconds.
pub fn ping(target: netmod.Ip4) ?u64 {
    const hop = net.nextHop(target);
    _ = resolve(hop) orelse return null;

    const len = net.buildPing(target, hal.nowNs(), &net_tx);
    if (len == 0) return null;
    if (!hal.netSend(net_tx[0..len])) return null;

    var waited: usize = 0;
    while (waited < 100) : (waited += 1) {
        sleepMs(10);
        _ = netPoll();
        if (net.ping_rtt_ns) |rtt| return rtt;
    }
    return null;
}

fn initScheduling() void {
    scheduler = Scheduler.init();
    // Assume AC power at boot; the profile will follow the sensors once the
    // battery driver exists.
    _ = scheduler.updatePower(.{ .on_ac = true, .battery_present = false });
    klog.info("power profile: {s}, quantum {d} us", .{
        scheduler.governor.current.label(),
        scheduler.tune.quantum_ns / 1000,
    });
}

/// The first processes, their threads and the initial handout of rights.
fn initUserland() !void {
    const now = hal.nowNs();

    shell_pid = try processes.create(.{ .name = "ai-shell", .class = .interactive });
    _ = try spawnThread(shell_pid, "shell.main", shellThread, 0);

    // The agent exists as a rights holder before it has any code to run: the
    // shell can already grant it access, and the audit log records it.
    agent_pid = try processes.create(.{ .name = "agent", .class = .background });

    const indexer_pid = try processes.create(.{ .name = "semantic-index", .class = .background });
    _ = try spawnThread(indexer_pid, "index.worker", indexerThread, 0);

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

    // FR-2.1 covers sockets as well as files: nothing reaches the network
    // without a token, and the token carries the hosts and ports it allows.
    net_cap = try registry.issueRoot(shell_pid, .{ .kind = .socket }, .{
        .send = true,
        .recv = true,
        .grant = true,
        .revoke = true,
    }, .{ .net = .{ .host = cap.Path.from(""), .port_lo = 0, .port_hi = 65535 } }, .{
        .purpose = "network access",
    }, now);

    klog.info("processes: {d}, threads: {d}, capabilities: {d}", .{
        processes.count(),
        scheduler.runnableCount(),
        registry.count(),
    });
}

export fn kmain() callconv(.c) void {
    hal.init();
    hal.setTrapHandler(onTrap);
    hal.setSyscallHandler(syscall.dispatch);
    banner();

    initMemory();
    registry = Registry.init();
    ipc = Ipc.init();
    processes = ProcTable.init();
    initScheduling();

    initNetwork();

    initUserland() catch |e| {
        klog.err("userland init failed: {s}", .{@errorName(e)});
        hal.halt();
    };

    klog.info("kernel ready, starting threads", .{});
    hal.armTimer(scheduler.tune.quantum_ns);
    hal.interruptsEnable();

    idleLoop();
}

/// The boot thread becomes the idle thread. It is not in the scheduler's
/// tables: it runs exactly when nothing else can, which is also what keeps the
/// `critical` power profile honest — with every class forbidden, the machine
/// idles here instead of pretending there is work.
fn idleLoop() noreturn {
    while (true) {
        if (scheduler.peek() != null) reschedule();
        if (scheduler.shouldDeepIdle()) {
            hal.deepIdle(scheduler.tune.quantum_ns);
        } else {
            hal.idle();
        }
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
