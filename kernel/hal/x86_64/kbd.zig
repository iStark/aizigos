//! PS/2 keyboard (i8042), scan code set 1.
//!
//! Works both from the IRQ1 handler and by polling, so a shell stays usable
//! even when interrupt delivery is not yet trusted on a given machine.

const io = @import("serial.zig");

const data_port: u16 = 0x60;
const status_port: u16 = 0x64;

pub const irq_line: u8 = 1;

const ring_size = 64;
var ring: [ring_size]u8 = @splat(0);
var head: usize = 0;
var tail: usize = 0;

var shift_down = false;
var caps_lock = false;
var extended = false;

fn push(c: u8) void {
    const next = (head + 1) % ring_size;
    if (next == tail) return; // full: drop, a human cannot outrun this
    ring[head] = c;
    head = next;
}

/// Pop the next character, or null when nothing has been typed.
pub fn getKey() ?u8 {
    poll();
    if (tail == head) return null;
    const c = ring[tail];
    tail = (tail + 1) % ring_size;
    return c;
}

pub fn hasKey() bool {
    poll();
    return tail != head;
}

/// Drain whatever the controller has ready. Safe to call with interrupts off.
pub fn poll() void {
    var guard: usize = 0;
    while (guard < 16) : (guard += 1) {
        const status = io.inb(status_port);
        if (status & 0x01 == 0) return; // output buffer empty
        if (status & 0x20 != 0) {
            _ = io.inb(data_port); // mouse byte, discard
            continue;
        }
        handleScancode(io.inb(data_port));
    }
}

/// Called from the IRQ1 handler.
pub fn onIrq() void {
    const status = io.inb(status_port);
    if (status & 0x01 == 0) return;
    handleScancode(io.inb(data_port));
}

fn handleScancode(code: u8) void {
    if (code == 0xE0) {
        extended = true;
        return;
    }
    if (extended) {
        extended = false;
        return; // arrows and friends: stage 3
    }

    const released = code & 0x80 != 0;
    const make = code & 0x7F;

    switch (make) {
        0x2A, 0x36 => {
            shift_down = !released;
            return;
        },
        0x3A => {
            if (!released) caps_lock = !caps_lock;
            return;
        },
        else => {},
    }
    if (released) return;

    const ch = translate(make);
    if (ch != 0) push(ch);
}

fn translate(make: u8) u8 {
    if (make >= plain.len) return 0;
    var c = if (shift_down) shifted[make] else plain[make];
    if (caps_lock and c >= 'a' and c <= 'z' and !shift_down) c -= 32;
    if (caps_lock and c >= 'A' and c <= 'Z' and shift_down) c += 32;
    return c;
}

// Scan code set 1, make codes 0x00..0x58. 0 means "no character".
const plain = [_]u8{
    0, 0, '1', '2', '3', '4', '5', '6', // 0x00
    '7', '8', '9', '0', '-', '=', 8, '\t', // 0x08
    'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', // 0x10
    'o', 'p', '[', ']', '\n', 0, 'a', 's', // 0x18
    'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', // 0x20
    '\'', '`', 0, '\\', 'z', 'x', 'c', 'v', // 0x28
    'b', 'n', 'm', ',', '.', '/', 0, '*', // 0x30
    0, ' ', 0, 0, 0, 0, 0, 0, // 0x38
    0, 0, 0, 0, 0, 0, 0, '7', // 0x40
    '8', '9', '-', '4', '5', '6', '+', '1', // 0x48
    '2', '3', '0', '.', 0, 0, 0, 0, // 0x50
};

const shifted = [_]u8{
    0, 0, '!', '@', '#', '$', '%', '^', // 0x00
    '&', '*', '(', ')', '_', '+', 8, '\t', // 0x08
    'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', // 0x10
    'O', 'P', '{', '}', '\n', 0, 'A', 'S', // 0x18
    'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', // 0x20
    '"', '~', 0, '|', 'Z', 'X', 'C', 'V', // 0x28
    'B', 'N', 'M', '<', '>', '?', 0, '*', // 0x30
    0, ' ', 0, 0, 0, 0, 0, 0, // 0x38
    0, 0, 0, 0, 0, 0, 0, '7', // 0x40
    '8', '9', '-', '4', '5', '6', '+', '1', // 0x48
    '2', '3', '0', '.', 0, 0, 0, 0, // 0x50
};

comptime {
    if (plain.len != shifted.len) @compileError("keymap tables must match in size");
}

/// Flush anything the firmware left in the controller buffer.
pub fn init() void {
    var guard: usize = 0;
    while (io.inb(status_port) & 0x01 != 0 and guard < 32) : (guard += 1) {
        _ = io.inb(data_port);
    }
    head = 0;
    tail = 0;
    shift_down = false;
    caps_lock = false;
    extended = false;
}
