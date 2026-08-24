//! PL011 UART (QEMU -M virt: 0x0900_0000).

const base: usize = 0x0900_0000;

const DR: *volatile u32 = @ptrFromInt(base + 0x00);
const FR: *volatile u32 = @ptrFromInt(base + 0x18);
const IBRD: *volatile u32 = @ptrFromInt(base + 0x24);
const FBRD: *volatile u32 = @ptrFromInt(base + 0x28);
const LCRH: *volatile u32 = @ptrFromInt(base + 0x2C);
const CR: *volatile u32 = @ptrFromInt(base + 0x30);
const IMSC: *volatile u32 = @ptrFromInt(base + 0x38);

const fr_txff: u32 = 1 << 5;

pub fn init() void {
    CR.* = 0; // выключить на время настройки
    IBRD.* = 26; // 24 МГц / (16 * 115200)
    FBRD.* = 3;
    LCRH.* = (0b11 << 5) | (1 << 4); // 8N1 + FIFO
    IMSC.* = 0;
    CR.* = (1 << 0) | (1 << 8) | (1 << 9); // UARTEN | TXE | RXE
}

pub fn writeByte(byte: u8) void {
    while (FR.* & fr_txff != 0) {}
    DR.* = byte;
}

pub fn write(bytes: []const u8) void {
    for (bytes) |b| {
        if (b == '\n') writeByte('\r');
        writeByte(b);
    }
}
