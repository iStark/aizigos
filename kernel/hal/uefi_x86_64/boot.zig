//! UEFI bring-up: take the machine from the firmware and never hand it back.
//!
//! Order matters here. The framebuffer is claimed while boot services are
//! still alive (so a failure can still be reported through the firmware
//! console), the memory map is read into a static buffer, and only then does
//! ExitBootServices run. After that call the firmware is gone: no console, no
//! allocator, no timers but ours.

const std = @import("std");
const uefi = std.os.uefi;
const types = @import("../types.zig");
const fb = @import("fb.zig");

pub const max_regions = 128;

/// The UEFI map is a few kilobytes on real machines; 64 KiB is generous.
var map_buffer: [64 * 1024]u8 align(8) = undefined;

var regions: [max_regions]types.MemRegion = undefined;
var region_count: usize = 0;
var exited = false;

pub fn memoryMap() []const types.MemRegion {
    return regions[0..region_count];
}

pub fn bootServicesGone() bool {
    return exited;
}

/// Write through the firmware console. Only usable before ExitBootServices.
pub fn firmwareWrite(text: []const u8) void {
    if (exited) return;
    const con_out = uefi.system_table.con_out orelse return;
    var buf: [128:0]u16 = undefined;
    var n: usize = 0;
    for (text) |c| {
        if (n + 2 >= buf.len) break;
        if (c == '\n') {
            buf[n] = '\r';
            n += 1;
        }
        buf[n] = c;
        n += 1;
    }
    buf[n] = 0;
    _ = con_out.outputString(buf[0..n :0]) catch {};
}

fn claimFramebuffer() void {
    const bs = uefi.system_table.boot_services orelse return;
    const gop = (bs.locateProtocol(uefi.protocol.GraphicsOutput, null) catch return) orelse return;
    const mode = gop.mode;
    const info = mode.info;

    const order: fb.PixelOrder = switch (info.pixel_format) {
        .red_green_blue_reserved_8_bit_per_color => .rgb,
        .blue_green_red_reserved_8_bit_per_color => .bgr,
        // Bit-mask and blt-only modes are not worth supporting here: a machine
        // without a linear 32-bit framebuffer keeps the serial console instead.
        else => return,
    };

    fb.init(.{
        .base = mode.frame_buffer_base,
        .width = info.horizontal_resolution,
        .height = info.vertical_resolution,
        .pitch = info.pixels_per_scan_line * 4,
        .order = order,
    });
}

fn classify(kind: uefi.tables.MemoryType) types.MemKind {
    return switch (kind) {
        // Once the firmware is gone its own code and data are ours to use.
        .conventional_memory, .boot_services_code, .boot_services_data => .usable,
        .memory_mapped_io, .memory_mapped_io_port_space => .device,
        else => .reserved,
    };
}

fn addRegion(base: u64, len: u64, kind: types.MemKind) void {
    if (len == 0) return;
    // Merge with the previous region when they touch and agree.
    if (region_count > 0) {
        const last = &regions[region_count - 1];
        if (last.kind == kind and last.end() == base) {
            last.len += len;
            return;
        }
    }
    if (region_count == max_regions) return;
    regions[region_count] = .{ .base = base, .len = len, .kind = kind };
    region_count += 1;
}

fn buildRegions(map: uefi.tables.MemoryMapSlice) void {
    region_count = 0;
    var it = map.iterator();
    while (it.next()) |desc| {
        const len = desc.number_of_pages * 4096;
        var kind = classify(desc.type);
        // The first megabyte holds real-mode and firmware leftovers on PCs.
        if (desc.physical_start < 0x100000) kind = .reserved;
        addRegion(desc.physical_start, len, kind);
    }
}

/// Everything above runs while the firmware is still in charge.
/// On return the kernel owns the machine.
pub fn takeOverMachine() void {
    const bs = uefi.system_table.boot_services orelse {
        firmwareWrite("no boot services\n");
        return;
    };

    claimFramebuffer();

    const map = bs.getMemoryMap(&map_buffer) catch |e| {
        firmwareWrite("GetMemoryMap failed: ");
        firmwareWrite(@errorName(e));
        firmwareWrite("\n");
        return;
    };
    buildRegions(map);

    bs.exitBootServices(uefi.handle, map.info.key) catch |e| {
        firmwareWrite("ExitBootServices failed: ");
        firmwareWrite(@errorName(e));
        firmwareWrite("\n");
        return;
    };
    exited = true;
    uefi.system_table.con_in = null;
    uefi.system_table.con_out = null;
    uefi.system_table.std_err = null;
    uefi.system_table.boot_services = null;
}
