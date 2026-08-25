//! Text console on the UEFI GOP framebuffer.
//!
//! The firmware console dies with ExitBootServices, so from that point on this
//! is the only thing on screen. It owns the pixels directly: no acceleration,
//! no double buffering, just glyph blitting and a memmove for scrolling.

const font = @import("font.zig");

pub const PixelOrder = enum { bgr, rgb };

pub const Info = struct {
    base: u64,
    width: u32,
    height: u32,
    /// Bytes between the starts of two scan lines.
    pitch: u32,
    order: PixelOrder,
};

const default_fg: u32 = 0xC8C8C8;
const default_bg: u32 = 0x0C0C10;

var fb_info: ?Info = null;
var pixels: [*]volatile u32 = undefined;
var scale: u32 = 1;
var cols: u32 = 0;
var rows: u32 = 0;
var cur_x: u32 = 0;
var cur_y: u32 = 0;
var fg: u32 = default_fg;
var bg: u32 = default_bg;
var cursor_drawn = false;

pub fn ready() bool {
    return fb_info != null;
}

/// The framebuffer the firmware handed over, if there is one. The kernel needs
/// it to map the pixels into its own page tables.
pub fn info() ?Info {
    return fb_info;
}

pub fn init(desc: Info) void {
    fb_info = desc;
    pixels = @ptrFromInt(desc.base);
    // On a large screen an 8x8 glyph is unreadable; double it.
    scale = if (desc.height >= 800) 2 else 1;
    cols = desc.width / (font.glyph_width * scale);
    rows = desc.height / (font.glyph_height * scale);
    cur_x = 0;
    cur_y = 0;
    clear();
}

pub fn size() struct { cols: u32, rows: u32 } {
    return .{ .cols = cols, .rows = rows };
}

/// The framebuffer in pixels, for anything that draws rather than prints.
pub fn dimensions() struct { width: u32, height: u32 } {
    const i = fb_info orelse return .{ .width = 0, .height = 0 };
    return .{ .width = i.width, .height = i.height };
}

/// Draw one glyph at pixel coordinates, scaled like the text console.
pub fn drawGlyphAt(c: u8, x: u32, y: u32, color: u32, glyph_scale: u32) void {
    const i = fb_info orelse return;
    const bits = font.glyph(c);
    const raw = encode(color);
    var row: u32 = 0;
    while (row < font.glyph_height) : (row += 1) {
        const line = bits[row];
        var col: u32 = 0;
        while (col < font.glyph_width) : (col += 1) {
            if ((line >> @intCast(7 - col)) & 1 == 0) continue;
            var sy: u32 = 0;
            while (sy < glyph_scale) : (sy += 1) {
                var sx: u32 = 0;
                while (sx < glyph_scale) : (sx += 1) {
                    const px = x + col * glyph_scale + sx;
                    const py = y + row * glyph_scale + sy;
                    if (px < i.width and py < i.height) pixels[pixelIndex(px, py)] = raw;
                }
            }
        }
    }
}

/// Draw a string at pixel coordinates, leaving the background alone.
pub fn drawTextAt(text: []const u8, x: u32, y: u32, color: u32, glyph_scale: u32) void {
    var pen = x;
    for (text) |c| {
        drawGlyphAt(c, pen, y, color, glyph_scale);
        pen += font.glyph_width * glyph_scale;
    }
}

/// Copy a rectangle out of the framebuffer, so whatever is drawn over it can
/// be undone. This is how a cursor moves without leaving a trail.
pub fn saveRect(x: u32, y: u32, w: u32, h: u32, out: []u32) void {
    const i = fb_info orelse return;
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        var col: u32 = 0;
        while (col < w) : (col += 1) {
            const idx = row * w + col;
            if (idx >= out.len) return;
            out[idx] = if (x + col < i.width and y + row < i.height)
                pixels[pixelIndex(x + col, y + row)]
            else
                0;
        }
    }
}

pub fn restoreRect(x: u32, y: u32, w: u32, h: u32, data: []const u32) void {
    const i = fb_info orelse return;
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        var col: u32 = 0;
        while (col < w) : (col += 1) {
            const idx = row * w + col;
            if (idx >= data.len) return;
            if (x + col < i.width and y + row < i.height) {
                pixels[pixelIndex(x + col, y + row)] = data[idx];
            }
        }
    }
}

/// Put the text console back on screen after something else has drawn over it.
pub fn resetConsole() void {
    cur_x = 0;
    cur_y = 0;
    cursor_drawn = false;
    clear();
}

fn encode(color: u32) u32 {
    const i = fb_info orelse return color;
    const r = (color >> 16) & 0xFF;
    const g = (color >> 8) & 0xFF;
    const b = color & 0xFF;
    return switch (i.order) {
        .bgr => (r << 16) | (g << 8) | b,
        .rgb => (b << 16) | (g << 8) | r,
    };
}

fn pixelIndex(x: u32, y: u32) usize {
    const i = fb_info.?;
    return (@as(usize, y) * i.pitch / 4) + x;
}

pub fn fillRect(x: u32, y: u32, w: u32, h: u32, color: u32) void {
    const i = fb_info orelse return;
    const raw = encode(color);
    var row: u32 = 0;
    while (row < h and y + row < i.height) : (row += 1) {
        const base = pixelIndex(x, y + row);
        var col: u32 = 0;
        while (col < w and x + col < i.width) : (col += 1) {
            pixels[base + col] = raw;
        }
    }
}

pub fn clear() void {
    const i = fb_info orelse return;
    fillRect(0, 0, i.width, i.height, bg);
    cur_x = 0;
    cur_y = 0;
    cursor_drawn = false;
}

pub fn setColor(new_fg: u32) void {
    fg = new_fg;
}

pub fn resetColor() void {
    fg = default_fg;
}

fn drawGlyph(c: u8, cell_x: u32, cell_y: u32, color: u32) void {
    if (fb_info == null) return;
    const bits = font.glyph(c);
    const px = cell_x * font.glyph_width * scale;
    const py = cell_y * font.glyph_height * scale;
    const raw_fg = encode(color);
    const raw_bg = encode(bg);

    var row: u32 = 0;
    while (row < font.glyph_height) : (row += 1) {
        const line = bits[row];
        var col: u32 = 0;
        while (col < font.glyph_width) : (col += 1) {
            const on = (line >> @intCast(7 - col)) & 1 != 0;
            const raw = if (on) raw_fg else raw_bg;
            var sy: u32 = 0;
            while (sy < scale) : (sy += 1) {
                var sx: u32 = 0;
                while (sx < scale) : (sx += 1) {
                    const x = px + col * scale + sx;
                    const y = py + row * scale + sy;
                    if (x < fb_info.?.width and y < fb_info.?.height) {
                        pixels[pixelIndex(x, y)] = raw;
                    }
                }
            }
        }
    }
}

fn scroll() void {
    const i = fb_info orelse return;
    const line_px = font.glyph_height * scale;
    const words_per_line = i.pitch / 4;
    const shift = @as(usize, line_px) * words_per_line;
    const total = @as(usize, i.height) * words_per_line;

    var dst: usize = 0;
    while (dst + shift < total) : (dst += 1) {
        pixels[dst] = pixels[dst + shift];
    }
    fillRect(0, i.height - line_px, i.width, line_px, bg);
}

fn newline() void {
    cur_x = 0;
    if (cur_y + 1 < rows) {
        cur_y += 1;
    } else {
        scroll();
    }
}

fn advance() void {
    cur_x += 1;
    if (cur_x >= cols) newline();
}

pub fn hideCursor() void {
    if (!cursor_drawn) return;
    fillRect(
        cur_x * font.glyph_width * scale,
        cur_y * font.glyph_height * scale,
        font.glyph_width * scale,
        font.glyph_height * scale,
        bg,
    );
    cursor_drawn = false;
}

pub fn showCursor() void {
    if (fb_info == null or cursor_drawn) return;
    const px = cur_x * font.glyph_width * scale;
    const py = (cur_y * font.glyph_height + font.glyph_height - 1) * scale;
    fillRect(px, py, font.glyph_width * scale, scale, fg);
    cursor_drawn = true;
}

pub fn backspace() void {
    hideCursor();
    if (cur_x > 0) {
        cur_x -= 1;
    } else if (cur_y > 0) {
        cur_y -= 1;
        cur_x = cols - 1;
    }
    drawGlyph(' ', cur_x, cur_y, fg);
}

pub fn write(bytes: []const u8) void {
    if (fb_info == null) return;
    hideCursor();
    for (bytes) |c| {
        switch (c) {
            '\n' => newline(),
            '\r' => cur_x = 0,
            8 => backspace(),
            '\t' => {
                var n: u32 = 4 - (cur_x % 4);
                while (n > 0) : (n -= 1) {
                    drawGlyph(' ', cur_x, cur_y, fg);
                    advance();
                }
            },
            else => {
                drawGlyph(c, cur_x, cur_y, fg);
                advance();
            },
        }
    }
}
