//! COM1 (0x3F8), 115200 8N1.

const port: u16 = 0x3F8;

pub inline fn outb(p: u16, value: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (value),
          [p] "N{dx}" (p),
    );
}

pub inline fn inb(p: u16) u8 {
    return asm volatile ("inb %[p], %[r]"
        : [r] "={al}" (-> u8),
        : [p] "N{dx}" (p),
    );
}

/// The disk hands over data a word at a time, so the port helpers grew a word
/// pair. They live here because this file is where port I/O is kept, whatever
/// its name says about serial lines.
pub inline fn outw(p: u16, value: u16) void {
    asm volatile ("outw %[v], %[p]"
        :
        : [v] "{ax}" (value),
          [p] "N{dx}" (p),
    );
}

pub inline fn inw(p: u16) u16 {
    return asm volatile ("inw %[p], %[r]"
        : [r] "={ax}" (-> u16),
        : [p] "N{dx}" (p),
    );
}

pub fn init() void {
    outb(port + 1, 0x00); // disable interrupts
    outb(port + 3, 0x80); // DLAB
    outb(port + 0, 0x01); // divisor 1 => 115200
    outb(port + 1, 0x00);
    outb(port + 3, 0x03); // 8N1
    outb(port + 2, 0xC7); // FIFO, clear, threshold 14
    outb(port + 4, 0x03); // RTS/DSR
}

fn txReady() bool {
    return inb(port + 5) & 0x20 != 0;
}

pub fn writeByte(byte: u8) void {
    while (!txReady()) {}
    outb(port, byte);
}

/// Next byte from the receive register, or null when nothing arrived.
/// A serial console is how a headless machine gets a keyboard.
pub fn readByte() ?u8 {
    if (inb(port + 5) & 0x01 == 0) return null;
    return inb(port);
}

pub fn write(bytes: []const u8) void {
    for (bytes) |b| {
        if (b == '\n') writeByte('\r');
        writeByte(b);
    }
}
