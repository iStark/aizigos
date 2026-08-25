//! HAL implementation for AArch64 / QEMU virt.
//! Satisfies the contract in kernel/hal/contract.zig (FR-1.4).

const types = @import("../types.zig");
const regs = @import("regs.zig");
const uart = @import("uart.zig");
const timer = @import("timer.zig");
const gic = @import("gic.zig");
const mmu = @import("mmu.zig");
const context = @import("context.zig");

pub const vectors = @import("vectors.zig");

comptime {
    _ = @import("boot.zig");
}

pub const target_name: []const u8 = "aarch64-qemu-virt";
pub const page_size: usize = mmu.page_size;
pub const max_cpus: usize = 4;

extern const __kernel_start: anyopaque;
extern const __kernel_end: anyopaque;

const ram_base: u64 = 0x4000_0000;
const ram_len: u64 = 512 << 20; // QEMU virt is started with -m 512M by default

var regions: [4]types.MemRegion = undefined;
var region_count: usize = 0;
var perf_level: types.PerfLevel = types.perf_nominal;

var kernel_space: mmu.AddressSpace = .{};

/// With the MMU off, AArch64 treats every access as Device memory, where an
/// unaligned load or store faults outright. The compiler emits unaligned
/// accesses freely, so the MMU is not an optimisation here: the kernel cannot
/// run a single formatted log line without it.
fn enableMmu() void {
    mmu.asInit(&kernel_space) catch {
        uart.write("[hal] no page tables for the kernel space\n");
        return;
    };
    // Everything below RAM is MMIO on QEMU virt: GIC, PL011, RTC, virtio.
    mmu.identityMap(&kernel_space, 0, ram_base, .{ .read = true, .write = true, .device = true }) catch {
        uart.write("[hal] failed to map device memory\n");
        return;
    };
    mmu.identityMap(&kernel_space, ram_base, ram_len, .{ .read = true, .write = true, .exec = true }) catch {
        uart.write("[hal] failed to map RAM\n");
        return;
    };
    mmu.enable(&kernel_space);
}

pub fn init() void {
    uart.init();
    enableMmu();
    vectors.install();
    gic.init();
    timer.init();
    gic.enableIrq(timer.irq);

    const kernel_end = (@intFromPtr(&__kernel_end) + page_size - 1) & ~@as(usize, page_size - 1);
    regions = .{
        .{ .base = 0x0800_0000, .len = 0x0002_0000, .kind = .device }, // GIC
        .{ .base = 0x0900_0000, .len = 0x0000_1000, .kind = .device }, // PL011
        .{ .base = ram_base, .len = kernel_end - ram_base, .kind = .reserved },
        .{ .base = kernel_end, .len = ram_base + ram_len - kernel_end, .kind = .usable },
    };
    region_count = 4;
}

pub fn consoleWrite(bytes: []const u8) void {
    uart.write(bytes);
}

pub fn readKey() ?u8 {
    return uart.readByte();
}

/// QEMU virt has no PS/2 controller; a pointer would arrive over USB HID,
/// which is a driver this kernel does not have yet.
pub fn readPointer() ?types.PointerEvent {
    return null;
}

pub fn memoryMap() []const types.MemRegion {
    return regions[0..region_count];
}

pub fn nowNs() u64 {
    return timer.nowNs();
}

pub fn armTimer(ns: u64) void {
    timer.arm(ns);
}

pub fn setTrapHandler(handler: ?types.TrapHandler) void {
    vectors.on_trap = handler;
}

pub fn setSyscallHandler(handler: ?types.SyscallHandler) void {
    vectors.on_syscall = handler;
}

pub fn interruptsEnable() void {
    asm volatile ("msr daifclr, #2");
}

pub fn interruptsDisable() void {
    asm volatile ("msr daifset, #2");
}

pub fn interruptsEnabled() bool {
    return (regs.mrs("daif") & (1 << 7)) == 0;
}

pub fn cpuId() u32 {
    return @truncate(regs.mrs("mpidr_el1") & 0xFF);
}

pub fn idle() void {
    regs.wfi();
}

pub fn deepIdle(max_ns: u64) void {
    // The scheduler already armed the timer; in power-save just sleep until it.
    if (max_ns > 0) timer.arm(max_ns);
    regs.wfi();
}

/// DVFS. QEMU has no real frequency control, so the level is only recorded,
/// for auditing and for platforms where PSCI/CPPC actually exist.
pub fn setPerfLevel(level: types.PerfLevel) void {
    perf_level = level;
}

pub fn currentPerfLevel() types.PerfLevel {
    return perf_level;
}

pub fn halt() noreturn {
    interruptsDisable();
    while (true) regs.wfi();
}

pub fn currentSpace() *mmu.AddressSpace {
    return &kernel_space;
}

var trap_stack_top: usize = 0;

/// On AArch64 the kernel keeps its own stack pointer (SP_EL1) across an
/// exception from EL0, so this only records where that stack is.
pub fn setKernelStack(top: usize) void {
    trap_stack_top = top;
}

/// Drop to EL0: the exception return picks the level out of SPSR, the entry
/// point out of ELR and the stack out of SP_EL0.
pub fn enterUserMode(entry: usize, user_stack_top: usize) noreturn {
    regs.msr("sp_el0", user_stack_top);
    regs.msr("elr_el1", entry);
    // EL0t with interrupts unmasked.
    regs.msr("spsr_el1", 0);
    asm volatile ("eret");
    unreachable;
}

pub const AddressSpace = mmu.AddressSpace;
pub const asInit = mmu.asInit;
pub const asDeinit = mmu.asDeinit;
pub const asMap = mmu.asMap;
pub const asUnmap = mmu.asUnmap;
pub const asTranslate = mmu.asTranslate;
pub const asActivate = mmu.asActivate;

pub const Context = context.Context;
pub const ctxInit = context.ctxInit;
pub const ctxSwitch = context.ctxSwitch;
