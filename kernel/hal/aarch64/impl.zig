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

pub fn init() void {
    uart.init();
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

pub fn memoryMap() []const types.MemRegion {
    return regions[0..region_count];
}

pub fn nowNs() u64 {
    return timer.nowNs();
}

pub fn armTimer(ns: u64) void {
    timer.arm(ns);
}

pub fn setTrapHandler(handler: ?*const fn (types.TrapKind, u64, u64) void) void {
    vectors.on_trap = handler;
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
