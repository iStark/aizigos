//! UEFI bring-up: take the machine from the firmware and never hand it back.
//!
//! Order matters here. The framebuffer is claimed while boot services are
//! still alive (so a failure can still be reported through the firmware
//! console), the memory map is read into a static buffer, and only then does
//! ExitBootServices run. After that call the firmware is gone: no console, no
//! allocator, no timers but ours.

const std = @import("std");
pub const settings = @import("settings.zig");
pub const config = @import("../../config.zig");
const fat32 = @import("../../fs/fat32.zig");
const ata = @import("../x86_64/ata.zig");
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

/// The screen sizes this machine offers, gathered while the firmware is still
/// alive. After the handover they can only be reported, not changed: the code
/// that would change them lives in memory this kernel takes for its own.
pub const Screen = struct {
    width: u32 = 0,
    height: u32 = 0,
    mode: u16 = 0,
};

pub var screens: [16]Screen = @splat(.{});

/// What the settings file said at boot. The desktop reads it from here rather
/// than going back to the disk, so both agree about what was in force.
pub var stored: config.Values = .defaults;

/// The ACPI root pointer, taken from the firmware's configuration tables.
/// Zero on a machine that published none.
pub var acpi_rsdp: u64 = 0;

/// ACPI 2.0 and later; the older 1.0 table is accepted as a fallback because a
/// machine that publishes only that one still knows how to turn itself off.
const acpi_20_guid = uefi.Guid{
    .time_low = 0x8868E871,
    .time_mid = 0xE4F1,
    .time_high_and_version = 0x11D3,
    .clock_seq_high_and_reserved = 0xBC,
    .clock_seq_low = 0x22,
    .node = .{ 0x00, 0x80, 0xC7, 0x3C, 0x88, 0x81 },
};

const acpi_10_guid = uefi.Guid{
    .time_low = 0xEB9D2D30,
    .time_mid = 0x2D88,
    .time_high_and_version = 0x11D3,
    .clock_seq_high_and_reserved = 0x9A,
    .clock_seq_low = 0x16,
    .node = .{ 0x00, 0x90, 0x27, 0x3F, 0xC1, 0x4D },
};

fn findAcpi() void {
    const table = uefi.system_table;
    const count = table.number_of_table_entries;
    const entries = table.configuration_table;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const entry = entries[index];
        if (entry.vendor_guid.eql(acpi_20_guid)) {
            acpi_rsdp = @intFromPtr(entry.vendor_table);
            return;
        }
        if (entry.vendor_guid.eql(acpi_10_guid) and acpi_rsdp == 0) {
            acpi_rsdp = @intFromPtr(entry.vendor_table);
        }
    }
}
pub var screen_count: usize = 0;
pub var screen_current: u16 = 0xFFFF;

fn gatherModes(gop: *uefi.protocol.GraphicsOutput) void {
    screen_count = 0;
    var index: u32 = 0;
    while (index < gop.mode.max_mode and screen_count < screens.len) : (index += 1) {
        const info = gop.queryMode(index) catch continue;
        switch (info.pixel_format) {
            .red_green_blue_reserved_8_bit_per_color,
            .blue_green_red_reserved_8_bit_per_color,
            => {},
            else => continue,
        }
        // A desktop needs room; below this the windows do not fit and the
        // choice is not worth offering.
        if (info.horizontal_resolution < 800 or info.vertical_resolution < 600) continue;
        screens[screen_count] = .{
            .width = info.horizontal_resolution,
            .height = info.vertical_resolution,
            .mode = @intCast(index),
        };
        screen_count += 1;
    }
}

/// The settings file, read straight off the disk. This runs before the kernel
/// has mounted anything, because the screen size has to be applied while the
/// firmware that can apply it is still alive, and ATA is port I/O that works
/// just as well now as later.
fn storedSettings() config.Values {
    ata.init();
    if (!ata.present()) return .defaults;
    var volume = fat32.Volume.mount(.{ .read = readSectors }) catch return .defaults;
    return config.loadFrom(&volume);
}

fn readSectors(context: ?*anyopaque, lba: u64, buffer: []u8) bool {
    _ = context;
    return ata.read(lba, buffer);
}

/// The mode whose size matches, or none. Sizes are matched rather than mode
/// numbers because that is what the settings file holds and what a person
/// reading it means.
fn modeFor(width: u32, height: u32) ?u16 {
    var index: usize = 0;
    while (index < screen_count) : (index += 1) {
        if (screens[index].width == width and screens[index].height == height) {
            return screens[index].mode;
        }
    }
    return null;
}

fn claimFramebuffer() void {
    const bs = uefi.system_table.boot_services orelse return;
    const gop = (bs.locateProtocol(uefi.protocol.GraphicsOutput, null) catch return) orelse return;
    gatherModes(gop);

    // A screen size chosen on a previous run, applied while there is still
    // firmware to apply it with. The file on disk is the setting; the UEFI
    // variable is what a machine with no writable disk falls back on.
    stored = storedSettings();
    var wanted: u16 = 0xFFFF;
    if (stored.screen_width != 0) {
        wanted = modeFor(stored.screen_width, stored.screen_height) orelse 0xFFFF;
    } else {
        wanted = settings.load().screen_mode;
    }
    if (wanted != 0xFFFF and wanted != gop.mode.mode) {
        gop.setMode(wanted) catch {};
    }
    screen_current = @intCast(gop.mode.mode);

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
    // The tables themselves live in memory the firmware marks as ACPI data,
    // which stays reserved after the handover; only the pointer to them has to
    // be taken while the configuration table is still readable.
    findAcpi();

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
