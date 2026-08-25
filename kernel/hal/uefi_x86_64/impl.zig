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
const gdt = @import("../x86_64/gdt.zig");

pub const boot = @import("boot.zig");
pub const fb = @import("fb.zig");
pub const kbd = @import("../x86_64/kbd.zig");
pub const mouse = @import("../x86_64/mouse.zig");
pub const e1000 = @import("../x86_64/e1000.zig");
pub const ata = @import("../x86_64/ata.zig");

pub const target_name: []const u8 = "x86_64-uefi";
pub const page_size: usize = paging.page_size;
pub const max_cpus: usize = 8;

var tsc_hz: u64 = 1_000_000_000;
var tsc_base: u64 = 0;
var perf_level: types.PerfLevel = types.perf_nominal;
var kernel_trap: ?types.TrapHandler = null;

var kernel_space: paging.AddressSpace = .{};
var own_tables = false;

/// Stop borrowing the firmware's page tables.
///
/// UEFI leaves an identity mapping behind and it keeps working, but it is not
/// ours: nothing says what it maps, its permissions are the firmware's idea,
/// and a process address space cannot be built next to it. So the kernel
/// builds its own identity map of the memory it was told about, plus the
/// framebuffer, and switches CR3 to it.
fn buildKernelSpace() void {
    paging.asInit(&kernel_space) catch {
        serial.write("[hal] no page tables for the kernel space\n");
        return;
    };

    const rw = types.MapFlags{ .read = true, .write = true, .exec = true };
    for (boot.memoryMap()) |region| {
        const flags = if (region.kind == .device)
            types.MapFlags{ .read = true, .write = true, .device = true }
        else
            rw;
        paging.identityMap(&kernel_space, region.base, region.len, flags) catch {
            serial.write("[hal] identity map ran out of tables\n");
            return;
        };
    }
    // Device registers live in the PCI hole below 4 GiB and never appear in
    // the firmware's memory map. Without them the kernel boots fine and then
    // faults the first time a driver touches its card — which is exactly what
    // happened. RAM is mapped first, so anything already covered stays as it
    // was; this only fills the gaps.
    paging.identityMap(&kernel_space, 0x8000_0000, 0x8000_0000, .{
        .read = true,
        .write = true,
        .device = true,
    }) catch {
        serial.write("[hal] could not map the device window\n");
    };

    // The framebuffer is MMIO and usually absent from the memory map.
    if (fb.info()) |f| {
        paging.identityMap(&kernel_space, f.base, @as(u64, f.pitch) * f.height, .{
            .read = true,
            .write = true,
            .device = true,
        }) catch {};
    }

    paging.asActivate(&kernel_space);
    own_tables = true;
}

/// Whether the kernel is running on page tables it built itself.
pub fn onOwnPageTables() bool {
    return own_tables;
}

pub fn init() void {
    serial.init();
    // While the firmware is still alive this is the only way to be seen at all.
    boot.firmwareWrite("AIZigOS: taking over the machine\n");

    boot.takeOverMachine();

    // The GDT comes first: the IDT records the code selector that is current
    // when it is built, and ring 3 needs segments the firmware never had.
    gdt.init(bootStackTop());
    idt.on_trap = onTrap;
    idt.init();
    pit.remapPic();
    kbd.init();
    mouse.init();
    e1000.init();
    ata.init();
    tsc_hz = pit.calibrateTscHz();
    tsc_base = pit.rdtsc();
    buildKernelSpace();
}

/// The HAL handles its own devices: keyboard interrupts never reach the kernel
/// as raw IRQs, they turn into characters in the keyboard ring buffer.
fn onTrap(kind: types.TrapKind, esr: u64, addr: u64, from_user: bool) void {
    if (kind == .irq and addr == kbd.irq_line) {
        kbd.onIrq();
        return;
    }
    if (kind == .irq and addr == mouse.irq_line) {
        mouse.onIrq();
        return;
    }
    if (kernel_trap) |handler| handler(kind, esr, addr, from_user);
}

pub fn setTrapHandler(handler: ?types.TrapHandler) void {
    kernel_trap = handler;
}

pub fn setSyscallHandler(handler: ?types.SyscallHandler) void {
    idt.on_syscall = handler;
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

pub fn readPointer() ?types.PointerEvent {
    return mouse.read();
}

pub fn netAddress() ?[6]u8 {
    return e1000.address();
}

pub fn netSend(frame: []const u8) bool {
    return e1000.send(frame);
}

pub fn netReceive(out: []u8) ?usize {
    return e1000.receive(out);
}

pub fn memoryMap() []const types.MemRegion {
    return boot.memoryMap();
}

pub fn diskPresent() bool {
    return ata.present();
}

pub fn diskRead(lba: u64, buffer: []u8) bool {
    return ata.read(lba, buffer);
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

/// Where the boot stack ends; used as the initial trap stack until a thread
/// with its own kernel stack enters user mode.
fn bootStackTop() u64 {
    return asm volatile ("movq %%rsp, %[out]"
        : [out] "=r" (-> u64),
    );
}

pub fn currentSpace() *paging.AddressSpace {
    return &kernel_space;
}

pub fn enterUserMode(entry: usize, user_stack_top: usize) noreturn {
    gdt.enterUserMode(@intCast(entry), @intCast(user_stack_top));
}

pub fn setKernelStack(top: usize) void {
    gdt.setKernelStack(@intCast(top));
}

pub const AddressSpace = paging.AddressSpace;
pub const asInit = paging.asInit;
pub const asInitFromKernel = paging.asInitFromKernel;
pub const asDeinit = paging.asDeinit;
pub const asMap = paging.asMap;
pub const asUnmap = paging.asUnmap;
pub const asTranslate = paging.asTranslate;
pub const asActivate = paging.asActivate;

pub const Context = context.Context;
pub const ctxInit = context.ctxInit;
pub const ctxSwitch = context.ctxSwitch;
