//! Just enough PCI to find a device and switch it on.
//!
//! Configuration space through the 0xCF8/0xCFC port pair: write an address,
//! read or write a dword. No enumeration of capabilities, no bridges, no
//! bus renumbering — the kernel needs one network card, not a device tree.

const io = @import("serial.zig");

const address_port: u16 = 0xCF8;
const data_port: u16 = 0xCFC;

pub const Address = struct {
    bus: u8,
    device: u5,
    function: u3,

    fn encode(self: Address, offset: u8) u32 {
        return 0x8000_0000 |
            (@as(u32, self.bus) << 16) |
            (@as(u32, self.device) << 11) |
            (@as(u32, self.function) << 8) |
            (@as(u32, offset) & 0xFC);
    }
};

fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[v], %[p]"
        :
        : [v] "{eax}" (value),
          [p] "N{dx}" (port),
    );
}

fn inl(port: u16) u32 {
    return asm volatile ("inl %[p], %[r]"
        : [r] "={eax}" (-> u32),
        : [p] "N{dx}" (port),
    );
}

pub fn read32(address: Address, offset: u8) u32 {
    outl(address_port, address.encode(offset));
    return inl(data_port);
}

pub fn write32(address: Address, offset: u8, value: u32) void {
    outl(address_port, address.encode(offset));
    outl(data_port, value);
}

pub fn read8(address: Address, offset: u8) u8 {
    const dword = read32(address, offset & 0xFC);
    const shift: u5 = @intCast((offset & 3) * 8);
    return @truncate(dword >> shift);
}

pub fn read16(address: Address, offset: u8) u16 {
    const dword = read32(address, offset & 0xFC);
    const shift: u5 = @intCast((offset & 2) * 8);
    return @truncate(dword >> shift);
}

pub const Device = struct {
    address: Address,
    vendor: u16,
    device: u16,
    /// The first base address register, with its flag bits cleared.
    bar0: u64,
    irq: u8,
};

/// Walk the first bus looking for one vendor and device. QEMU puts everything
/// on bus 0, and a kernel that needs more than that needs a real PCI layer.
pub fn find(vendor: u16, device_id: u16) ?Device {
    var bus: u16 = 0;
    while (bus < 4) : (bus += 1) {
        var slot: u8 = 0;
        while (slot < 32) : (slot += 1) {
            const address = Address{ .bus = @intCast(bus), .device = @intCast(slot), .function = 0 };
            const ids = read32(address, 0x00);
            const found_vendor: u16 = @truncate(ids);
            if (found_vendor == 0xFFFF) continue;
            const found_device: u16 = @truncate(ids >> 16);
            if (found_vendor != vendor or found_device != device_id) continue;

            const bar_low = read32(address, 0x10);
            var first: u64 = bar_low & 0xFFFF_FFF0;
            // A 64-bit memory BAR keeps its upper half in the next register.
            if (bar_low & 0x6 == 0x4) {
                first |= @as(u64, read32(address, 0x14)) << 32;
            }
            return .{
                .address = address,
                .vendor = found_vendor,
                .device = found_device,
                .bar0 = first,
                .irq = @truncate(read32(address, 0x3C)),
            };
        }
    }
    return null;
}

/// Let the device answer memory reads and drive the bus itself, which it must
/// do to move packets without the CPU copying every byte.
pub fn enable(device: Device) void {
    const command = read32(device.address, 0x04);
    write32(device.address, 0x04, command | 0x0006);
}

/// A base address register by index, with its flag bits cleared. A 64-bit
/// register takes two slots and the caller's index counts slots, which is what
/// a device's own documentation counts.
pub fn bar(address: Address, index: u8) u64 {
    const offset: u8 = 0x10 + index * 4;
    const low = read32(address, offset);
    if (low & 1 != 0) return low & 0xFFFF_FFFC; // an I/O port range
    var value: u64 = low & 0xFFFF_FFF0;
    if (low & 0x6 == 0x4) value |= @as(u64, read32(address, offset + 4)) << 32;
    return value;
}

/// Walk the capability list, handing each vendor-specific entry to `visit`
/// until it says it has seen enough.
///
/// The list is a chain of offsets inside configuration space, and a device
/// with a broken one would loop forever, so the walk is bounded: there is no
/// room in 256 bytes for more capabilities than this.
pub fn eachCapability(address: Address, context: anytype, visit: fn (@TypeOf(context), u8, u8) bool) void {
    const status = read16(address, 0x06);
    if (status & 0x10 == 0) return; // no capability list

    var offset = read8(address, 0x34) & 0xFC;
    var steps: usize = 0;
    while (offset >= 0x40 and steps < 48) : (steps += 1) {
        const id = read8(address, offset);
        const next = read8(address, offset + 1) & 0xFC;
        if (visit(context, id, offset)) return;
        if (next == 0 or next == offset) return;
        offset = next;
    }
}

comptime {
    _ = io;
}
