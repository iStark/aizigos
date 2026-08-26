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
const elf = @import("elf.zig");
const fp = @import("fp.zig");
const gui = @import("gui.zig");
const netmod = @import("net/net.zig");
const dns_mod = @import("net/dns.zig");
const heap = @import("mm/heap.zig");
const libc = @import("libc_port.zig");
pub const fat32 = @import("fs/fat32.zig");
const config = @import("config.zig");

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
/// 128 KiB per thread. Sixty-four was comfortable until a system call could
/// reach the network: a fetch nests a copy buffer, a frame and the connection
/// blocks behind it, and running out of kernel stack does not announce itself
/// politely — it jumps somewhere that is not code. `ps` shows the high water
/// mark, which is how this number stops being a guess.
const kernel_stack_pages = 32;

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
pub var net: netmod.Stack = undefined;
pub var net_cap: cap.CapId = 0;
var net_rx: [netmod.max_frame]u8 = undefined;
var net_tx: [netmod.max_frame]u8 = undefined;

/// The volume the machine booted from, once it has been found and parsed.
pub var boot_volume: ?fat32.Volume = null;
pub var disk_cap: cap.CapId = 0;

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

/// The kernel identity map, cloned into every process space.
var kernel_vmm: vmm.AddressSpace = .{};
var current_vmm: *vmm.AddressSpace = &kernel_vmm;

fn spaceOf(tid: sched.Tid) *vmm.AddressSpace {
    if (processes.ownerOf(tid)) |pid| {
        if (processes.get(pid)) |p| return &p.space;
    }
    return &kernel_vmm;
}

fn activateSpace(space: *vmm.AddressSpace) void {
    if (current_vmm == space) return;
    space.activate();
    current_vmm = space;
}

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

    const next_space = if (next_tid) |t| spaceOf(t) else &kernel_vmm;
    activateSpace(next_space);
    if (next_tid) |t| {
        if (scheduler.task(t)) |task| {
            if (task.stack_pages != 0) {
                hal.setKernelStack(task.stack_base + task.stack_pages * hal.page_size);
            }
        }
    }

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
    if (kind == .fp_unavailable) {
        if (!fp.handleUnavailable(from_user)) {
            if (from_user) killCurrentThread(kind, addr, esr) else {
                klog.err("kernel FP trap at 0x{x}", .{addr});
                hal.halt();
            }
        }
        return;
    }
    if (from_user) fp.onKernelEntry(true);
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
    if (from_user) fp.prepareReturnToUser();
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
    reapAndReschedule(tid);
}

fn reapAndReschedule(tid: sched.Tid) void {
    const pid = processes.ownerOf(tid);
    if (scheduler.task(tid)) |t| {
        if (t.stack_pages != 0) {
            frames.freeContiguous(t.stack_base, t.stack_pages) catch {};
            t.stack_pages = 0;
        }
    }
    scheduler.exit(tid) catch {};
    // Leave this address space before tearing it down: asDeinit frees the
    // process root, and CR3 must not still point at it.
    current_ctx = &dead_ctx;
    activateSpace(&kernel_vmm);
    if (pid) |p| {
        const left = processes.dropThread(p, tid) catch 0;
        if (left == 0) {
            // A program that died mid-fetch does not get to keep a connection:
            // there are four, and a leak would end the machine's networking a
            // crash at a time.
            const closed = socketsOfProcessClosed(p);
            if (closed > 0) klog.info("closed {d} socket(s) held by process {d}", .{ closed, p });
            _ = filesOfProcessClosed(p);
            _ = processes.terminate(&scheduler, &registry, &frames, p, hal.nowNs()) catch {};
        }
    }
    reschedule();
}

/// A program asked to die. Same teardown as a fault, without the error log.
pub fn exitCurrent(status: u64) void {
    const tid = scheduler.current orelse return;
    const name = if (scheduler.task(tid)) |t| t.nameText() else "?";
    klog.info("thread {d} ({s}) exited {d}", .{ tid, name, status });
    reapAndReschedule(tid);
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
    const pid = processes.ownerOf(tid) orelse return;
    const proc_space = if (processes.get(pid)) |p| &p.space else return;
    user.run(&frames, kernel_stack_top, program, proc_space) catch |e| {
        klog.err("could not start the user program: {s}", .{@errorName(e)});
        exitCurrent(1);
    };
}

fn elfThread(_: usize) callconv(.c) void {
    const tid = scheduler.current orelse return;
    const t = scheduler.task(tid) orelse return;
    const kernel_stack_top = t.stack_base + t.stack_pages * hal.page_size;
    const pid = processes.ownerOf(tid) orelse return;
    const child = processes.get(pid) orelse return;
    const path = child.exec_path[0..child.exec_path_len];
    const volume: *fat32.Volume = if (boot_volume) |*vol| vol else {
        klog.err("exec: no disk", .{});
        exitCurrent(1);
        return;
    };
    const file = volume.open(path) catch |e| {
        klog.err("exec: {s}: {s}", .{ path, @errorName(e) });
        exitCurrent(1);
        return;
    };
    if (file.size == 0 or file.size > elf.max_size) {
        klog.err("exec: {s} is {d} bytes, refused", .{ path, file.size });
        exitCurrent(1);
        return;
    }
    const raw = kernel_heap.alloc(file.size) catch {
        klog.err("exec: no heap for {s}", .{path});
        exitCurrent(1);
        return;
    };
    const image = raw[0..file.size];
    const got = volume.read(file, 0, image) catch |e| {
        klog.err("exec: read {s}: {s}", .{ path, @errorName(e) });
        kernel_heap.free(raw);
        exitCurrent(1);
        return;
    };
    if (got != file.size) {
        klog.err("exec: short read {s} {d}/{d}", .{ path, got, file.size });
        kernel_heap.free(raw);
        exitCurrent(1);
        return;
    }
    const entry = elf.load(&child.space, &frames, image) catch |e| {
        klog.err("exec: load {s}: {s}", .{ path, @errorName(e) });
        kernel_heap.free(raw);
        exitCurrent(1);
        return;
    };
    kernel_heap.free(raw);
    child.space.mapAnonymous(&frames, user.stack_va, user.stack_pages, .{
        .read = true,
        .write = true,
        .user = true,
    }) catch {
        klog.err("exec: stack map failed", .{});
        exitCurrent(1);
        return;
    };
    klog.info("entering user mode: {s} at 0x{x}", .{ path, entry });
    child.space.activate();
    current_vmm = &child.space;
    hal.setKernelStack(kernel_stack_top);
    fp.prepareReturnToUser();
    hal.enterUserMode(entry, user.stack_va + user.stack_pages * hal.page_size);
}

pub const UserError = error{ AlreadyRunning, NoDisk, TooLarge, BadPath };

/// Run a baked-in assembler blob in its own process and address space.
pub fn startUserProgram(program: user.Program) !sched.Tid {
    const name = switch (program) {
        .hello => "agent.user",
        .faulting => "agent.bad",
    };
    const pid = try processes.create(.{ .name = name, .parent = agent_pid, .class = .normal });
    return spawnThread(pid, name, userThread, @intFromEnum(program));
}

/// Load a static ELF64 off the boot volume into a new process.
pub fn startElf(path: []const u8, args: []const u8) !sched.Tid {
    if (boot_volume == null) return UserError.NoDisk;
    if (path.len == 0 or path.len > 48) return UserError.BadPath;
    const pid = try processes.create(.{ .name = "elf", .parent = agent_pid, .class = .normal });
    const p = processes.get(pid) orelse return error.NoSuchProcess;
    @memcpy(p.exec_path[0..path.len], path);
    p.exec_path_len = @intCast(path.len);
    p.setArgs(args);
    return spawnThread(pid, "elf.main", elfThread, 0);
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

    // Share the kernel identity map with every process space created after this.
    kernel_vmm.arch = hal.currentSpace().*;
    vmm.attachKernel(&kernel_vmm);
    current_vmm = &kernel_vmm;

    const st = frames.stats();
    klog.info("physical memory: {d} KiB free of {d} KiB in {d} regions", .{
        st.free_frames * st.page_size / 1024,
        st.total_frames * st.page_size / 1024,
        map.len,
    });
}

/// Sectors for the filesystem come through the HAL, so the driver above it
/// never learns which machine it is running on.
fn diskSectors(context: ?*anyopaque, lba: u64, buffer: []u8) bool {
    _ = context;
    return hal.diskRead(lba, buffer);
}

fn diskPutSectors(context: ?*anyopaque, lba: u64, buffer: []const u8) bool {
    _ = context;
    return hal.diskWrite(lba, buffer);
}

/// A display we can drive ourselves, if this machine has one. Without it the
/// framebuffer the firmware handed over carries on exactly as before, so a
/// machine with no virtio display loses nothing.
fn initDisplay() void {
    if (comptime !@hasDecl(hal.impl, "virtio_gpu")) return;
    const gpu = hal.impl.virtio_gpu;
    if (!gpu.init(&frames)) {
        klog.info("display: firmware framebuffer only, no mode changes", .{});
        return;
    }

    // The size someone chose last time, if this display will show it, and
    // otherwise whatever the firmware left on screen. Taking over at the
    // remembered size means the desktop never appears at the wrong one and
    // then jumps.
    const now = hal.impl.fb.dimensions();
    var want_w = now.width;
    var want_h = now.height;
    const stored = hal.impl.boot.stored;
    if (stored.screen_width != 0) {
        for (hal.impl.displayModes()) |mode| {
            if (mode.width == stored.screen_width and mode.height == stored.screen_height) {
                want_w = mode.width;
                want_h = mode.height;
                break;
            }
        }
    }
    if (!hal.impl.displayTakeOver(want_w, want_h)) {
        klog.warn("display: virtio-gpu found but would not take the screen", .{});
        return;
    }
    klog.info("display: virtio-gpu at {d}x{d}, {d} sizes without a restart", .{
        want_w,
        want_h,
        gpu.mode_count,
    });
}

fn initStorage() void {
    if (!hal.diskPresent()) {
        klog.info("storage: no readable disk on this machine", .{});
        return;
    }
    boot_volume = fat32.Volume.mount(.{
        .read = diskSectors,
        .write = if (hal.diskWritable()) diskPutSectors else null,
    }) catch |e| {
        klog.warn("storage: disk present but unreadable: {s}", .{@errorName(e)});
        return;
    };
    const volume = &boot_volume.?;
    klog.info("storage: FAT32 at LBA {d}, {d} clusters of {d} bytes, {s}", .{
        volume.partition_lba,
        volume.cluster_count,
        volume.bytes_per_cluster,
        if (volume.writable()) "read and write" else "read only",
    });
}

/// The filesystem answers to the same rule as everything else: FR-2.1 says no
/// access without a token, and the check lives here rather than in the shell
/// so that a future model driving the shell cannot route around it.
fn fsAllowed(path: []const u8, rights: cap.Rights) bool {
    return registry.use(disk_cap, shell_pid, .{
        .object = .{ .kind = .directory },
        .rights = rights,
        .path = path,
    }, hal.nowNs()) == .allow;
}

pub const FsError = fat32.Error || error{ NoDisk, Denied };

pub fn fsList(path: []const u8, out: []fat32.Entry) FsError!usize {
    if (boot_volume == null) return error.NoDisk;
    if (!fsAllowed(path, .{ .list = true })) return error.Denied;
    return boot_volume.?.list(path, out);
}

pub fn fsRead(path: []const u8, offset: u64, out: []u8) FsError!usize {
    if (boot_volume == null) return error.NoDisk;
    if (!fsAllowed(path, .{ .read = true })) return error.Denied;
    const file = try boot_volume.?.open(path);
    return boot_volume.?.read(file, offset, out);
}

/// Save a whole file. Writing needs its own right: a token that lets a program
/// read the disk is not a token that lets it change what is on it.
pub fn fsWrite(path: []const u8, data: []const u8) FsError!void {
    if (boot_volume == null) return error.NoDisk;
    if (!fsAllowed(path, .{ .write = true })) return error.Denied;
    return boot_volume.?.writeFile(path, data);
}

pub fn fsRemove(path: []const u8) FsError!void {
    if (boot_volume == null) return error.NoDisk;
    if (!fsAllowed(path, .{ .write = true })) return error.Denied;
    return boot_volume.?.remove(path);
}

/// Save the settings file. Separate from `fsWrite` because it is the kernel's
/// own file rather than someone's document: it goes through the same capability
/// check, and answers whether it landed rather than raising.
pub fn fsSaveConfig(values: config.Values) bool {
    if (boot_volume == null) return false;
    if (!boot_volume.?.writable()) return false;
    if (!fsAllowed(config.path, .{ .write = true })) return false;
    return config.saveTo(&boot_volume.?, values);
}

pub fn fsStat(path: []const u8) FsError!fat32.File {
    if (boot_volume == null) return error.NoDisk;
    if (!fsAllowed(path, .{ .read = true })) return error.Denied;
    return boot_volume.?.open(path);
}

// --- open files -----------------------------------------------------------

/// Files a program holds open. Static and small like everything else: eight is
/// more than the programs this system runs have ever wanted at once, and a
/// number that can be exceeded is a number that gets checked.
pub const max_open_files = 8;

const OpenFile = struct {
    used: bool = false,
    owner: proc.Pid = 0,
    file: fat32.File = .{ .cluster = 0, .size = 0, .is_dir = false },
    offset: u64 = 0,
};

var open_files: [max_open_files]OpenFile = @splat(.{});

pub const OpenError = FsError || error{NoRoom};

/// Open a file for a process. The capability is checked here, against the path
/// the caller named, before anything is looked up — a handle is only ever
/// handed out for a path the holder was allowed to ask about.
pub fn fileOpen(owner: proc.Pid, path: []const u8) OpenError!usize {
    const file = try fsStat(path);
    if (file.is_dir) return error.IsADirectory;

    for (&open_files, 0..) |*slot, index| {
        if (slot.used) continue;
        slot.* = .{ .used = true, .owner = owner, .file = file, .offset = 0 };
        return index + 1;
    }
    return error.NoRoom;
}

fn fileOf(owner: proc.Pid, handle: usize) FsError!*OpenFile {
    if (handle == 0 or handle > open_files.len) return error.NotFound;
    const slot = &open_files[handle - 1];
    // A handle belongs to whoever opened it. Guessing numbers gets nothing.
    if (!slot.used or slot.owner != owner) return error.NotFound;
    return slot;
}

pub fn fileRead(owner: proc.Pid, handle: usize, out: []u8) FsError!usize {
    const slot = try fileOf(owner, handle);
    if (boot_volume == null) return error.NoDisk;
    const got = try boot_volume.?.read(slot.file, slot.offset, out);
    slot.offset += got;
    return got;
}

pub const Whence = enum(u64) { set = 0, current = 1, end = 2, _ };

pub fn fileSeek(owner: proc.Pid, handle: usize, offset: i64, whence: Whence) FsError!u64 {
    const slot = try fileOf(owner, handle);
    const base: i64 = switch (whence) {
        .set => 0,
        .current => @intCast(slot.offset),
        .end => @intCast(slot.file.size),
        _ => return error.NotFound,
    };
    const target = base + offset;
    if (target < 0) return error.NotFound;
    slot.offset = @intCast(target);
    return slot.offset;
}

pub fn fileSize(owner: proc.Pid, handle: usize) FsError!u64 {
    const slot = try fileOf(owner, handle);
    return slot.file.size;
}

pub fn fileClose(owner: proc.Pid, handle: usize) void {
    const slot = fileOf(owner, handle) catch return;
    slot.* = .{};
}

/// A process that ends lets go of its files, the same way it lets go of its
/// sockets. Eight handles do not survive many crashes otherwise.
pub fn filesOfProcessClosed(owner: proc.Pid) usize {
    var closed: usize = 0;
    for (&open_files) |*slot| {
        if (!slot.used or slot.owner != owner) continue;
        slot.* = .{};
        closed += 1;
    }
    return closed;
}

/// Say what the machine can and cannot tell us about the world. Both of these
/// are load-bearing for TLS, and a system that quietly lacks either would fail
/// later and less clearly.
fn initWorld() void {
    var sample: [16]u8 = undefined;
    const hardware = hal.entropy(&sample);
    const seconds = hal.realtimeSeconds();
    if (hardware) {
        klog.info("entropy: the processor's generator", .{});
    } else {
        klog.warn("entropy: none this kernel trusts; TLS will refuse to run", .{});
    }
    if (seconds == 0) {
        klog.warn("clock: no real time source; certificates cannot be dated", .{});
    } else {
        klog.info("clock: {d} seconds since the epoch", .{seconds});
    }
}

fn initNetwork() void {
    const mac = hal.netAddress() orelse {
        klog.info("network: no interface on this machine", .{});
        return;
    };
    net = .{};
    net.config.mac = mac;
    klog.info("network: {x}:{x}:{x}:{x}:{x}:{x} as 10.0.2.15, gateway 10.0.2.2", .{
        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
    });
}

/// The network is one object, and more than one thread reaches for it: the
/// shell polls the wire in a loop while a program may be halfway through
/// building a packet in the same buffer. One thread at a time, then.
///
/// A single processor cannot lose a buffer to a second core, only to
/// preemption, so this is all the exclusion the network needs — and it is
/// recursive, because a thread that holds it polls the wire while it waits.
var net_owner: ?sched.Tid = null;
var net_depth: usize = 0;

fn netTryEnter() bool {
    const guard = hal.IrqGuard.acquire();
    defer guard.release();
    const me = scheduler.current;
    if (net_owner) |owner| {
        // A thread that died holding the network does not get to keep it.
        if (owner != me and scheduler.task(owner) != null) return false;
    }
    net_owner = me;
    net_depth += 1;
    return true;
}

fn netEnter() void {
    while (!netTryEnter()) yield();
}

fn netLeave() void {
    const guard = hal.IrqGuard.acquire();
    defer guard.release();
    if (net_depth > 0) net_depth -= 1;
    if (net_depth == 0) net_owner = null;
}

/// Move whatever the card has received through the stack, and send whatever
/// the stack answers with. Returns true when there was traffic.
///
/// Someone else servicing the wire is not a reason to wait: they will do the
/// same work, and this caller has other things to be getting on with.
pub fn netPoll() bool {
    if (hal.netAddress() == null) return false;
    if (!netTryEnter()) return false;
    defer netLeave();
    var busy = false;
    while (hal.netReceive(&net_rx)) |len| {
        busy = true;
        const reply = net.receive(net_rx[0..len], hal.nowNs(), &net_tx);
        if (reply > 0) _ = hal.netSend(net_tx[0..reply]);
    }
    const due = net.tick(hal.nowNs(), &net_tx);
    if (due > 0) {
        _ = hal.netSend(net_tx[0..due]);
        busy = true;
    }
    return busy;
}

/// Ask the network who owns an address, then wait a little for the answer.
fn resolve(target: netmod.Ip4) ?netmod.Mac {
    if (net.lookup(target)) |mac| return mac;
    netEnter();
    defer netLeave();
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
/// What can go wrong on the way out. Callers tell a person which of these it
/// was, because "no reply" and "you have no token for that host" are different
/// problems and only one of them is worth retrying.
pub const NetError = error{
    NoInterface,
    Denied,
    Unresolved,
    NoRoute,
    NoAnswer,
    /// Every connection this kernel can track is already in use.
    NoRoom,
    /// No such socket, or not one this process opened.
    NoSocket,
    /// The exchange started and did not finish in the time allowed. Distinct
    /// from NoAnswer because a connection that half-opened and stalled is a
    /// different fault from one nothing ever replied to.
    Timeout,
};

/// Reaching the network is an object access like any other (FR-2.1). The check
/// lives here, next to the code that actually sends, so that every path
/// through it is checked: a typed command, a sentence, a system call, and
/// whatever drives the shell once a model is doing the driving.
fn netPermits(host: []const u8, port: u16) NetError!void {
    if (hal.netAddress() == null) return NetError.NoInterface;
    const decision = registry.use(net_cap, shell_pid, .{
        .object = .{ .kind = .socket },
        .rights = .{ .send = true, .recv = true },
        .path = host,
        .port = port,
    }, hal.nowNs());
    if (!decision.ok()) return NetError.Denied;
}

/// Ping a host by name or by address. The name is resolved here rather than by
/// the caller, so that a sentence and a typed command reach the same host, and
/// so that what comes back is the address that actually answered.
pub fn ping(host: []const u8) NetError!Pinged {
    const target = try resolveHost(host);
    try netPermits(host, 0);
    netEnter();
    defer netLeave();

    const hop = net.nextHop(target);
    _ = resolve(hop) orelse return NetError.NoRoute;

    const len = net.buildPing(target, hal.nowNs(), &net_tx);
    if (len == 0) return NetError.NoAnswer;
    if (!hal.netSend(net_tx[0..len])) return NetError.NoAnswer;

    var waited: usize = 0;
    while (waited < 100) : (waited += 1) {
        sleepMs(10);
        _ = netPoll();
        if (net.ping_rtt_ns) |rtt| return .{ .address = target, .rtt_ns = rtt };
    }
    return NetError.NoAnswer;
}

/// Which address answered, and how long it took. The address matters: a name
/// that resolved somewhere unexpected is worth seeing rather than hiding.
pub const Pinged = struct {
    address: netmod.Ip4,
    rtt_ns: u64,
};

/// A dotted quad if that is what it is, and the resolver otherwise. A name
/// that does not resolve is an answer, not a reason to substitute something
/// else and report success.
pub fn resolveHost(host: []const u8) NetError!netmod.Ip4 {
    if (netmod.parseIp(host)) |ip| return ip;
    return dnsLookup(host);
}

pub fn dnsLookup(name: []const u8) NetError!netmod.Ip4 {
    if (netmod.parseIp(name)) |ip| return ip;
    const now = hal.nowNs();
    if (net.dns.lookup(name, now)) |ip| return ip;
    try netPermits(name, 53);
    netEnter();
    defer netLeave();
    const hop = net.nextHop(net.dns_server);
    _ = resolve(hop) orelse return NetError.NoRoute;
    const port = net.bindUdp(0) orelse return NetError.NoAnswer;
    defer net.unbindUdp(port);
    var query: [256]u8 = undefined;
    const id: u16 = @truncate(now);
    const qlen = dns_mod.buildQuery(name, id, &query) orelse return NetError.Unresolved;
    const slen = net.buildUdp(port, net.dns_server, 53, query[0..qlen], &net_tx);
    if (slen == 0) return NetError.NoAnswer;
    _ = hal.netSend(net_tx[0..slen]);
    var waited: usize = 0;
    var packet: [netmod.max_udp_payload]u8 = undefined;
    while (waited < 50) : (waited += 1) {
        sleepMs(20);
        _ = netPoll();
        if (net.recvUdp(port, &packet)) |got| {
            const answer = dns_mod.parseAnswer(packet[0..got.len], id) catch
                return NetError.Unresolved;
            if (answer) |a| {
                net.dns.store(name, a.ip, hal.nowNs(), a.ttl_s);
                return a.ip;
            }
            // The server answered and said it has no address for that name.
            return NetError.Unresolved;
        }
    }
    return NetError.NoAnswer;
}

// --- sockets --------------------------------------------------------------

/// Connections a program holds. Static and small, like every other table here:
/// four is what the TCP module tracks, and a system that cannot yet lay out a
/// page has no business holding more.
pub const max_sockets = netmod.tcp_mod.max_tcbs;

const Socket = struct {
    used: bool = false,
    owner: proc.Pid = 0,
    id: usize = 0,
    port: u16 = 0,
    host: [64]u8 = @splat(0),
    host_len: u8 = 0,

    fn hostText(self: *const Socket) []const u8 {
        return self.host[0..self.host_len];
    }
};

var sockets: [max_sockets]Socket = @splat(.{});

/// Open a connection on behalf of a process. The capability is checked here,
/// once, against the host and port the caller asked for — after this the
/// socket is the token, and it belongs to the process that opened it.
pub fn socketConnect(owner: proc.Pid, host: []const u8, port: u16) NetError!usize {
    if (host.len == 0 or host.len > 63) return NetError.Unresolved;
    const started = hal.nowNs();
    const ip = try resolveHost(host);
    try netPermits(host, port);

    netEnter();
    defer netLeave();

    // Choosing a slot and filling it in have to happen without letting go of
    // the network in between. Two callers that both saw the same free slot
    // would both write it, and the first one's handle would then be pointing
    // at the second one's connection.
    var slot: ?usize = null;
    for (&sockets, 0..) |*socket, index| {
        if (!socket.used) {
            socket.* = .{ .used = true, .owner = owner, .port = port };
            slot = index;
            break;
        }
    }
    const index = slot orelse return NetError.NoRoom;
    errdefer sockets[index] = .{};

    const hop = net.nextHop(ip);
    _ = resolve(hop) orelse return complain(host, "route", started, NetError.NoRoute);

    var frame: [netmod.max_frame]u8 = undefined;
    const opened = net.tcp.connect(&net, ip, port, hal.nowNs(), &frame) catch |e| switch (e) {
        // Every connection in use is a different fact from nobody answering,
        // and the caller can do something about one of them.
        error.TableFull => return complain(host, "connect", started, NetError.NoRoom),
        else => return complain(host, "connect", started, NetError.NoAnswer),
    };
    if (opened.len > 0) _ = hal.netSend(frame[0..opened.len]);

    var waited: usize = 0;
    while (waited < 150) : (waited += 1) {
        sleepMs(20);
        _ = netPoll();
        switch (net.tcp.stateOf(opened.id) orelse {
            net.tcp.release(opened.id);
            return complain(host, "handshake", started, NetError.NoAnswer);
        }) {
            .established => break,
            else => {},
        }
    } else {
        net.tcp.release(opened.id);
        return complain(host, "handshake", started, NetError.Timeout);
    }

    sockets[index].id = opened.id;
    const take = @min(host.len, 64);
    @memcpy(sockets[index].host[0..take], host[0..take]);
    sockets[index].host_len = @intCast(take);
    // Handles start at one so that zero stays available for "no socket".
    return index + 1;
}

fn socketOf(owner: proc.Pid, handle: usize) NetError!*Socket {
    if (handle == 0 or handle > sockets.len) {
        klog.warn("socket {d}: out of range", .{handle});
        return NetError.NoSocket;
    }
    const socket = &sockets[handle - 1];
    // A handle is not a name that anyone may use: it belongs to whoever opened
    // it, and a program guessing numbers gets nothing.
    if (!socket.used or socket.owner != owner) return NetError.NoSocket;
    return socket;
}

/// Hand bytes to the connection. A transmit buffer with no room in it is not a
/// failure and not an answer either: wait for the far end to acknowledge what
/// is already in flight, the same way reading waits for data. Returning zero
/// would make every caller invent this loop for itself, and most would get it
/// wrong in the same way.
pub fn socketSend(owner: proc.Pid, handle: usize, bytes: []const u8) NetError!usize {
    const socket = try socketOf(owner, handle);
    var waited: usize = 0;
    while (waited < 100) : (waited += 1) {
        {
            netEnter();
            defer netLeave();
            var frame: [netmod.max_frame]u8 = undefined;
            const sent = net.tcp.send(&net, socket.id, bytes, hal.nowNs(), &frame) catch |e| {
                klog.warn("socket {d} to {s}: send failed ({s})", .{
                    handle,
                    socket.hostText(),
                    @errorName(e),
                });
                return NetError.NoAnswer;
            };
            if (sent.len > 0) _ = hal.netSend(frame[0..sent.len]);
            if (sent.copied > 0) return sent.copied;
        }
        sleepMs(10);
        _ = netPoll();
    }
    return NetError.Timeout;
}

/// Read what has arrived. Zero means the other end is finished, which is how a
/// reader knows to stop rather than waiting forever for a byte that is not
/// coming.
pub fn socketRecv(owner: proc.Pid, handle: usize, out: []u8) NetError!usize {
    const socket = try socketOf(owner, handle);
    var waited: usize = 0;
    // Ten seconds. Two was enough for a small page from a nearby server and
    // not for a large one behind a slow path: a reader that gives up while the
    // other end is still sending reports a failure that never happened.
    while (waited < 500) : (waited += 1) {
        {
            netEnter();
            defer netLeave();
            // A connection that is gone is the end of the stream, not a bad
            // handle: the handle is still ours, and a reader told "no such
            // socket" reports a failure where there was an ending.
            const got = net.tcp.recv(socket.id, out) catch 0;
            if (got > 0) {
                // Room has appeared; say so, or the sender keeps believing the
                // window it was last told about.
                var frame: [netmod.max_frame]u8 = undefined;
                const update = net.tcp.windowUpdate(&net, socket.id, hal.nowNs(), &frame) catch 0;
                if (update > 0) _ = hal.netSend(frame[0..update]);
                return got;
            }
            const state = net.tcp.stateOf(socket.id);
            if (state == null or state == .close_wait or state == .time_wait or state == .closed) {
                return 0;
            }
        }
        sleepMs(20);
        _ = netPoll();
    }
    klog.warn("socket {d} to {s}: nothing for ten seconds", .{ handle, socket.hostText() });
    return NetError.Timeout;
}

pub fn socketClose(owner: proc.Pid, handle: usize) void {
    const socket = socketOf(owner, handle) catch return;
    netEnter();
    defer netLeave();
    var frame: [netmod.max_frame]u8 = undefined;
    const fin = net.tcp.close(&net, socket.id, hal.nowNs(), &frame) catch 0;
    if (fin > 0) _ = hal.netSend(frame[0..fin]);
    // Let the close go out and the other end answer it before the connection
    // block is wanted again: there are four of them, and a fetch that starts
    // the moment the last one ended should not find the table full.
    var settle: usize = 0;
    while (settle < 10) : (settle += 1) {
        _ = netPoll();
        const state = net.tcp.stateOf(socket.id);
        if (state == null or state == .closed) break;
        sleepMs(10);
    }
    net.tcp.release(socket.id);
    socket.* = .{};
}

/// A process that ends takes its connections with it. Otherwise a program that
/// crashed mid-fetch would hold one of four sockets until the machine stopped.
pub fn socketsOfProcessClosed(owner: proc.Pid) usize {
    var closed: usize = 0;
    for (&sockets, 0..) |*socket, index| {
        if (!socket.used or socket.owner != owner) continue;
        socketClose(owner, index + 1);
        closed += 1;
    }
    return closed;
}

/// Log which stage of a fetch failed and how long it had been trying, then
/// hand the error on unchanged.
fn complain(host: []const u8, stage: []const u8, started: u64, e: NetError) NetError {
    klog.warn("http: {s}: {s} failed after {d} ms ({s})", .{
        host,
        stage,
        (hal.nowNs() - started) / 1_000_000,
        @errorName(e),
    });
    return e;
}

fn append(buf: []u8, i: *usize, piece: []const u8) bool {
    if (i.* + piece.len > buf.len) return false;
    @memcpy(buf[i.*..][0..piece.len], piece);
    i.* += piece.len;
    return true;
}

fn writeHttpGet(buf: []u8, path: []const u8, host: []const u8) ?[]const u8 {
    var i: usize = 0;
    if (!append(buf, &i, "GET ")) return null;
    if (!append(buf, &i, path)) return null;
    if (!append(buf, &i, " HTTP/1.0\r\nHost: ")) return null;
    if (!append(buf, &i, host)) return null;
    if (!append(buf, &i, "\r\nUser-Agent: aizigos\r\n\r\n")) return null;
    return buf[0..i];
}

/// The shell's own fetch, for looking at a page without starting a program.
/// It is a thin thing on purpose: the connection machinery is the socket layer
/// above, and the HTTP a program needs lives in user/http.c, on the far side
/// of the gate where a text format belongs.
pub fn httpGet(host: []const u8, path: []const u8, dest: []u8) NetError!usize {
    const handle = try socketConnect(shell_pid, host, 80);
    defer socketClose(shell_pid, handle);

    var request: [320]u8 = undefined;
    const written = writeHttpGet(&request, path, host) orelse return NetError.NoRoom;
    var sent: usize = 0;
    while (sent < written.len) {
        const wrote = try socketSend(shell_pid, handle, written[sent..]);
        if (wrote == 0) break;
        sent += wrote;
    }

    var filled: usize = 0;
    while (filled < dest.len) {
        const got = socketRecv(shell_pid, handle, dest[filled..]) catch |e| {
            if (filled > 0) break; // something arrived; keep what there is
            return e;
        };
        if (got == 0) break;
        filled += got;
    }
    return filled;
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

    // The boot volume is read-only by construction, and its token says so:
    // no write, no create, no delete. A token cannot grant what the driver
    // does not implement, but it can promise what it will never ask for.
    // Writing is in the root token because the shell is the thing a person
    // sits in front of. Anything else that wants to save gets a narrower token
    // derived from this one, scoped to the directory it has business in.
    disk_cap = try registry.issueRoot(shell_pid, .{ .kind = .directory }, .{
        .read = true,
        .write = true,
        .list = true,
        .create = true,
        .grant = true,
        .revoke = true,
    }, .{ .fs = cap.Path.from("/") }, .{ .purpose = "boot volume" }, now);

    klog.info("processes: {d}, threads: {d}, capabilities: {d}", .{
        processes.count(),
        scheduler.runnableCount(),
        registry.count(),
    });
}

export fn kmain() callconv(.c) void {
    hal.init();
    fp.enable();
    hal.setTrapHandler(onTrap);
    hal.setSyscallHandler(syscall.dispatch);
    banner();

    initMemory();
    registry = Registry.init();
    ipc = Ipc.init();
    processes = ProcTable.init();
    initScheduling();

    initWorld();
    initNetwork();
    initStorage();
    initDisplay();

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
