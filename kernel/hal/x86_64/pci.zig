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
            var bar: u64 = bar_low & 0xFFFF_FFF0;
            // A 64-bit memory BAR keeps its upper half in the next register.
            if (bar_low & 0x6 == 0x4) {
                bar |= @as(u64, read32(address, 0x14)) << 32;
            }
            return .{
                .address = address,
                .vendor = found_vendor,
                .device = found_device,
                .bar0 = bar,
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

comptime {
    _ = io;
}
