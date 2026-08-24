//! Host HAL implementation, used by unit tests only.
//! It touches no hardware: time is virtual and driven by the test, and the
//! MMU is a software model of mappings.

const std = @import("std");
const types = @import("../types.zig");

pub const target_name: []const u8 = "host-test";
pub const page_size: usize = 4096;
pub const max_cpus: usize = 1;

var virtual_now_ns: u64 = 0;
var timer_deadline_ns: u64 = 0;
var irq_on: bool = false;
var perf_level: types.PerfLevel = types.perf_nominal;
var deep_idle_ns: u64 = 0;

/// Test hook: advance the virtual clock.
pub fn testAdvance(ns: u64) void {
    virtual_now_ns += ns;
}

/// Test hook: the DVFS level the power policy has set.
pub fn testPerfLevel() types.PerfLevel {
    return perf_level;
}

/// Test hook: nanoseconds the kernel spent in deep idle.
pub fn testDeepIdleNs() u64 {
    return deep_idle_ns;
}

pub fn testReset() void {
    virtual_now_ns = 0;
    timer_deadline_ns = 0;
    irq_on = false;
    perf_level = types.perf_nominal;
    deep_idle_ns = 0;
}

const host_memory = [_]types.MemRegion{
    .{ .base = 0x0000_0000, .len = 1 << 20, .kind = .reserved },
    .{ .base = 0x0010_0000, .len = 64 << 20, .kind = .usable },
};

pub fn init() void {
    testReset();
}

pub fn consoleWrite(bytes: []const u8) void {
    std.debug.print("{s}", .{bytes});
}

pub fn memoryMap() []const types.MemRegion {
    return &host_memory;
}

pub fn nowNs() u64 {
    return virtual_now_ns;
}

pub fn armTimer(ns: u64) void {
    timer_deadline_ns = virtual_now_ns + ns;
}

var trap_handler: ?*const fn (types.TrapKind, u64, u64) void = null;

pub fn setTrapHandler(handler: ?*const fn (types.TrapKind, u64, u64) void) void {
    trap_handler = handler;
}

/// Test hook: simulate a trap.
pub fn testFireTrap(kind: types.TrapKind, esr: u64, addr: u64) void {
    if (trap_handler) |h| h(kind, esr, addr);
}

pub fn interruptsEnable() void {
    irq_on = true;
}
pub fn interruptsDisable() void {
    irq_on = false;
}
pub fn interruptsEnabled() bool {
    return irq_on;
}

pub fn cpuId() u32 {
    return 0;
}

pub fn idle() void {
    virtual_now_ns += 1000;
}

pub fn deepIdle(max_ns: u64) void {
    deep_idle_ns += max_ns;
    virtual_now_ns += max_ns;
}

pub fn setPerfLevel(level: types.PerfLevel) void {
    perf_level = level;
}

pub fn halt() noreturn {
    @panic("hal.halt() called on the host");
}

// --- software model of an address space ---------------------------------

const max_mappings = 256;

pub const AddressSpace = struct {
    const Entry = struct {
        va: types.VirtAddr = 0,
        pa: types.PhysAddr = 0,
        flags: types.MapFlags = .{},
        live: bool = false,
    };

    entries: [max_mappings]Entry = @splat(.{}),
    active: bool = false,
    id: u32 = 0,
};

var next_space_id: u32 = 1;

pub fn asInit(space: *AddressSpace) types.MmuError!void {
    space.* = .{ .id = next_space_id };
    next_space_id += 1;
}

pub fn asDeinit(space: *AddressSpace) void {
    space.* = .{};
}

pub fn asMap(space: *AddressSpace, va: types.VirtAddr, pa: types.PhysAddr, flags: types.MapFlags) types.MmuError!void {
    if (va % page_size != 0 or pa % page_size != 0) return error.Misaligned;
    var free_slot: ?usize = null;
    for (&space.entries, 0..) |*e, i| {
        if (e.live and e.va == va) return error.AlreadyMapped;
        if (!e.live and free_slot == null) free_slot = i;
    }
    const slot = free_slot orelse return error.OutOfTables;
    space.entries[slot] = .{ .va = va, .pa = pa, .flags = flags, .live = true };
}

pub fn asUnmap(space: *AddressSpace, va: types.VirtAddr, pages: usize) types.MmuError!void {
    var page: usize = 0;
    while (page < pages) : (page += 1) {
        const target = va + page * page_size;
        var hit = false;
        for (&space.entries) |*e| {
            if (e.live and e.va == target) {
                e.live = false;
                hit = true;
                break;
            }
        }
        if (!hit) return error.NotMapped;
    }
}

pub fn asTranslate(space: *AddressSpace, va: types.VirtAddr) ?types.PhysAddr {
    const base = va - (va % page_size);
    for (&space.entries) |*e| {
        if (e.live and e.va == base) return e.pa + (va % page_size);
    }
    return null;
}

pub fn asActivate(space: *AddressSpace) void {
    space.active = true;
}

// --- context ------------------------------------------------------------

pub const Context = struct {
    entry: usize = 0,
    stack_top: usize = 0,
    arg: usize = 0,
    switches: u32 = 0,
    started: bool = false,
};

pub fn ctxInit(ctx: *Context, entry: usize, stack_top: usize, arg: usize) void {
    ctx.* = .{ .entry = entry, .stack_top = stack_top, .arg = arg };
}

/// No real switch on the host: record the fact so tests can assert on it.
pub fn ctxSwitch(from: *Context, to: *Context) void {
    from.switches += 1;
    to.started = true;
}
