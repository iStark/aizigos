//! PIT 8253: TSC calibration (channel 2) and one-shot timer (channel 0).

const serial = @import("serial.zig");
const outb = serial.outb;
const inb = serial.inb;

pub const base_hz: u64 = 1_193_182;

pub inline fn rdtsc() u64 {
    var hi: u32 = undefined;
    var lo: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

/// Calibrate the TSC frequency against PIT channel 2 (no interrupts needed).
pub fn calibrateTscHz() u64 {
    const ms = 10;
    const ticks: u16 = @intCast(base_hz * ms / 1000);

    // gate on, speaker off
    outb(0x61, (inb(0x61) & 0xFD) | 0x01);
    outb(0x43, 0b1011_0010); // channel 2, lo/hi, mode 0
    outb(0x42, @truncate(ticks));
    outb(0x42, @truncate(ticks >> 8));

    // restart the count
    const p = inb(0x61) & 0xFE;
    outb(0x61, p);
    outb(0x61, p | 1);

    const start = rdtsc();
    while (inb(0x61) & 0x20 == 0) {}
    const end = rdtsc();

    const elapsed = end - start;
    return elapsed * 1000 / ms;
}

/// Fire IRQ0 once after `count` PIT ticks.
pub fn armOneShot(count: u16) void {
    outb(0x43, 0b0011_0000); // channel 0, lo/hi, mode 0 (interrupt on terminal count)
    outb(0x40, @truncate(count));
    outb(0x40, @truncate(count >> 8));
}

/// Remap the PIC: IRQ0..15 onto vectors 0x20..0x2F.
pub fn remapPic() void {
    outb(0x20, 0x11);
    outb(0xA0, 0x11);
    outb(0x21, 0x20);
    outb(0xA1, 0x28);
    outb(0x21, 0x04);
    outb(0xA1, 0x02);
    outb(0x21, 0x01);
    outb(0xA1, 0x01);
    // Master: timer, keyboard and the cascade to the slave.
    outb(0x21, 0xF8);
    // Slave: the PS/2 mouse on IRQ12.
    outb(0xA1, 0xEF);
}

pub fn eoi(irq: u8) void {
    if (irq >= 8) outb(0xA0, 0x20);
    outb(0x20, 0x20);
}
