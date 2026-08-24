//! HAL implementation for x86_64 (Multiboot2 / QEMU q35).
//! Satisfies the contract in kernel/hal/contract.zig (FR-1.4).

const types = @import("../types.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");
const paging = @import("paging.zig");
const context = @import("context.zig");

pub const idt = @import("idt.zig");

comptime {
    _ = @import("boot.zig");
}

pub const target_name: []const u8 = "x86_64-multiboot2";
pub const page_size: usize = paging.page_size;
pub const max_cpus: usize = 8;

extern const __kernel_end: anyopaque;

var regions: [3]types.MemRegion = undefined;
var region_count: usize = 0;
var tsc_hz: u64 = 1_000_000_000;
var tsc_base: u64 = 0;
var perf_level: types.PerfLevel = types.perf_nominal;

pub fn init() void {
    serial.init();
    idt.init();
    pit.remapPic();
    tsc_hz = pit.calibrateTscHz();
    tsc_base = pit.rdtsc();

    const kernel_end = (@intFromPtr(&__kernel_end) + page_size - 1) & ~@as(usize, page_size - 1);
    regions = .{
        .{ .base = 0, .len = 0x0010_0000, .kind = .reserved },
        .{ .base = 0x0010_0000, .len = kernel_end - 0x0010_0000, .kind = .reserved },
        // Conservative: 128 MiB past the kernel. Stage 2 parses the Multiboot2 map.
        .{ .base = kernel_end, .len = 128 << 20, .kind = .usable },
    };
    region_count = 3;
}

pub fn consoleWrite(bytes: []const u8) void {
    serial.write(bytes);
}

pub fn memoryMap() []const types.MemRegion {
    return regions[0..region_count];
}

pub fn nowNs() u64 {
    const delta = pit.rdtsc() -% tsc_base;
    return @intCast(@as(u128, delta) * 1_000_000_000 / tsc_hz);
}

pub fn armTimer(ns: u64) void {
    const ticks = @as(u128, ns) * pit.base_hz / 1_000_000_000;
    const clamped: u16 = @intCast(@max(@as(u128, 1), @min(ticks, 65535)));
    pit.armOneShot(clamped);
}

pub fn setTrapHandler(handler: ?*const fn (types.TrapKind, u64, u64) void) void {
    idt.on_trap = handler;
}

pub fn interruptsEnable() void {
    asm volatile ("sti");
}

pub fn interruptsDisable() void {
    asm volatile ("cli");
}

pub fn interruptsEnabled() bool {
    const flags = asm volatile (
        \\pushfq
        \\popq %[out]
        : [out] "=r" (-> u64),
    );
    return flags & 0x200 != 0;
}

pub fn cpuId() u32 {
    return 0; // stage 2: APIC ID
}

pub fn idle() void {
    asm volatile ("hlt");
}

pub fn deepIdle(max_ns: u64) void {
    if (max_ns > 0) armTimer(max_ns);
    asm volatile ("hlt");
}

pub fn setPerfLevel(level: types.PerfLevel) void {
    perf_level = level; // stage 2: MSR_IA32_HWP_REQUEST
}

pub fn currentPerfLevel() types.PerfLevel {
    return perf_level;
}

pub fn halt() noreturn {
    interruptsDisable();
    while (true) asm volatile ("hlt");
}

pub const AddressSpace = paging.AddressSpace;
pub const asInit = paging.asInit;
pub const asDeinit = paging.asDeinit;
pub const asMap = paging.asMap;
pub const asUnmap = paging.asUnmap;
pub const asTranslate = paging.asTranslate;
pub const asActivate = paging.asActivate;

pub const Context = context.Context;
pub const ctxInit = context.ctxInit;
pub const ctxSwitch = context.ctxSwitch;
