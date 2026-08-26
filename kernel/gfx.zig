//! The compositor: three layers, one buffer, and a list of what changed.
//!
//! Everything used to draw straight into the framebuffer the firmware handed
//! us, in whatever order the code happened to run. That works for one window
//! and stops working the moment there are two: a panel slides over a program
//! and the program's pixels are gone, because nobody kept them. The fixes for
//! that were a growing pile of flags — repaint this, ask that to repaint
//! itself, remember where the chrome was — and each new element multiplied the
//! cases. This replaces the pile.
//!
//! Three layers, bottom to top:
//!
//!   1. the desktop — background, windows, panels. The shell paints here.
//!   2. a program's surface — the kernel keeps the last thing it blitted, so
//!      the screen can be rebuilt without asking the program for anything.
//!   3. the pointer — drawn at the end, over whatever is underneath.
//!
//! Nothing reaches the screen except through `present`, which walks the
//! damaged rectangles, composites those parts of the three layers, and copies
//! them out. Off-screen work costs one buffer and buys the whole class of
//! ordering bugs back.

const std = @import("std");
const hal = @import("hal/hal.zig");
const pmm = @import("mm/pmm.zig");
const klog = @import("klog.zig");

const has_framebuffer = @hasDecl(hal.impl, "fb");
const fb = if (has_framebuffer) hal.impl.fb else struct {};
const font = if (has_framebuffer) @import("hal/uefi_x86_64/font.zig") else struct {};

pub const Rect = struct {
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,

    pub fn right(self: Rect) u32 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) u32 {
        return self.y + self.h;
    }

    pub fn empty(self: Rect) bool {
        return self.w == 0 or self.h == 0;
    }

    pub fn intersects(self: Rect, other: Rect) bool {
        return self.x < other.right() and other.x < self.right() and
            self.y < other.bottom() and other.y < self.bottom();
    }

    /// The smallest rectangle covering both. Used when the damage list is
    /// full: too coarse is slow, and losing a rectangle is a stale screen.
    pub fn cover(self: Rect, other: Rect) Rect {
        if (self.empty()) return other;
        if (other.empty()) return self;
        const x = @min(self.x, other.x);
        const y = @min(self.y, other.y);
        return .{
            .x = x,
            .y = y,
            .w = @max(self.right(), other.right()) - x,
            .h = @max(self.bottom(), other.bottom()) - y,
        };
    }

    pub fn clipTo(self: Rect, bounds: Rect) Rect {
        const x = @max(self.x, bounds.x);
        const y = @max(self.y, bounds.y);
        const r = @min(self.right(), bounds.right());
        const b = @min(self.bottom(), bounds.bottom());
        if (r <= x or b <= y) return .{};
        return .{ .x = x, .y = y, .w = r - x, .h = b - y };
    }
};

// --- the layers ------------------------------------------------------------

var width: u32 = 0;
var height: u32 = 0;
var ready_now = false;

/// The desktop, painted by the shell. Screen sized.
var desktop: []u32 = &.{};

/// A program's window, kept here so the screen can be rebuilt without it.
pub const max_surface_w: u32 = 1024;
pub const max_surface_h: u32 = 768;
var surface_pixels: []u32 = &.{};
var surface_rect: Rect = .{};
var surface_live = false;

/// The pointer, as a shape rather than a saved patch of screen.
var cursor_rect: Rect = .{};
var cursor_visible = false;

/// The overlay: the panels the shell slides in from the edges. Its own layer,
/// above a program's window, and painted once rather than on every frame of an
/// animation — sliding only changes how much of it is shown, which costs
/// nothing but a different number in a rectangle.
var overlay: []u32 = &.{};
var overlay_rects: [2]Rect = @splat(.{});

/// Which parts of the overlay are currently on screen.
pub fn setOverlay(left: Rect, right: Rect) void {
    if (!ready_now) return;
    const same = overlay_rects[0].x == left.x and overlay_rects[0].w == left.w and
        overlay_rects[1].x == right.x and overlay_rects[1].w == right.w;
    if (same) return;
    for (overlay_rects) |old| {
        if (!old.empty()) dirty(old);
    }
    overlay_rects[0] = left.clipTo(size());
    overlay_rects[1] = right.clipTo(size());
    for (overlay_rects) |new| {
        if (!new.empty()) dirty(new);
    }
}

fn overlaid(x: u32, y: u32) bool {
    for (overlay_rects) |rect| {
        if (rect.empty()) continue;
        if (x >= rect.x and x < rect.right() and y >= rect.y and y < rect.bottom()) return true;
    }
    return false;
}

/// Where the drawing calls below land. The shell paints the desktop, then
/// switches to the overlay to paint the panels, and back again.
pub const Target = enum { desktop, overlay };
var target: Target = .desktop;

pub fn paintTo(where: Target) void {
    target = where;
}

fn canvas() []u32 {
    return switch (target) {
        .desktop => desktop,
        .overlay => overlay,
    };
}

// --- damage ----------------------------------------------------------------

const max_damage = 24;
var damage: [max_damage]Rect = @splat(.{});
var damage_count: usize = 0;

/// Note that part of the screen no longer matches what is on it.
pub fn dirty(rect: Rect) void {
    if (!ready_now) return;
    const clipped = rect.clipTo(.{ .x = 0, .y = 0, .w = width, .h = height });
    if (clipped.empty()) return;

    // Already covered by something on the list: nothing to add.
    for (damage[0..damage_count]) |existing| {
        if (clipped.x >= existing.x and clipped.y >= existing.y and
            clipped.right() <= existing.right() and clipped.bottom() <= existing.bottom())
        {
            return;
        }
    }

    if (damage_count == max_damage) {
        // Full: fold the newcomer into the first entry rather than dropping
        // it. A screen that is repainted too generously is merely slow.
        damage[0] = damage[0].cover(clipped);
        return;
    }
    damage[damage_count] = clipped;
    damage_count += 1;
}

pub fn dirtyAll() void {
    damage_count = 0;
    dirty(.{ .x = 0, .y = 0, .w = width, .h = height });
}

// --- setting up ------------------------------------------------------------

pub fn ready() bool {
    return ready_now;
}

pub fn size() Rect {
    return .{ .x = 0, .y = 0, .w = width, .h = height };
}

/// Take the framebuffer's dimensions and allocate what the layers need. The
/// buffers come from the frame allocator rather than from static memory: a
/// screen-sized array in .bss would be several megabytes of kernel image, and
/// the size budget exists to be kept.
pub fn init(frames: *pmm.Pmm) bool {
    if (comptime !has_framebuffer) return false;
    if (!fb.ready()) return false;

    const dims = fb.dimensions();
    if (dims.width == 0 or dims.height == 0) return false;
    width = dims.width;
    height = dims.height;

    desktop = allocPixels(frames, width * height) orelse {
        klog.warn("compositor: no memory for a {d}x{d} desktop", .{ width, height });
        return false;
    };
    surface_pixels = allocPixels(frames, max_surface_w * max_surface_h) orelse {
        klog.warn("compositor: no memory for a program window", .{});
        return false;
    };
    overlay = allocPixels(frames, width * height) orelse {
        klog.warn("compositor: no memory for the panels", .{});
        return false;
    };
    @memset(desktop, 0);
    @memset(surface_pixels, 0);
    @memset(overlay, 0);

    ready_now = true;
    dirtyAll();
    klog.info("compositor: {d}x{d}, three layers", .{ width, height });
    return true;
}

fn allocPixels(frames: *pmm.Pmm, count: usize) ?[]u32 {
    const bytes = count * @sizeOf(u32);
    const pages = (bytes + hal.page_size - 1) / hal.page_size;
    const base = frames.allocContiguous(pages) catch return null;
    const raw: [*]u32 = @ptrFromInt(base);
    return raw[0..count];
}

// --- painting the desktop layer -------------------------------------------

pub fn fillRect(x: u32, y: u32, w: u32, h: u32, colour: u32) void {
    if (!ready_now) return;
    const rect = (Rect{ .x = x, .y = y, .w = w, .h = h }).clipTo(size());
    if (rect.empty()) return;

    const into = canvas();
    var row = rect.y;
    while (row < rect.bottom()) : (row += 1) {
        const base = row * width;
        var column = rect.x;
        while (column < rect.right()) : (column += 1) into[base + column] = colour;
    }
    dirty(rect);
}

pub fn drawGlyphAt(code: u21, x: u32, y: u32, colour: u32, glyph_scale: u32) void {
    if (comptime !has_framebuffer) return;
    if (!ready_now) return;
    const bits = font.glyph(code);
    var row: u32 = 0;
    while (row < font.glyph_height) : (row += 1) {
        const line = bits[row];
        var column: u32 = 0;
        while (column < font.glyph_width) : (column += 1) {
            if ((line >> @intCast(7 - column)) & 1 == 0) continue;
            var sy: u32 = 0;
            while (sy < glyph_scale) : (sy += 1) {
                var sx: u32 = 0;
                while (sx < glyph_scale) : (sx += 1) {
                    const px = x + column * glyph_scale + sx;
                    const py = y + row * glyph_scale + sy;
                    if (px < width and py < height) canvas()[py * width + px] = colour;
                }
            }
        }
    }
    dirty(.{
        .x = x,
        .y = y,
        .w = font.glyph_width * glyph_scale,
        .h = font.glyph_height * glyph_scale,
    });
}

pub fn drawTextAt(text: []const u8, x: u32, y: u32, colour: u32, glyph_scale: u32) void {
    if (comptime !has_framebuffer) return;
    var pen = x;
    var index: usize = 0;
    while (index < text.len) {
        const decoded = font.decode(text[index..]);
        if (decoded.len == 0) break;
        index += decoded.len;
        drawGlyphAt(decoded.code, pen, y, colour, glyph_scale);
        pen += font.glyph_width * glyph_scale;
    }
}

// --- the program's window --------------------------------------------------

/// Where a program's window is, and whether it is on the screen at all.
pub fn setSurface(rect: Rect, live: bool) void {
    if (!ready_now) return;
    if (!surface_rect.empty()) dirty(surface_rect);
    surface_rect = rect.clipTo(size());
    surface_live = live and !surface_rect.empty();
    if (!surface_rect.empty()) dirty(surface_rect);
}

pub fn surfaceLive() bool {
    return surface_live;
}

/// Take a program's pixels. They are kept: when a panel slides over this
/// window and away again, the shell rebuilds the screen from what is here and
/// the program is never involved.
pub fn surfaceBlit(x: u32, y: u32, w: u32, h: u32, row_pixels: []const u32, row_index: u32) void {
    if (!ready_now or surface_rect.empty()) return;
    if (x >= max_surface_w or y + row_index >= max_surface_h) return;
    _ = h;

    const target_row = y + row_index;
    const count = @min(w, max_surface_w - x);
    const base = target_row * max_surface_w + x;
    var column: u32 = 0;
    while (column < count and column < row_pixels.len) : (column += 1) {
        surface_pixels[base + column] = row_pixels[column];
    }

    dirty(.{
        .x = surface_rect.x + x,
        .y = surface_rect.y + target_row,
        .w = count,
        .h = 1,
    });
}

// --- the pointer -----------------------------------------------------------

const cursor_w: u32 = 10;
const cursor_h: u32 = 16;

pub fn moveCursor(x: u32, y: u32) void {
    if (!ready_now) return;
    if (cursor_visible) dirty(cursor_rect);
    cursor_rect = .{ .x = x, .y = y, .w = cursor_w, .h = cursor_h };
    cursor_visible = true;
    dirty(cursor_rect);
}

pub fn hideCursor() void {
    if (!cursor_visible) return;
    cursor_visible = false;
    dirty(cursor_rect);
}

/// A plain arrow: a filled triangle with a darker edge, so it stays visible
/// over a pale page and a dark desktop alike.
fn cursorPixel(column: u32, row: u32) ?u32 {
    if (row >= cursor_h) return null;
    const span = @min(cursor_w, 13 - @min(row, 12));
    if (column >= span) return null;
    if (column + 1 == span or row + 1 == cursor_h) return 0x0A0A0A;
    return 0xFFFFFF;
}

// --- putting it on the screen ---------------------------------------------

/// Composite the damaged parts and copy them out. One line of the screen at a
/// time, because a line is contiguous in every layer and the framebuffer wants
/// whole runs.
pub fn present() void {
    if (comptime !has_framebuffer) return;
    if (!ready_now or damage_count == 0) return;

    var line: [max_surface_w * 2]u32 = undefined;

    for (damage[0..damage_count]) |rect| {
        var row = rect.y;
        while (row < rect.bottom()) : (row += 1) {
            const span = @min(rect.w, line.len);
            const source = desktop[row * width + rect.x ..][0..span];
            @memcpy(line[0..span], source);

            if (surface_live and row >= surface_rect.y and row < surface_rect.bottom()) {
                const within = row - surface_rect.y;
                var column: u32 = 0;
                while (column < span) : (column += 1) {
                    const screen_x = rect.x + column;
                    if (screen_x < surface_rect.x or screen_x >= surface_rect.right()) continue;
                    if (overlaid(screen_x, row)) continue;
                    const sx = screen_x - surface_rect.x;
                    if (sx >= max_surface_w or within >= max_surface_h) continue;
                    line[column] = surface_pixels[within * max_surface_w + sx];
                }
            }

            // The panels, above both.
            {
                var column: u32 = 0;
                while (column < span) : (column += 1) {
                    const screen_x = rect.x + column;
                    if (!overlaid(screen_x, row)) continue;
                    line[column] = overlay[row * width + screen_x];
                }
            }

            if (cursor_visible and row >= cursor_rect.y and row < cursor_rect.bottom()) {
                const within = row - cursor_rect.y;
                var column: u32 = 0;
                while (column < span) : (column += 1) {
                    const screen_x = rect.x + column;
                    if (screen_x < cursor_rect.x or screen_x >= cursor_rect.right()) continue;
                    if (cursorPixel(screen_x - cursor_rect.x, within)) |colour| {
                        line[column] = colour;
                    }
                }
            }

            fb.blitArgb(rect.x, row, span, 1, line[0..span], span);
        }
    }
    damage_count = 0;
}
