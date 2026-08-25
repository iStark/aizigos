//! Intel 82540EM (e1000) driver — the card QEMU gives a PC by default.
//!
//! Descriptor rings and packet buffers live in the kernel image's .bss, which
//! is identity-mapped, so their physical and virtual addresses are the same
//! and the card can be handed pointers to them directly. That is a shortcut a
//! real driver could not take, and it is the reason this one is short.

const pci = @import("pci.zig");
const serial = @import("serial.zig");

const vendor_intel: u16 = 0x8086;
const device_82540em: u16 = 0x100E;

// Registers, by byte offset from the memory-mapped base.
const reg_ctrl = 0x0000;
const reg_status = 0x0008;
const reg_ims = 0x00D0;
const reg_imc = 0x00D8;
const reg_rctl = 0x0100;
const reg_tctl = 0x0400;
const reg_rdbal = 0x2800;
const reg_rdbah = 0x2804;
const reg_rdlen = 0x2808;
const reg_rdh = 0x2810;
const reg_rdt = 0x2818;
const reg_tdbal = 0x3800;
const reg_tdbah = 0x3804;
const reg_tdlen = 0x3808;
const reg_tdh = 0x3810;
const reg_tdt = 0x3818;
const reg_mta = 0x5200;
const reg_ral = 0x5400;
const reg_rah = 0x5404;

const ctrl_slu = 1 << 6; // set link up
const ctrl_rst = 1 << 26;

const status_lu = 1 << 1; // link up

const rctl_en = 1 << 1;
const rctl_bam = 1 << 15; // accept broadcast
const rctl_secrc = 1 << 26; // strip the ethernet CRC
const rctl_bsize_2048 = 0; // with BSEX clear

const tctl_en = 1 << 1;
const tctl_psp = 1 << 3; // pad short packets

const tx_cmd_eop = 1 << 0;
const tx_cmd_ifcs = 1 << 1;
const tx_cmd_rs = 1 << 3;
const tx_status_dd = 1 << 0;
const rx_status_dd = 1 << 0;

pub const rx_slots = 16;
pub const tx_slots = 8;
pub const buffer_size = 2048;

const RxDescriptor = extern struct {
    address: u64 align(1),
    length: u16 align(1),
    checksum: u16 align(1),
    status: u8 align(1),
    errors: u8 align(1),
    special: u16 align(1),
};

const TxDescriptor = extern struct {
    address: u64 align(1),
    length: u16 align(1),
    checksum_offset: u8 align(1),
    command: u8 align(1),
    status: u8 align(1),
    checksum_start: u8 align(1),
    special: u16 align(1),
};

var rx_ring: [rx_slots]RxDescriptor align(16) = @splat(.{
    .address = 0,
    .length = 0,
    .checksum = 0,
    .status = 0,
    .errors = 0,
    .special = 0,
});
var tx_ring: [tx_slots]TxDescriptor align(16) = @splat(.{
    .address = 0,
    .length = 0,
    .checksum_offset = 0,
    .command = 0,
    .status = 0,
    .checksum_start = 0,
    .special = 0,
});

var rx_buffers: [rx_slots][buffer_size]u8 align(16) = @splat(@splat(0));
var tx_buffers: [tx_slots][buffer_size]u8 align(16) = @splat(@splat(0));

var base: u64 = 0;
var present = false;
var mac: [6]u8 = @splat(0);
var rx_next: usize = 0;
var tx_next: usize = 0;

fn write(offset: u32, value: u32) void {
    const cell: *volatile u32 = @ptrFromInt(base + offset);
    cell.* = value;
}

fn read(offset: u32) u32 {
    const cell: *const volatile u32 = @ptrFromInt(base + offset);
    return cell.*;
}

pub fn detected() bool {
    return present;
}

pub fn address() ?[6]u8 {
    return if (present) mac else null;
}

pub fn linkUp() bool {
    if (!present) return false;
    return read(reg_status) & status_lu != 0;
}

pub fn init() void {
    const device = pci.find(vendor_intel, device_82540em) orelse {
        serial.write("[net] no e1000 on the bus\n");
        return;
    };
    pci.enable(device);
    base = device.bar0;
    if (base == 0) return;

    // A reset leaves the card in a known state; the manual asks for a pause
    // afterwards, and reading a register back is the pause.
    write(reg_ctrl, read(reg_ctrl) | ctrl_rst);
    var spin: usize = 0;
    while (spin < 100_000) : (spin += 1) {
        if (read(reg_ctrl) & ctrl_rst == 0) break;
    }
    write(reg_imc, 0xFFFF_FFFF); // no interrupts: this driver polls
    write(reg_ctrl, read(reg_ctrl) | ctrl_slu);

    // The hardware address is already in the receive address registers on
    // QEMU, which saves reading the EEPROM.
    const low = read(reg_ral);
    const high = read(reg_rah);
    mac = .{
        @truncate(low),
        @truncate(low >> 8),
        @truncate(low >> 16),
        @truncate(low >> 24),
        @truncate(high),
        @truncate(high >> 8),
    };

    // Clear the multicast table filter.
    var i: u32 = 0;
    while (i < 128) : (i += 1) write(reg_mta + i * 4, 0);

    for (&rx_ring, 0..) |*descriptor, slot| {
        descriptor.* = .{
            .address = @intFromPtr(&rx_buffers[slot]),
            .length = 0,
            .checksum = 0,
            .status = 0,
            .errors = 0,
            .special = 0,
        };
    }
    write(reg_rdbal, @truncate(@intFromPtr(&rx_ring)));
    write(reg_rdbah, @truncate(@intFromPtr(&rx_ring) >> 32));
    write(reg_rdlen, rx_slots * @sizeOf(RxDescriptor));
    write(reg_rdh, 0);
    write(reg_rdt, rx_slots - 1);
    write(reg_rctl, rctl_en | rctl_bam | rctl_secrc | rctl_bsize_2048);

    for (&tx_ring) |*descriptor| {
        descriptor.* = .{
            .address = 0,
            .length = 0,
            .checksum_offset = 0,
            .command = 0,
            .status = tx_status_dd,
            .checksum_start = 0,
            .special = 0,
        };
    }
    write(reg_tdbal, @truncate(@intFromPtr(&tx_ring)));
    write(reg_tdbah, @truncate(@intFromPtr(&tx_ring) >> 32));
    write(reg_tdlen, tx_slots * @sizeOf(TxDescriptor));
    write(reg_tdh, 0);
    write(reg_tdt, 0);
    write(reg_tctl, tctl_en | tctl_psp | (0x10 << 4) | (0x40 << 12));

    rx_next = 0;
    tx_next = 0;
    present = true;
    serial.write("[net] e1000 ready\n");
}

/// Hand a frame to the card. Returns false when the ring is still busy, which
/// on this driver means the previous frame has not been sent yet.
pub fn send(frame: []const u8) bool {
    if (!present or frame.len == 0 or frame.len > buffer_size) return false;
    const descriptor = &tx_ring[tx_next];
    if (descriptor.status & tx_status_dd == 0) return false;

    @memcpy(tx_buffers[tx_next][0..frame.len], frame);
    descriptor.address = @intFromPtr(&tx_buffers[tx_next]);
    descriptor.length = @intCast(frame.len);
    descriptor.command = tx_cmd_eop | tx_cmd_ifcs | tx_cmd_rs;
    descriptor.status = 0;

    tx_next = (tx_next + 1) % tx_slots;
    write(reg_tdt, @intCast(tx_next));
    return true;
}

/// Take the next received frame, if the card has left one for us.
pub fn receive(out: []u8) ?usize {
    if (!present) return null;
    const descriptor = &rx_ring[rx_next];
    if (descriptor.status & rx_status_dd == 0) return null;

    const length = @min(@as(usize, descriptor.length), out.len);
    @memcpy(out[0..length], rx_buffers[rx_next][0..length]);

    descriptor.status = 0;
    const tail = rx_next;
    rx_next = (rx_next + 1) % rx_slots;
    write(reg_rdt, @intCast(tail));
    return length;
}
