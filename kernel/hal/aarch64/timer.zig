//! ARM Generic Timer (EL1 physical timer).

const regs = @import("regs.zig");

pub const irq: u32 = 30; // PPI 30 = CNTP

var freq_hz: u64 = 62_500_000;

pub fn init() void {
    const f = regs.mrs("cntfrq_el0");
    if (f != 0) freq_hz = f;
    regs.msr("cntp_ctl_el0", 0);
}

pub fn frequency() u64 {
    return freq_hz;
}

pub fn nowNs() u64 {
    const ticks = regs.mrs("cntpct_el0");
    return @intCast(@as(u128, ticks) * 1_000_000_000 / freq_hz);
}

/// Program a one-shot firing `ns` nanoseconds from now.
pub fn arm(ns: u64) void {
    const ticks = @as(u128, ns) * freq_hz / 1_000_000_000;
    const tval: u64 = @intCast(@min(ticks, @as(u128, @as(u32, 0x7fff_ffff))));
    regs.msr("cntp_tval_el0", tval);
    regs.msr("cntp_ctl_el0", 1); // ENABLE, mask cleared
}

pub fn disarm() void {
    regs.msr("cntp_ctl_el0", 0);
}

/// Acknowledge the firing (drop the interrupt level).
pub fn ack() void {
    regs.msr("cntp_ctl_el0", 2); // ENABLE=0, IMASK=1
}
