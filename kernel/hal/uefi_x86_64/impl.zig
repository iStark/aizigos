//! HAL implementation for x86_64 machines booted through UEFI.
//!
//! It reuses the plain x86_64 device drivers (serial, PIT, IDT, paging,
//! context switch) and replaces only what UEFI changes: the machine arrives
//! already in long mode with paging on, the memory map comes from the
//! firmware, and there is a linear framebuffer to draw on.

const types = @import("../types.zig");
const serial = @import("../x86_64/serial.zig");
const pit = @import("../x86_64/pit.zig");
const paging = @import("../x86_64/paging.zig");
const context = @import("../x86_64/context.zig");
const idt = @import("../x86_64/idt.zig");

pub const boot = @import("boot.zig");
pub const fb = @import("fb.zig");
pub const kbd = @import("../x86_64/kbd.zig");

pub const target_name: []const u8 = "x86_64-uefi";
pub const page_size: usize = paging.page_size;
pub const max_cpus: usize = 8;

var tsc_hz: u64 = 1_000_000_000;
var tsc_base: u64 = 0;
var perf_level: types.PerfLevel = types.perf_nominal;
var kernel_trap: ?*const fn (types.TrapKind, u64, u64) void = null;

pub fn init() void {
    serial.init();
    // While the firmware is still alive this is the only way to be seen at all.
    boot.firmwareWrite("AIZigOS: taking over the machine\n");

    boot.takeOverMachine();

    idt.on_trap = onTrap;
    idt.init();
    pit.remapPic();
    kbd.init();
    tsc_hz = pit.calibrateTscHz();
    tsc_base = pit.rdtsc();
}

/// The HAL handles its own devices: keyboard interrupts never reach the kernel
/// as raw IRQs, they turn into characters in the keyboard ring buffer.
fn onTrap(kind: types.TrapKind, esr: u64, addr: u64) void {
    if (kind == .irq and addr == kbd.irq_line) {
        kbd.onIrq();
        return;
    }
    if (kernel_trap) |handler| handler(kind, esr, addr);
}

pub fn setTrapHandler(handler: ?*const fn (types.TrapKind, u64, u64) void) void {
    kernel_trap = handler;
}

pub fn consoleWrite(bytes: []const u8) void {
    serial.write(bytes);
    if (fb.ready()) {
        fb.write(bytes);
    } else {
        boot.firmwareWrite(bytes);
    }
}

pub fn readKey() ?u8 {
    // A PS/2 keyboard in a window, a serial line when headless: both count.
    return kbd.getKey() orelse serial.readByte();
}

pub fn memoryMap() []const types.MemRegion {
    return boot.memoryMap();
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
