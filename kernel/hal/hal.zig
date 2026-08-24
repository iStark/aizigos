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

pub const impl = if (builtin.os.tag != .freestanding)
    // Host implementation: for `zig build test` only, touches no hardware.
    @import("host/impl.zig")
else switch (builtin.cpu.arch) {
    .aarch64 => @import("aarch64/impl.zig"),
    .x86_64 => @import("x86_64/impl.zig"),
    else => @compileError("No HAL for this architecture. Add kernel/hal/<arch>/impl.zig following contract.zig"),
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
pub inline fn memoryMap() []const MemRegion {
    return impl.memoryMap();
}
pub inline fn nowNs() u64 {
    return impl.nowNs();
}
pub inline fn armTimer(ns: u64) void {
    impl.armTimer(ns);
}
pub const TrapHandler = ?*const fn (types.TrapKind, u64, u64) void;

/// The kernel installs one trap handler; the HAL decides which vector
/// mechanism calls it (FR-1.4).
pub inline fn setTrapHandler(handler: TrapHandler) void {
    impl.setTrapHandler(handler);
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
