//! Минимальный драйвер GICv2 (QEMU -M virt).

const dist_base: usize = 0x0800_0000;
const cpu_base: usize = 0x0801_0000;

const GICD_CTLR: *volatile u32 = @ptrFromInt(dist_base + 0x000);
const GICD_ISENABLER: [*]volatile u32 = @ptrFromInt(dist_base + 0x100);
const GICD_IPRIORITYR: [*]volatile u8 = @ptrFromInt(dist_base + 0x400);

const GICC_CTLR: *volatile u32 = @ptrFromInt(cpu_base + 0x000);
const GICC_PMR: *volatile u32 = @ptrFromInt(cpu_base + 0x004);
const GICC_IAR: *volatile u32 = @ptrFromInt(cpu_base + 0x00C);
const GICC_EOIR: *volatile u32 = @ptrFromInt(cpu_base + 0x010);

pub const spurious: u32 = 1023;

pub fn init() void {
    GICD_CTLR.* = 1;
    GICC_PMR.* = 0xF0; // пропускать все приоритеты выше 0xF0
    GICC_CTLR.* = 1;
}

pub fn enableIrq(id: u32) void {
    GICD_IPRIORITYR[id] = 0x80;
    GICD_ISENABLER[id / 32] = @as(u32, 1) << @intCast(id % 32);
}

pub fn claim() u32 {
    return GICC_IAR.* & 0x3FF;
}

pub fn complete(id: u32) void {
    GICC_EOIR.* = id;
}
