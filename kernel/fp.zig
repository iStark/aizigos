//! Lazy user-mode floating point.
//!
//! The kernel itself is compiled without FP on the freestanding boards and
//! does not save FX state in `ctxSwitch`. The first user FP instruction traps
//! (#NM / CPACR), the previous owner's state is stored, and the unit is handed
//! over. UEFI kernels may emit SSE in memcpy: CR0.TS stays clear while a
//! kernel thread runs.

const builtin = @import("builtin");
const sched = @import("sched/sched.zig");

const supported = (builtin.os.tag == .freestanding or builtin.os.tag == .uefi) and
    (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64);

const max_areas = 64;
const area_bytes = 512;

var areas: [max_areas][area_bytes]u8 align(16) = @splat(@splat(0));
var used: [max_areas]bool = @splat(false);
var owner: ?sched.Tid = null;

fn idx(tid: sched.Tid) ?usize {
    if (tid == 0 or tid > max_areas) return null;
    return tid - 1;
}

fn currentTid() ?sched.Tid {
    const root = @import("root");
    return root.scheduler.current;
}

pub fn enable() void {
    if (!supported) return;
    switch (builtin.cpu.arch) {
        .x86_64 => {
            var cr0 = readCr0();
            cr0 |= 1 << 1; // MP
            cr0 &= ~@as(u64, 1 << 2); // EM
            writeCr0(cr0);
            var cr4 = readCr4();
            cr4 |= (1 << 9) | (1 << 10); // OSFXSR | OSXMMEXCPT
            writeCr4(cr4);
            clearTs();
        },
        .aarch64 => {
            // FPEN = 00: trap EL0 and EL1. The kernel on this board has no FP.
            var cpacr = readCpacr();
            cpacr &= ~@as(u64, 0b11 << 20);
            writeCpacr(cpacr);
        },
        else => {},
    }
}

pub fn onKernelEntry(from_user: bool) void {
    if (!supported) return;
    if (!from_user) {
        clearTs();
        return;
    }
    const tid = currentTid() orelse return;
    if (owner == tid) save(tid);
    clearTs();
}

pub fn prepareReturnToUser() void {
    if (!supported) return;
    const tid = currentTid() orelse {
        clearTs();
        return;
    };
    if (owner == tid) {
        restore(tid);
        clearTs();
    } else {
        setTs();
    }
}

/// Returns true if the trap was the lazy-FP handshake and the instruction
/// should be retried.
pub fn handleUnavailable(from_user: bool) bool {
    if (!supported) return false;
    if (!from_user) {
        clearTs();
        return true;
    }
    const tid = currentTid() orelse return false;
    if (owner) |prev| {
        if (prev != tid) save(prev);
    }
    const i = idx(tid) orelse return false;
    if (!used[i]) {
        initArea(i);
        used[i] = true;
    }
    restore(tid);
    owner = tid;
    clearTs();
    return true;
}

fn save(tid: sched.Tid) void {
    const i = idx(tid) orelse return;
    if (!used[i]) return;
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("fxsave64 (%[p])"
            :
            : [p] "r" (&areas[i]),
            : .{ .memory = true }),
        .aarch64 => saveAarch64(&areas[i]),
        else => {},
    }
}

fn restore(tid: sched.Tid) void {
    const i = idx(tid) orelse return;
    if (!used[i]) return;
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("fxrstor64 (%[p])"
            :
            : [p] "r" (&areas[i]),
            : .{ .memory = true }),
        .aarch64 => restoreAarch64(&areas[i]),
        else => {},
    }
}

fn initArea(i: usize) void {
    @memset(&areas[i], 0);
    // FCW = 0x037F, MXCSR = 0x1F80 — the x87/SSE defaults after FNINIT.
    areas[i][0] = 0x7F;
    areas[i][1] = 0x03;
    areas[i][24] = 0x80;
    areas[i][25] = 0x1F;
}

fn setTs() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        var cr0 = readCr0();
        cr0 |= 1 << 3;
        writeCr0(cr0);
    } else if (comptime builtin.cpu.arch == .aarch64) {
        var cpacr = readCpacr();
        cpacr &= ~@as(u64, 0b11 << 20);
        writeCpacr(cpacr);
    }
}

fn clearTs() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("clts");
    } else if (comptime builtin.cpu.arch == .aarch64) {
        var cpacr = readCpacr();
        cpacr |= 0b11 << 20;
        writeCpacr(cpacr);
    }
}

fn readCr0() u64 {
    if (comptime builtin.cpu.arch != .x86_64) return 0;
    return asm volatile ("movq %%cr0, %[v]"
        : [v] "=r" (-> u64),
    );
}

fn writeCr0(v: u64) void {
    if (comptime builtin.cpu.arch != .x86_64) return;
    asm volatile ("movq %[v], %%cr0"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

fn readCr4() u64 {
    if (comptime builtin.cpu.arch != .x86_64) return 0;
    return asm volatile ("movq %%cr4, %[v]"
        : [v] "=r" (-> u64),
    );
}

fn writeCr4(v: u64) void {
    if (comptime builtin.cpu.arch != .x86_64) return;
    asm volatile ("movq %[v], %%cr4"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

fn readCpacr() u64 {
    if (comptime builtin.cpu.arch != .aarch64) return 0;
    return asm volatile ("mrs %[v], cpacr_el1"
        : [v] "=r" (-> u64),
    );
}

fn writeCpacr(v: u64) void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    asm volatile (
        \\msr cpacr_el1, %[v]
        \\isb
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

fn saveAarch64(area: *[area_bytes]u8) void {
    _ = area;
}

fn restoreAarch64(area: *[area_bytes]u8) void {
    _ = area;
}
