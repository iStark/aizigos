//! A display driven by us rather than by the firmware.
//!
//! Everything on screen so far has gone through the framebuffer UEFI handed
//! over at boot. That works, and it has one hard limit: changing the mode is
//! the firmware's code, and the firmware's code is gone the moment the kernel
//! takes the machine. A resolution the user picked could only be applied at
//! the next start, which is a strange thing to explain to someone sitting in
//! front of a working desktop.
//!
//! virtio-gpu removes the firmware from the question. The device takes a
//! resource -- a rectangle of pixels in our own memory -- and shows it. Asking
//! for a different size means making a new resource and pointing the scanout
//! at it, which is a few messages and no reboot.
//!
//! This is the 2D part of the protocol only. No 3D, no cursor plane, no
//! multiple scanouts: a desktop needs one rectangle on one screen, and the
//! rest is weight for a stage that has not arrived.

const std = @import("std");
const pci = @import("pci.zig");
const pmm = @import("../../mm/pmm.zig");

const vendor_id: u16 = 0x1AF4;
/// Both the transitional device id and the modern one; QEMU's `virtio-vga`
/// presents the first, `virtio-gpu-pci` the second.
const device_ids = [_]u16{ 0x1010, 0x1050 };

// Virtio PCI capability types.
const cfg_common: u8 = 1;
const cfg_notify: u8 = 2;
const cfg_isr: u8 = 3;
const cfg_device: u8 = 4;

// Device status bits, set in this order; the device reads them as a handshake.
const status_acknowledge: u8 = 1;
const status_driver: u8 = 2;
const status_driver_ok: u8 = 4;
const status_features_ok: u8 = 8;
const status_failed: u8 = 128;

// The 2D commands, and the two answers this driver understands.
const cmd_get_display_info: u32 = 0x0100;
const cmd_resource_create_2d: u32 = 0x0101;
const cmd_resource_unref: u32 = 0x0102;
const cmd_set_scanout: u32 = 0x0103;
const cmd_resource_flush: u32 = 0x0104;
const cmd_transfer_to_host_2d: u32 = 0x0105;
const cmd_resource_attach_backing: u32 = 0x0106;
const resp_ok_nodata: u32 = 0x1100;
const resp_ok_display_info: u32 = 0x1101;

/// B8G8R8X8, which is the order the rest of the kernel already writes pixels
/// in, so nothing above has to know the device is different.
const format_bgrx: u32 = 2;

const queue_size = 16;
const control_queue = 0;

// ---- the layout the device reads ----------------------------------------

const Descriptor = extern struct {
    addr: u64 = 0,
    len: u32 = 0,
    flags: u16 = 0,
    next: u16 = 0,
};

const flag_next: u16 = 1;
const flag_write: u16 = 2;

const Available = extern struct {
    flags: u16 = 0,
    index: u16 = 0,
    ring: [queue_size]u16 = @splat(0),
    used_event: u16 = 0,
};

const UsedElement = extern struct {
    id: u32 = 0,
    len: u32 = 0,
};

const Used = extern struct {
    flags: u16 = 0,
    index: u16 = 0,
    ring: [queue_size]UsedElement = @splat(.{}),
    avail_event: u16 = 0,
};

const Header = extern struct {
    type: u32 = 0,
    flags: u32 = 0,
    fence_id: u64 = 0,
    ctx_id: u32 = 0,
    padding: u32 = 0,
};

const Rect = extern struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

const DisplayOne = extern struct {
    rect: Rect = .{},
    enabled: u32 = 0,
    flags: u32 = 0,
};

const DisplayInfo = extern struct {
    header: Header = .{},
    displays: [16]DisplayOne = @splat(.{}),
};

const CreateResource = extern struct {
    header: Header = .{},
    resource_id: u32 = 0,
    format: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

const AttachBacking = extern struct {
    header: Header = .{},
    resource_id: u32 = 0,
    entries: u32 = 0,
    addr: u64 = 0,
    length: u32 = 0,
    padding: u32 = 0,
};

const SetScanout = extern struct {
    header: Header = .{},
    rect: Rect = .{},
    scanout_id: u32 = 0,
    resource_id: u32 = 0,
};

const TransferToHost = extern struct {
    header: Header = .{},
    rect: Rect = .{},
    offset: u64 = 0,
    resource_id: u32 = 0,
    padding: u32 = 0,
};

const FlushResource = extern struct {
    header: Header = .{},
    rect: Rect = .{},
    resource_id: u32 = 0,
    padding: u32 = 0,
};

const Unref = extern struct {
    header: Header = .{},
    resource_id: u32 = 0,
    padding: u32 = 0,
};

// ---- state ---------------------------------------------------------------

/// The rings and the message buffers are static and page-aligned. The device
/// reads them by physical address, and this kernel identity-maps its own
/// memory, so a static array is a physical address we already know.
var descriptors: [queue_size]Descriptor align(4096) = @splat(.{});
var available: Available align(4096) = .{};
var used: Used align(4096) = .{};
var request: [512]u8 align(16) = @splat(0);
var response: [512]u8 align(16) = @splat(0);

var common_base: u64 = 0;
var notify_base: u64 = 0;
var notify_multiplier: u32 = 0;
var notify_offset: u16 = 0;
var found: ?pci.Device = null;
var ready_now = false;
var last_index: u16 = 0;

var frame_base: u64 = 0;
var frame_pages: usize = 0;
var frame_width: u32 = 0;
var frame_height: u32 = 0;
var next_resource: u32 = 1;
var live_resource: u32 = 0;

var frames: ?*pmm.Pmm = null;

/// What the device says it can show, gathered once at start-up.
pub var modes: [16]Mode = @splat(.{});
pub var mode_count: usize = 0;

pub const Mode = struct {
    width: u32 = 0,
    height: u32 = 0,
};

pub fn present() bool {
    return ready_now;
}

pub fn width() u32 {
    return frame_width;
}

pub fn height() u32 {
    return frame_height;
}

/// Where the pixels live. The compositor writes here and nowhere else.
pub fn framebuffer() u64 {
    return frame_base;
}

// ---- register access -----------------------------------------------------

fn common8(offset: usize) *volatile u8 {
    return @ptrFromInt(common_base + offset);
}

fn common16(offset: usize) *volatile u16 {
    return @ptrFromInt(common_base + offset);
}

fn common32(offset: usize) *volatile u32 {
    return @ptrFromInt(common_base + offset);
}

// Offsets into the common configuration structure, from the specification.
const off_device_feature_select: usize = 0;
const off_device_feature: usize = 4;
const off_driver_feature_select: usize = 8;
const off_driver_feature: usize = 12;
const off_num_queues: usize = 18;
const off_device_status: usize = 20;
const off_queue_select: usize = 22;
const off_queue_size: usize = 24;
const off_queue_enable: usize = 28;
const off_queue_notify_off: usize = 30;
const off_queue_desc: usize = 32;
const off_queue_driver: usize = 40;
const off_queue_device: usize = 48;

fn writeStatus(value: u8) void {
    common8(off_device_status).* = value;
}

fn write64(offset: usize, value: u64) void {
    common32(offset).* = @truncate(value & 0xFFFF_FFFF);
    common32(offset + 4).* = @truncate(value >> 32);
}

// ---- finding the device --------------------------------------------------

const CapFind = struct {
    address: pci.Address,
    common: u64 = 0,
    notify: u64 = 0,
    multiplier: u32 = 0,
};

fn onCapability(state: *CapFind, id: u8, offset: u8) bool {
    if (id != 0x09) return false; // not vendor-specific
    const kind = pci.read8(state.address, offset + 3);
    const bar_index = pci.read8(state.address, offset + 4);
    const within = pci.read32(state.address, offset + 8);
    const length = pci.read32(state.address, offset + 12);
    const bar_base = pci.bar(state.address, bar_index);
    const base = bar_base + within;

    // A virtio BAR can sit above 4 GiB, outside the device window the kernel
    // maps at start-up. Ask for it before writing to it.
    if (kind == cfg_common or kind == cfg_notify) {
        if (!mapRegisters(bar_base, within + length)) return false;
    }

    switch (kind) {
        cfg_common => state.common = base,
        cfg_notify => {
            state.notify = base;
            state.multiplier = pci.read32(state.address, offset + 16);
        },
        else => {},
    }
    // Keep walking: the two structures needed are rarely the first two found.
    return false;
}

fn mapRegisters(base: u64, len: u32) bool {
    const impl = @import("../uefi_x86_64/impl.zig");
    if (comptime !@hasDecl(impl, "mapDevice")) return true;
    // Whole pages, and never less than one: a structure a few dozen bytes long
    // still needs the page it sits in.
    const page: u64 = 4096;
    const start = base & ~(page - 1);
    const finish = (base + len + page - 1) & ~(page - 1);
    return impl.mapDevice(start, finish - start);
}

fn locate() ?pci.Device {
    for (device_ids) |id| {
        if (pci.find(vendor_id, id)) |device| return device;
    }
    return null;
}

// ---- the queue -----------------------------------------------------------

fn notifyDevice() void {
    const at: *volatile u16 = @ptrFromInt(
        notify_base + @as(u64, notify_offset) * notify_multiplier,
    );
    at.* = control_queue;
}

/// Send one command and wait for the answer. Everything this driver does is a
/// handful of messages at start-up or a mode change, so polling costs nothing
/// and saves an interrupt handler, a vector and a wakeup path.
fn submit(out_len: usize, in_len: usize) bool {
    descriptors[0] = .{
        .addr = @intFromPtr(&request),
        .len = @intCast(out_len),
        .flags = flag_next,
        .next = 1,
    };
    descriptors[1] = .{
        .addr = @intFromPtr(&response),
        .len = @intCast(in_len),
        .flags = flag_write,
        .next = 0,
    };

    const slot = available.index % queue_size;
    available.ring[slot] = 0;
    // The device may read the ring the instant the index moves, so the entry
    // has to be in place first. A release store says exactly that and stops
    // the compiler moving the writes above it.
    @atomicStore(u16, &available.index, available.index +% 1, .release);
    notifyDevice();

    var spins: usize = 0;
    while (spins < 100_000_000) : (spins += 1) {
        if (used.index != last_index) {
            last_index = used.index;
            return true;
        }
        std.atomic.spinLoopHint();
    }
    return false;
}

fn requestAs(comptime T: type) *T {
    const at: *T = @ptrCast(@alignCast(&request));
    at.* = T{};
    return at;
}

fn responseHeader() *const Header {
    return @ptrCast(@alignCast(&response));
}

fn simpleCommand(comptime T: type, filled: T) bool {
    const at: *T = @ptrCast(@alignCast(&request));
    at.* = filled;
    if (!submit(@sizeOf(T), @sizeOf(Header))) return false;
    return responseHeader().type == resp_ok_nodata;
}

// ---- start-up ------------------------------------------------------------

/// Find the device, hand it the rings, and ask what it can show. False means
/// there is no virtio display here, which is not an error: the framebuffer
/// from the firmware carries on as it did.
pub fn init(allocator: *pmm.Pmm) bool {
    ready_now = false;
    frames = allocator;

    const device = locate() orelse return false;
    found = device;
    pci.enable(device);

    var state = CapFind{ .address = device.address };
    pci.eachCapability(device.address, &state, onCapability);
    if (state.common == 0 or state.notify == 0) return false;

    common_base = state.common;
    notify_base = state.notify;
    notify_multiplier = state.multiplier;

    // The handshake the specification lays out, in the order it lays it out.
    writeStatus(0);
    writeStatus(status_acknowledge);
    writeStatus(status_acknowledge | status_driver);

    // No feature is needed. Saying so plainly beats negotiating something and
    // then not using it.
    common32(off_device_feature_select).* = 0;
    _ = common32(off_device_feature).*;
    common32(off_driver_feature_select).* = 0;
    common32(off_driver_feature).* = 0;
    common32(off_driver_feature_select).* = 1;
    // Bit 32 is VIRTIO_F_VERSION_1, and a modern device refuses to work
    // without it acknowledged.
    common32(off_driver_feature).* = 1;

    writeStatus(status_acknowledge | status_driver | status_features_ok);
    const back = common8(off_device_status).*;
    if (back & status_features_ok == 0) {
        writeStatus(status_failed);
        return false;
    }

    if (common16(off_num_queues).* == 0) return false;

    common16(off_queue_select).* = control_queue;
    const room = common16(off_queue_size).*;
    if (room == 0) return false;
    if (room < queue_size) {
        // The rings here are a fixed size; a device offering less would need
        // them rebuilt, and no device in practice does.
        writeStatus(status_failed);
        return false;
    }
    common16(off_queue_size).* = queue_size;
    notify_offset = common16(off_queue_notify_off).*;

    write64(off_queue_desc, @intFromPtr(&descriptors));
    write64(off_queue_driver, @intFromPtr(&available));
    write64(off_queue_device, @intFromPtr(&used));
    common16(off_queue_enable).* = 1;

    writeStatus(status_acknowledge | status_driver | status_features_ok | status_driver_ok);

    last_index = used.index;
    ready_now = true;

    if (!readDisplayInfo()) {
        ready_now = false;
        return false;
    }
    return true;
}

/// What the device is willing to show. The first display's rectangle is the
/// size the host window is at; the list of sizes the desktop offers is built
/// from that plus the usual ones that fit inside it.
fn readDisplayInfo() bool {
    const header = requestAs(Header);
    header.type = cmd_get_display_info;
    if (!submit(@sizeOf(Header), @sizeOf(DisplayInfo))) return false;

    const info: *const DisplayInfo = @ptrCast(@alignCast(&response));
    if (info.header.type != resp_ok_display_info) return false;

    const host = info.displays[0].rect;
    const largest_w = if (host.width == 0) 1024 else host.width;
    const largest_h = if (host.height == 0) 768 else host.height;

    // A window on the host is one size; a virtual display can be told to be
    // any size that fits in it. These are the ones worth offering.
    const candidates = [_]Mode{
        .{ .width = 800, .height = 600 },
        .{ .width = 1024, .height = 768 },
        .{ .width = 1280, .height = 720 },
        .{ .width = 1280, .height = 800 },
        .{ .width = 1440, .height = 900 },
        .{ .width = 1600, .height = 900 },
        .{ .width = 1920, .height = 1080 },
    };
    mode_count = 0;
    for (candidates) |mode| {
        if (mode.width > largest_w or mode.height > largest_h) continue;
        modes[mode_count] = mode;
        mode_count += 1;
    }
    if (mode_count == 0) {
        modes[0] = .{ .width = largest_w, .height = largest_h };
        mode_count = 1;
    }
    return true;
}

// ---- modes ---------------------------------------------------------------

/// Show a rectangle of this size, allocating the memory behind it. The old
/// resource is released only once the new one is on screen: a mode change that
/// fails should leave the machine showing what it showed before, not nothing.
pub fn setMode(w: u32, h: u32) bool {
    if (!ready_now) return false;
    const allocator = frames orelse return false;

    const bytes = @as(u64, w) * h * 4;
    const page = allocator.stats().page_size;
    const pages: usize = @intCast((bytes + page - 1) / page);

    const base = allocator.allocContiguous(pages) catch return false;
    const resource = next_resource;
    next_resource += 1;

    var settled = false;
    defer if (!settled) {
        allocator.freeContiguous(base, pages) catch {};
    };

    if (!simpleCommand(CreateResource, .{
        .header = .{ .type = cmd_resource_create_2d },
        .resource_id = resource,
        .format = format_bgrx,
        .width = w,
        .height = h,
    })) return false;

    if (!simpleCommand(AttachBacking, .{
        .header = .{ .type = cmd_resource_attach_backing },
        .resource_id = resource,
        .entries = 1,
        .addr = base,
        .length = @intCast(bytes),
    })) return false;

    if (!simpleCommand(SetScanout, .{
        .header = .{ .type = cmd_set_scanout },
        .rect = .{ .width = w, .height = h },
        .scanout_id = 0,
        .resource_id = resource,
    })) return false;

    // Now that the device is showing the new resource, the old one and its
    // memory can go.
    if (live_resource != 0) {
        _ = simpleCommand(Unref, .{
            .header = .{ .type = cmd_resource_unref },
            .resource_id = live_resource,
        });
        allocator.freeContiguous(frame_base, frame_pages) catch {};
    }

    live_resource = resource;
    frame_base = base;
    frame_pages = pages;
    frame_width = w;
    frame_height = h;
    settled = true;
    rememberMode(w, h);
    return true;
}

/// Keep the size in use on the list of sizes offered. The firmware may have
/// left the screen at something that is not one of the usual sizes, and a list
/// that cannot name what is on screen is a confusing list.
fn rememberMode(w: u32, h: u32) void {
    for (modes[0..mode_count]) |mode| {
        if (mode.width == w and mode.height == h) return;
    }
    if (mode_count == modes.len) return;
    modes[mode_count] = .{ .width = w, .height = h };
    mode_count += 1;
}

/// Push a rectangle of what we drew to the screen. Two messages, because the
/// device keeps its own copy of the pixels: one to take them, one to show
/// them.
pub fn flush(x: u32, y: u32, w: u32, h: u32) void {
    if (!ready_now or live_resource == 0) return;
    if (w == 0 or h == 0) return;

    const offset = (@as(u64, y) * frame_width + x) * 4;
    _ = simpleCommand(TransferToHost, .{
        .header = .{ .type = cmd_transfer_to_host_2d },
        .rect = .{ .x = x, .y = y, .width = w, .height = h },
        .offset = offset,
        .resource_id = live_resource,
    });
    _ = simpleCommand(FlushResource, .{
        .header = .{ .type = cmd_resource_flush },
        .rect = .{ .x = x, .y = y, .width = w, .height = h },
        .resource_id = live_resource,
    });
}
