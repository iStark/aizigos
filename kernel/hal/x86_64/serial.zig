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

pub fn init() void {
    outb(port + 1, 0x00); // выключить прерывания
    outb(port + 3, 0x80); // DLAB
    outb(port + 0, 0x01); // делитель 1 => 115200
    outb(port + 1, 0x00);
    outb(port + 3, 0x03); // 8N1
    outb(port + 2, 0xC7); // FIFO, очистить, порог 14
    outb(port + 4, 0x03); // RTS/DSR
}

fn txReady() bool {
    return inb(port + 5) & 0x20 != 0;
}

pub fn writeByte(byte: u8) void {
    while (!txReady()) {}
    outb(port, byte);
}

pub fn write(bytes: []const u8) void {
    for (bytes) |b| {
        if (b == '\n') writeByte('\r');
        writeByte(b);
    }
}
