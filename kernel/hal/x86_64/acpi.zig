//! Just enough ACPI to turn the machine off and to restart it.
//!
//! These are the two things every other system's power menu does and this one
//! could not, and they are not optional politeness: a machine that can only be
//! stopped by killing the emulator or holding the button is a machine that has
//! not finished booting up, so to speak.
//!
//! ACPI is a large specification with an interpreted bytecode at the centre of
//! it, and none of that is needed here. The firmware's tables say where the
//! power management registers are; the one value that lives in bytecode is the
//! sleep type for state five, and it sits in a fixed, tiny shape that can be
//! found by searching for its name. That trick is old, well understood, and
//! honest about what it is: it works because `_S5_` in a DSDT is always a name
//! followed by a small package of small integers.
//!
//! What this deliberately does not do: evaluate AML, walk the namespace, or
//! prepare the platform the way a full implementation would. If a machine
//! needs any of that to shut down, this says it cannot rather than writing
//! something hopeful to a register.

const std = @import("std");
const io = @import("serial.zig");

const Header = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,
};

var pm1a_control: u16 = 0;
var pm1b_control: u16 = 0;
var slp_typ_a: u16 = 0;
var slp_typ_b: u16 = 0;
var can_sleep = false;

var reset_port: u16 = 0;
var reset_value: u8 = 0;
var reset_is_io = false;

/// Whether the tables were found and understood well enough to act on.
pub fn ready() bool {
    return can_sleep;
}

/// Read the tables, starting from the pointer the firmware handed us. Safe to
/// call on a machine whose tables are missing or in a shape this does not
/// understand: it leaves `ready()` false.
pub fn init(rsdp: u64) void {
    can_sleep = false;
    if (rsdp == 0) return;

    const bytes: [*]const u8 = @ptrFromInt(rsdp);
    if (!std.mem.eql(u8, bytes[0..8], "RSD PTR ")) return;

    const revision = bytes[15];
    var fadt: ?*const Header = null;

    if (revision >= 2) {
        const xsdt_address = std.mem.readInt(u64, bytes[24..32], .little);
        fadt = findTable(xsdt_address, 8);
    }
    if (fadt == null) {
        const rsdt_address: u64 = std.mem.readInt(u32, bytes[16..20], .little);
        fadt = findTable(rsdt_address, 4);
    }
    const facp = fadt orelse return;
    readFadt(facp);
}

/// Walk the root table's array of pointers looking for the fixed description
/// table. Entries are four bytes in an RSDT and eight in an XSDT, which is the
/// only difference between them that matters here.
fn findTable(root: u64, entry_size: usize) ?*const Header {
    if (root == 0) return null;
    const header: *const Header = @ptrFromInt(root);
    if (header.length < @sizeOf(Header)) return null;

    const count = (header.length - @sizeOf(Header)) / entry_size;
    const array: [*]const u8 = @ptrFromInt(root + @sizeOf(Header));
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const at = array[index * entry_size ..];
        const address: u64 = if (entry_size == 8)
            std.mem.readInt(u64, at[0..8], .little)
        else
            std.mem.readInt(u32, at[0..4], .little);
        if (address == 0) continue;
        const table: *const Header = @ptrFromInt(address);
        if (std.mem.eql(u8, &table.signature, "FACP")) return table;
    }
    return null;
}

fn readFadt(facp: *const Header) void {
    const raw: [*]const u8 = @ptrCast(facp);
    const length = facp.length;

    // Offsets into the fixed table, from the specification.
    if (length >= 68) {
        pm1a_control = @truncate(std.mem.readInt(u32, raw[64..68], .little));
    }
    if (length >= 72) {
        pm1b_control = @truncate(std.mem.readInt(u32, raw[68..72], .little));
    }

    // The reset register, present from ACPI 2.0. Address space 1 is port I/O,
    // which is the only one this can drive; memory-mapped resets need the page
    // mapped and are left to the fallback.
    if (length >= 129) {
        const space = raw[116];
        const address = std.mem.readInt(u64, raw[120..128], .little);
        reset_value = raw[128];
        if (space == 1 and address != 0 and address <= 0xFFFF) {
            reset_port = @truncate(address);
            reset_is_io = true;
        }
    }

    var dsdt: u64 = 0;
    if (length >= 44) dsdt = std.mem.readInt(u32, raw[40..44], .little);
    if (length >= 148) {
        const extended = std.mem.readInt(u64, raw[140..148], .little);
        if (extended != 0) dsdt = extended;
    }
    if (dsdt != 0) readSleepType(dsdt);

    can_sleep = pm1a_control != 0;
}

/// Find `_S5_` in the DSDT and take the two sleep values out of the package
/// that follows it.
///
/// The shape is fixed: the name, an opcode saying "package", a length byte, a
/// count, and then the values as byte-sized integers. Anything that does not
/// match is left alone -- a wrong sleep type written to the power management
/// register is not a shutdown, it is undefined behaviour on real hardware.
fn readSleepType(dsdt: u64) void {
    const header: *const Header = @ptrFromInt(dsdt);
    if (!std.mem.eql(u8, &header.signature, "DSDT")) return;
    if (header.length <= @sizeOf(Header)) return;

    const body: [*]const u8 = @ptrFromInt(dsdt);
    const length = header.length;

    var at: usize = @sizeOf(Header);
    while (at + 8 < length) : (at += 1) {
        if (!std.mem.eql(u8, body[at .. at + 4], "_S5_")) continue;

        // Skip the package opcode (0x12) and its length, which is one byte
        // here because the package is tiny.
        var cursor = at + 4;
        if (body[cursor] != 0x12) continue;
        cursor += 2; // opcode, then the length byte
        if (cursor >= length) return;
        const count = body[cursor];
        if (count < 1) return;
        cursor += 1;

        slp_typ_a = readSmallInteger(body, &cursor, length) orelse return;
        if (count >= 2) {
            slp_typ_b = readSmallInteger(body, &cursor, length) orelse 0;
        }
        return;
    }
}

/// One integer out of an AML package: either a one-byte constant or the
/// opcode for a byte-sized one.
fn readSmallInteger(body: [*]const u8, cursor: *usize, length: u32) ?u16 {
    if (cursor.* >= length) return null;
    const first = body[cursor.*];
    switch (first) {
        0x00 => {
            cursor.* += 1;
            return 0;
        },
        0x01 => {
            cursor.* += 1;
            return 1;
        },
        0x0A => {
            if (cursor.* + 1 >= length) return null;
            const value = body[cursor.* + 1];
            cursor.* += 2;
            return value;
        },
        else => return null,
    }
}

const slp_enable: u16 = 1 << 13;

/// Turn the machine off. Returns only if it did not work.
pub fn powerOff() void {
    if (!can_sleep) return;
    io.outw(pm1a_control, (slp_typ_a << 10) | slp_enable);
    if (pm1b_control != 0) {
        io.outw(pm1b_control, (slp_typ_b << 10) | slp_enable);
    }
}

/// Restart the machine. Returns only if none of the ways worked, which is why
/// there is more than one: the ACPI reset register is optional, and the port
/// on the chipset has been there since before it existed.
pub fn restart() void {
    if (reset_is_io) {
        io.outb(reset_port, reset_value);
        spin();
    }

    // The chipset reset control port: full reset, then the pulse.
    io.outb(0xCF9, 0x02);
    io.outb(0xCF9, 0x06);
    spin();

    // The keyboard controller's reset line, which is how this was done before
    // there was a chipset port to do it with.
    var guard: usize = 0;
    while (guard < 100_000 and io.inb(0x64) & 0x02 != 0) : (guard += 1) {}
    io.outb(0x64, 0xFE);
    spin();
}

fn spin() void {
    var waited: usize = 0;
    while (waited < 10_000_000) : (waited += 1) std.atomic.spinLoopHint();
}
