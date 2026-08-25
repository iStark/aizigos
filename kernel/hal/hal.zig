//! HAL facade: the single place where the kernel picks a per-arch implementation.
//!
//! The rest of the kernel imports only this module and `hal/types.zig`.
//! Registering a new target = one line in `impl` plus a directory with an
//! implementation that passes `contract.verify` (FR-1.4).

const builtin = @import("builtin");
const contract = @import("contract.zig");

pub const types = @import("types.zig");
pub const MapFlags = types.MapFlags;
pub const MemRegion = types.MemRegion;
pub const MmuError = types.MmuError;
pub const PerfLevel = types.PerfLevel;
pub const PhysAddr = types.PhysAddr;
pub const VirtAddr = types.VirtAddr;

pub const impl = switch (builtin.os.tag) {
    // Booted by firmware: the machine arrives in long mode with a framebuffer.
    .uefi => @import("uefi_x86_64/impl.zig"),
    .freestanding => switch (builtin.cpu.arch) {
        .aarch64 => @import("aarch64/impl.zig"),
        .x86_64 => @import("x86_64/impl.zig"),
        else => @compileError("No HAL for this architecture. Add kernel/hal/<arch>/impl.zig following contract.zig"),
    },
    // Host implementation: for `zig build test` only, touches no hardware.
    else => @import("host/impl.zig"),
};

comptime {
    contract.verify(impl);
}

pub const target_name: []const u8 = impl.target_name;
pub const page_size: usize = impl.page_size;
pub const max_cpus: usize = impl.max_cpus;

pub const AddressSpace = impl.AddressSpace;
pub const Context = impl.Context;

pub inline fn init() void {
    impl.init();
}
pub inline fn consoleWrite(bytes: []const u8) void {
    impl.consoleWrite(bytes);
}
/// Next typed character, or null when nothing is pending. The platform
/// decides what "typed" means: a PS/2 keyboard, a UART, a firmware console.
pub inline fn readKey() ?u8 {
    return impl.readKey();
}
/// Next pointer movement, if a pointing device reported one.
pub inline fn readPointer() ?types.PointerEvent {
    return impl.readPointer();
}
/// The hardware address of the network interface, if the machine has one.
pub inline fn netAddress() ?[6]u8 {
    return impl.netAddress();
}

/// Hand a frame to the interface. False means the transmit ring is busy.
pub inline fn netSend(frame: []const u8) bool {
    return impl.netSend(frame);
}

/// Take the next received frame, if one is waiting.
pub inline fn netReceive(out: []u8) ?usize {
    return impl.netReceive(out);
}

pub inline fn memoryMap() []const MemRegion {
    return impl.memoryMap();
}

/// Whether this machine has a block device the kernel can read.
pub inline fn diskPresent() bool {
    return impl.diskPresent();
}

/// Read whole sectors starting at `lba`. The buffer length is a multiple of
/// 512, and false means the contents are not to be trusted.
pub inline fn diskRead(lba: u64, buffer: []u8) bool {
    return impl.diskRead(lba, buffer);
}
pub inline fn nowNs() u64 {
    return impl.nowNs();
}
pub inline fn armTimer(ns: u64) void {
    impl.armTimer(ns);
}
pub const TrapHandler = ?types.TrapHandler;

/// The kernel installs one trap handler; the HAL decides which vector
/// mechanism calls it (FR-1.4).
pub inline fn setTrapHandler(handler: TrapHandler) void {
    impl.setTrapHandler(handler);
}
/// The kernel installs one system call handler; the HAL is responsible for
/// pulling the arguments out of the trap frame and putting the result back.
pub inline fn setSyscallHandler(handler: ?types.SyscallHandler) void {
    impl.setSyscallHandler(handler);
}
pub inline fn interruptsEnable() void {
    impl.interruptsEnable();
}
pub inline fn interruptsDisable() void {
    impl.interruptsDisable();
}
pub inline fn interruptsEnabled() bool {
    return impl.interruptsEnabled();
}
pub inline fn cpuId() u32 {
    return impl.cpuId();
}
pub inline fn idle() void {
    impl.idle();
}
pub inline fn deepIdle(max_ns: u64) void {
    impl.deepIdle(max_ns);
}
pub inline fn setPerfLevel(level: PerfLevel) void {
    impl.setPerfLevel(level);
}
pub inline fn halt() noreturn {
    impl.halt();
}

pub inline fn asInit(space: *AddressSpace) MmuError!void {
    return impl.asInit(space);
}
pub inline fn asDeinit(space: *AddressSpace) void {
    impl.asDeinit(space);
}
pub inline fn asMap(space: *AddressSpace, va: VirtAddr, pa: PhysAddr, flags: MapFlags) MmuError!void {
    return impl.asMap(space, va, pa, flags);
}
pub inline fn asUnmap(space: *AddressSpace, va: VirtAddr, pages: usize) MmuError!void {
    return impl.asUnmap(space, va, pages);
}
pub inline fn asTranslate(space: *AddressSpace, va: VirtAddr) ?PhysAddr {
    return impl.asTranslate(space, va);
}
pub inline fn asActivate(space: *AddressSpace) void {
    impl.asActivate(space);
}

/// The address space the CPU is currently translating through.
pub inline fn currentSpace() *AddressSpace {
    return impl.currentSpace();
}

/// Drop to the unprivileged level and start running there. Never returns: the
/// thread continues in user mode until it traps back in.
pub inline fn enterUserMode(entry: usize, user_stack_top: usize) noreturn {
    impl.enterUserMode(entry, user_stack_top);
}

/// Which stack a trap from user mode should land on.
pub inline fn setKernelStack(top: usize) void {
    impl.setKernelStack(top);
}

pub inline fn ctxInit(ctx: *Context, entry: usize, stack_top: usize, arg: usize) void {
    impl.ctxInit(ctx, entry, stack_top, arg);
}
pub inline fn ctxSwitch(from: *Context, to: *Context) void {
    impl.ctxSwitch(from, to);
}

/// Critical section: disables interrupts and returns a token to restore them.
pub const IrqGuard = struct {
    was_enabled: bool,

    pub fn acquire() IrqGuard {
        const was = impl.interruptsEnabled();
        impl.interruptsDisable();
        return .{ .was_enabled = was };
    }

    pub fn release(self: IrqGuard) void {
        if (self.was_enabled) impl.interruptsEnable();
    }
};
