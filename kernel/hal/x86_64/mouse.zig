//! PS/2 mouse on the i8042 auxiliary port.
//!
//! Three-byte packets: flags, then movement deltas that are already two's
//! complement but arrive with their sign bit stored separately in the flags,
//! which is the kind of detail that makes a cursor drift diagonally when it is
//! read wrong.

const io = @import("serial.zig");
const types = @import("../types.zig");

const data_port: u16 = 0x60;
const status_port: u16 = 0x64;

pub const irq_line: u8 = 12;

const ring_size = 32;
var ring: [ring_size]types.PointerEvent = @splat(.{});
var head: usize = 0;
var tail: usize = 0;

var packet: [3]u8 = @splat(0);
var packet_index: usize = 0;
var present = false;

fn waitInput() void {
    var guard: usize = 0;
    while (guard < 100_000) : (guard += 1) {
        if (io.inb(status_port) & 0x02 == 0) return;
    }
}

fn waitOutput() bool {
    var guard: usize = 0;
    while (guard < 100_000) : (guard += 1) {
        if (io.inb(status_port) & 0x01 != 0) return true;
    }
    return false;
}

fn command(byte: u8) void {
    waitInput();
    io.outb(status_port, byte);
}

/// Commands addressed to the mouse rather than the controller have to be
/// prefixed with 0xD4, otherwise the keyboard gets them.
fn toMouse(byte: u8) ?u8 {
    command(0xD4);
    waitInput();
    io.outb(data_port, byte);
    if (!waitOutput()) return null;
    return io.inb(data_port);
}

pub fn init() void {
    // Enable the auxiliary device.
    command(0xA8);

    // Turn on the interrupt for it in the controller configuration byte.
    command(0x20);
    if (!waitOutput()) return;
    var config = io.inb(data_port);
    config |= 0x02; // aux interrupt
    config &= ~@as(u8, 0x20); // clock enabled
    command(0x60);
    waitInput();
    io.outb(data_port, config);

    // Defaults, then start reporting.
    _ = toMouse(0xF6) orelse return;
    const ack = toMouse(0xF4) orelse return;
    present = ack == 0xFA;
    packet_index = 0;
    head = 0;
    tail = 0;
}

pub fn detected() bool {
    return present;
}

fn push(event: types.PointerEvent) void {
    const next = (head + 1) % ring_size;
    if (next == tail) return;
    ring[head] = event;
    head = next;
}

fn feed(byte: u8) void {
    // The first byte of a packet always has bit 3 set; anything else means the
    // stream is out of sync and the byte has to be dropped.
    if (packet_index == 0 and byte & 0x08 == 0) return;
    packet[packet_index] = byte;
    packet_index += 1;
    if (packet_index < 3) return;
    packet_index = 0;

    const flags = packet[0];
    if (flags & 0xC0 != 0) return; // overflow: the deltas are meaningless

    var dx: i16 = packet[1];
    var dy: i16 = packet[2];
    if (flags & 0x10 != 0) dx -= 256;
    if (flags & 0x20 != 0) dy -= 256;

    push(.{
        .dx = dx,
        // Mice count up as the hand moves away; screens count down.
        .dy = -dy,
        .buttons = flags & 0x07,
    });
}

/// Drain whatever the controller has ready. Safe with interrupts off.
pub fn poll() void {
    var guard: usize = 0;
    while (guard < 16) : (guard += 1) {
        const status = io.inb(status_port);
        if (status & 0x01 == 0) return;
        // Bit 5 marks a byte that came from the auxiliary device.
        if (status & 0x20 == 0) return;
        feed(io.inb(data_port));
    }
}

pub fn onIrq() void {
    const status = io.inb(status_port);
    if (status & 0x01 == 0) return;
    if (status & 0x20 == 0) return;
    feed(io.inb(data_port));
}

pub fn read() ?types.PointerEvent {
    poll();
    if (tail == head) return null;
    const event = ring[tail];
    tail = (tail + 1) % ring_size;
    return event;
}
