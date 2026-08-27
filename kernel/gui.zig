//! The graphical surface: a desktop, windows, a pointer and a status bar.
//!
//! This is not the browser runtime of section 4.5 and does not pretend to be.
//! It is a window system built on what the kernel already owns — a linear
//! framebuffer, a PS/2 mouse and a keyboard — so the machine can be used by
//! pointing at it. Everything on screen is live kernel state: the task list is
//! the scheduler's, the memory figure is the frame allocator's, and the
//! terminal window is the same shell that answers on the serial line.

const hal = @import("hal/hal.zig");
const klog = @import("klog.zig");
const cap = @import("cap/cap.zig");
const power = @import("sched/power.zig");
const shell = @import("shell.zig");

const has_framebuffer = @hasDecl(hal.impl, "fb");
const has_mouse = @hasDecl(hal.impl, "mouse");
const has_keyboard = @hasDecl(hal.impl, "kbd");
const fb = if (has_framebuffer) hal.impl.fb else struct {};
const gfx = @import("gfx.zig");
const i18n = @import("i18n.zig");
const font = if (has_framebuffer) @import("hal/uefi_x86_64/font.zig") else struct {};

// --- theme -----------------------------------------------------------------

// One accent, neutral surfaces, and borders that separate without drawing
// attention to themselves. The old palette put saturated blue everywhere,
// which made every element shout at the same volume; a surface should be
// quiet so the one thing that matters can be loud.
const desktop_top: u32 = 0x0A0E17;
const desktop_bottom: u32 = 0x151C2B;
const bar_fill: u32 = 0x0D1119;
const bar_text: u32 = 0x8A93A6;
const accent: u32 = 0x7AA2F7;

const window_fill: u32 = 0x151A24;
const window_edge: u32 = 0x242C3C;
const window_edge_focused: u32 = 0x3D5480;
const title_fill: u32 = 0x1A2130;
const title_fill_focused: u32 = 0x1F2839;
const shadow_colour: u32 = 0x05070C;

const text_colour: u32 = 0xE3E8F2;
const dim_colour: u32 = 0x7C8699;
const good_colour: u32 = 0x7EE787;
const warn_colour: u32 = 0xE3B341;

const button_fill: u32 = 0x212936;
const button_hot: u32 = 0x2C3648;
const button_edge: u32 = 0x303A4C;

/// How round things are. One number, so nothing drifts out of step with the
/// rest: a panel and the buttons in it should look like they were cut by the
/// same tool.
const radius_button: u32 = 8;
/// The panels sit on the surface, a shade above the desktop behind them.
const panel_fill: u32 = 0x121722;
const radius_window: u32 = 10;

const cursor_colour: u32 = 0xFFFFFF;
const cursor_edge: u32 = 0x0A0A0A;

const glyph_w = 8;
const glyph_h = 8;
const scale = 2;
const cell_w = glyph_w * scale;
const cell_h = glyph_h * scale + 2;

const bar_height = 30;

pub const Rect = struct {
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,

    pub fn contains(self: Rect, px: u32, py: u32) bool {
        return px >= self.x and px < self.x + self.w and
            py >= self.y and py < self.y + self.h;
    }
};

// --- terminal buffer -------------------------------------------------------

/// Bytes, not characters: a Russian line is twice as long in UTF-8, and the
/// drawing code is what decides how much of it fits on screen.
const term_cols = 168;
const term_rows = 30;

var term_text: [term_rows][term_cols]u8 = @splat(@splat(' '));
var term_len: [term_rows]usize = @splat(0);
var term_line: usize = 0;
var term_dirty = true;

fn termNewline() void {
    if (term_line + 1 < term_rows) {
        term_line += 1;
        term_len[term_line] = 0;
        return;
    }
    var i: usize = 1;
    while (i < term_rows) : (i += 1) {
        term_text[i - 1] = term_text[i];
        term_len[i - 1] = term_len[i];
    }
    term_len[term_line] = 0;
}

/// Where shell and kernel output goes while the desktop owns the screen.
/// Empty the terminal window. The scrollback is the only copy of what was
/// printed, so this is only ever called when something has decided that what
/// was printed no longer applies.
pub fn termClear() void {
    for (&term_len) |*len| len.* = 0;
    term_line = 0;
    term_dirty = true;
}

pub fn termWrite(bytes: []const u8) void {
    for (bytes) |c| {
        switch (c) {
            '\n' => termNewline(),
            '\r' => term_len[term_line] = 0,
            8 => {
                if (term_len[term_line] > 0) term_len[term_line] -= 1;
            },
            else => {
                // Anything printable, including the second and third bytes of
                // a UTF-8 sequence, which have to stay next to the first.
                if (c < 32) continue;
                if (term_len[term_line] == term_cols) termNewline();
                term_text[term_line][term_len[term_line]] = c;
                term_len[term_line] += 1;
            },
        }
    }
    term_dirty = true;
}

// --- windows ---------------------------------------------------------------

pub const Kind = enum { terminal, control, tasks };

const Window = struct {
    rect: Rect,
    title: []const u8,
    kind: Kind,
};

pub const Action = enum {
    power_cycle,
    grant,
    revoke_all,
    run_user,
    shut_down,
    restart_machine,
    language,
    layout_switch,
    screen_next,

    fn label(self: Action) []const u8 {
        return switch (self) {
            .power_cycle => i18n.t(.cycle_power),
            .grant => i18n.t(.grant_agent),
            .revoke_all => i18n.t(.revoke_agent),
            .run_user => i18n.t(.run_program),
            .shut_down => i18n.t(.shut_down),
            .restart_machine => i18n.t(.restart_machine),
            .language => i18n.t(.interface_language),
            .layout_switch => i18n.t(.keyboard_layout),
            .screen_next => i18n.t(.screen_size),
        };
    }

    /// What the setting currently is, drawn on the right of its row so a
    /// button both says what it does and shows where things stand.
    fn value(self: Action) []const u8 {
        return switch (self) {
            .language => i18n.language().label(),
            .layout_switch => if (has_keyboard) hal.impl.kbd.currentSwitch().label() else "-",
            .screen_next => screenLabel(),
            else => "",
        };
    }
};

var screen_text: [16]u8 = @splat(0);
var screen_len: usize = 0;

/// The size chosen for the next start, as text. Not the size on the screen
/// now: changing that needs the firmware, and the firmware is gone.
fn screenLabel() []const u8 {
    if (screen_len == 0) return "-";
    return screen_text[0..screen_len];
}

fn setScreenLabel(w: u32, h: u32) void {
    var line = klog.Line{};
    line.decimal(w);
    line.str("x");
    line.decimal(h);
    const text = line.text();
    const take = @min(text.len, screen_text.len);
    @memcpy(screen_text[0..take], text[0..take]);
    screen_len = take;
}

const Button = struct {
    rect: Rect,
    action: Action,
};

var windows: [3]Window = undefined;
var window_count: usize = 0;
var focused: usize = 0;

/// Every button on the panel at once: four actions, two power, three
/// settings, and room for the next one. It used to be eight, which was exactly
/// enough until it was not -- adding shut down and restart silently pushed the
/// screen row off the end, and a full array that drops what does not fit shows
/// nothing rather than complaining.
var buttons: [16]Button = undefined;
var button_count: usize = 0;
var hot_button: ?usize = null;

/// A panel that slides in from an edge.
///
/// The desktop used to be three windows sitting side by side, which is what a
/// framebuffer and no ideas gets you. Two of them were never dragged and never
/// resized — they were a control strip and a task list — so they belong on an
/// edge, out of the way until they are wanted. The launcher is the same idea
/// on the other side: what is running, and what can be started.
const Panel = struct {
    width: u32,
    shown: u32 = 0,
    open: bool = false,

    /// Move one step towards where it should be. Returns true if it moved,
    /// which is the desktop's cue that the screen needs repainting.
    fn step(self: *Panel) bool {
        const speed: u32 = 36;
        const target: u32 = if (self.open) self.width else 0;
        if (self.shown == target) return false;
        if (self.shown < target) {
            self.shown = @min(target, self.shown + speed);
        } else {
            self.shown = self.shown -| speed;
        }
        return true;
    }

    fn visible(self: Panel) bool {
        return self.shown > 0;
    }
};

var launcher = Panel{ .width = 240 };
var tools = Panel{ .width = 380 };

/// Panels take a share of the screen rather than a fixed number of pixels: 380
/// is comfortable on a wide display and half the machine on a narrow one.
fn sizePanels() void {
    tools.width = @min(380, width / 2);
    launcher.width = @min(240, width / 3);
}

/// What the launcher lists: programs on the volume, and what is running.
const max_listed = 8;
var startable: [max_listed][13]u8 = @splat(@splat(0));
var startable_len: [max_listed]u8 = @splat(0);
var startable_count: usize = 0;

// --- state -----------------------------------------------------------------

const cursor_w = 10;
const cursor_h = 16;

var active_now = false;
var cursor_x: u32 = 0;
var cursor_y: u32 = 0;
var buttons_down: u8 = 0;
var dragging: ?usize = null;
var drag_dx: i64 = 0;
var drag_dy: i64 = 0;

var width: u32 = 0;
var height: u32 = 0;
var last_status_ns: u64 = 0;
var tasks_dirty = true;

pub fn available() bool {
    if (!has_framebuffer) return false;
    return fb.ready();
}

pub fn active() bool {
    return active_now;
}

// --- painting --------------------------------------------------------------

fn mix(from: u32, to: u32, numerator: u32, denominator: u32) u32 {
    const r = blend((from >> 16) & 0xFF, (to >> 16) & 0xFF, numerator, denominator);
    const g = blend((from >> 8) & 0xFF, (to >> 8) & 0xFF, numerator, denominator);
    const b = blend(from & 0xFF, to & 0xFF, numerator, denominator);
    return (r << 16) | (g << 8) | b;
}

fn blend(a: u32, b: u32, numerator: u32, denominator: u32) u32 {
    if (denominator == 0) return a;
    if (b >= a) return a + (b - a) * numerator / denominator;
    return a - (a - b) * numerator / denominator;
}

/// Paint the desktop gradient inside a rectangle, so a window that moves can
/// be lifted off the background without repainting the whole screen.
fn paintDesktop(area: Rect) void {
    var row: u32 = 0;
    while (row < area.h) : (row += 1) {
        const y = area.y + row;
        if (y >= height) break;
        const colour = mix(desktop_top, desktop_bottom, y, height);
        gfx.fillRect(area.x, y, area.w, 1, colour);
    }
}

fn drawFrame(rect: Rect, colour: u32) void {
    gfx.fillRect(rect.x, rect.y, rect.w, 1, colour);
    gfx.fillRect(rect.x, rect.y + rect.h - 1, rect.w, 1, colour);
    gfx.fillRect(rect.x, rect.y, 1, rect.h, colour);
    gfx.fillRect(rect.x + rect.w - 1, rect.y, 1, rect.h, colour);
}

fn drawText(text: []const u8, x: u32, y: u32, colour: u32) void {
    gfx.drawTextAt(text, x, y, colour, scale);
}

fn drawNumber(prefix: []const u8, value: u64, suffix: []const u8, x: u32, y: u32, colour: u32) void {
    var line = klog.Line{};
    line.str(prefix);
    line.decimal(value);
    line.str(suffix);
    drawText(line.text(), x, y, colour);
}

/// The tab is on the status bar, which is above the panel layer and belongs to
/// the desktop. Painting it into the panel layer put it where that layer is
/// never shown, so it changed appearance only when the status bar next
/// refreshed.
fn drawToolsTab() void {
    const was = gfx.currentTarget();
    gfx.paintTo(.desktop);
    defer gfx.paintTo(was);

    const tab = toolsTab();
    gfx.fillRounded(tab.x, tab.y + 4, tab.w, tab.h - 8, radius_button, if (tools.open) accent else title_fill_focused);
    drawText(i18n.t(.control), tab.x + 10, 7, if (tools.open) 0x0E1626 else text_colour);
}

fn drawStatusBar() void {
    const root = @import("root");
    gfx.fillRect(0, 0, width, bar_height, bar_fill);
    gfx.fillRect(0, bar_height - 1, width, 1, window_edge);
    drawText("AIZigOS", 12, 7, accent);

    const stats = root.scheduler.stats();
    const memory = root.frames.stats();
    var line = klog.Line{};
    line.str(stats.profile.label());
    line.str("   ");
    line.str(i18n.t(.memory_short));
    line.str(" ");
    line.decimal(memory.free_frames * memory.page_size / 1024 / 1024);
    line.str(" MiB   ");
    line.str(i18n.t(.tasks_short));
    line.str(" ");
    line.decimal(stats.runnable);
    line.str("   ");
    line.str(i18n.t(.uptime_short));
    line.str(" ");
    line.decimal(hal.nowNs() / 1_000_000_000);
    line.str("s");

    const text = line.text();
    // Cyrillic is two bytes a letter in UTF-8 and one cell on the screen, so
    // the width is not the byte count.
    var glyphs: usize = 0;
    for (text) |byte| {
        if (byte & 0xC0 != 0x80) glyphs += 1;
    }
    const text_width: u32 = @intCast(glyphs * cell_w);
    const indicator_w: u32 = 3 * cell_w + 16;
    const reserved = indicator_w + toolsTab().w + 36;
    // Never behind the name on the left: a narrow screen should drop the end
    // of the figures, not print them over the title.
    const after_title = 12 + glyphWidth("AIZigOS") + 16;
    const wanted = if (width > text_width + reserved) width - text_width - reserved else 0;
    const x = @max(after_title, wanted);
    const room = (width -| reserved) -| x;
    drawText(clipToFields(text, room), x, 7, bar_text);
    drawToolsTab();

    // The layout indicator sits at the right edge, where a taskbar would put
    // it, and is the only part of the bar with a background of its own.
    if (has_keyboard) {
        const label = hal.impl.kbd.currentLayout().label();
        const box_x = width - indicator_w + 4;
        gfx.fillRect(box_x, 4, indicator_w - 12, bar_height - 9, title_fill_focused);
        drawText(label, box_x + 8, 7, accent);
    }
}

fn contentRect(w: Window) Rect {
    return .{
        .x = w.rect.x + 1,
        .y = w.rect.y + 28,
        .w = w.rect.w - 2,
        .h = w.rect.h - 29,
    };
}

fn windowTitle(w: Window) []const u8 {
    return switch (w.kind) {
        .terminal => i18n.t(.shell),
        .control => i18n.t(.control),
        .tasks => i18n.t(.tasks),
    };
}

fn drawWindowChrome(index: usize) void {
    const w = windows[index];
    const is_focused = index == focused;

    // A shadow that falls off rather than stopping: three bands, each fainter
    // than the last. A hard-edged shadow is a second border, and reads as one.
    var band: u32 = 0;
    while (band < 3) : (band += 1) {
        const spread = 3 - band;
        gfx.fillRounded(
            w.rect.x -| spread + 2,
            w.rect.y -| spread + 4,
            w.rect.w + spread * 2,
            w.rect.h + spread * 2,
            radius_window + spread,
            shadow_colour,
        );
    }

    gfx.fillRounded(w.rect.x, w.rect.y, w.rect.w, w.rect.h, radius_window, window_fill);
    // The title bar shares the window's top corners and is square at the
    // bottom, which is what makes it read as part of the window rather than a
    // strip laid on top of it.
    gfx.fillRounded(w.rect.x, w.rect.y, w.rect.w, 27, radius_window, if (is_focused) title_fill_focused else title_fill);
    gfx.fillRect(w.rect.x, w.rect.y + 27 - radius_window, w.rect.w, radius_window, if (is_focused) title_fill_focused else title_fill);
    gfx.strokeRounded(w.rect.x, w.rect.y, w.rect.w, w.rect.h, radius_window, if (is_focused) window_edge_focused else window_edge);
    drawText(windowTitle(w), w.rect.x + 14, w.rect.y + 6, if (is_focused) text_colour else dim_colour);
}

/// How many bytes of a UTF-8 line fit in a number of character cells. Cutting
/// at a byte count would slice a Russian letter in half.
fn bytesForColumns(line: []const u8, columns: u32) usize {
    // A board with no framebuffer has no font to ask, and nothing here to
    // draw either; counting bytes keeps the code honest on both.
    if (comptime !has_framebuffer) return @min(line.len, columns);
    var used: u32 = 0;
    var index: usize = 0;
    while (index < line.len and used < columns) {
        const decoded = font.decode(line[index..]);
        if (decoded.len == 0) break;
        index += decoded.len;
        used += 1;
    }
    return index;
}

fn drawTerminal(index: usize) void {
    const area = contentRect(windows[index]);
    gfx.fillRect(area.x, area.y, area.w, area.h, 0x0C131E);

    const rows = @min(term_rows, area.h / cell_h);
    // A window is narrower than the buffer is wide; anything past its right
    // edge has to be cut here or it paints over the next window.
    const cols = (area.w - 16) / cell_w;
    const first = if (term_line + 1 > rows) term_line + 1 - rows else 0;
    var row: usize = 0;
    while (row < rows and first + row <= term_line) : (row += 1) {
        const source = first + row;
        const y: u32 = area.y + 4 + @as(u32, @intCast(row)) * cell_h;
        const line = term_text[source][0..term_len[source]];
        drawText(line[0..bytesForColumns(line, cols)], area.x + 8, y, text_colour);
    }
    term_dirty = false;
}

/// Every button belongs to a panel, so every button is painted into the panel
/// layer. This used to inherit whatever layer the caller happened to be
/// painting to, which was right when the panels were being painted and wrong
/// on every hover: the pointer moving over a button stamped all of them into
/// the desktop layer, under the panel where nobody could see them, and they
/// stayed there when the panel slid away.
fn drawButton(index: usize) void {
    const was = gfx.currentTarget();
    gfx.paintTo(.overlay);
    defer gfx.paintTo(was);

    const b = buttons[index];
    const fill = if (hot_button != null and hot_button.? == index) button_hot else button_fill;
    gfx.fillRounded(b.rect.x, b.rect.y, b.rect.w, b.rect.h, radius_button, fill);
    gfx.strokeRounded(b.rect.x, b.rect.y, b.rect.w, b.rect.h, radius_button, button_edge);

    const label = b.action.label();
    const value = b.action.value();
    const y = b.rect.y + (b.rect.h - glyph_h * scale) / 2;
    if (value.len == 0) {
        // An action: centred, because it is a thing to press rather than a
        // thing to read.
        drawText(label, b.rect.x + (b.rect.w -| glyphWidth(label)) / 2, y, text_colour);
        return;
    }
    // A setting: what it is on the left, what it says on the right.
    drawText(label, b.rect.x + 10, y, dim_colour);
    drawText(value, b.rect.x + b.rect.w -| (glyphWidth(value) + 10), y, text_colour);
}

fn drawControl(area: Rect) void {
    button_count = 0;
    const actions = [_]Action{ .power_cycle, .grant, .revoke_all, .run_user, .shut_down, .restart_machine };
    for (actions, 0..) |action, i| {
        buttons[button_count] = .{
            .action = action,
            .rect = .{
                .x = area.x + 16,
                .y = area.y + 14 + @as(u32, @intCast(i)) * 46,
                .w = area.w - 32,
                .h = 36,
            },
        };
        button_count += 1;
    }
    var i: usize = 0;
    while (i < button_count) : (i += 1) drawButton(i);
}

/// The window is 420 pixels wide and a glyph is 16, so a row is 25 columns.
/// Anything wider has to be cut here rather than painted over the frame.
const task_name_cols = 11;
const task_class_cols = 5;

fn clip(text: []const u8, columns: usize) []const u8 {
    return text[0..@min(text.len, columns)];
}

/// The settings rows. Pressing one moves it to its next value: two languages,
/// three ways to switch the keyboard, and whatever screen sizes the firmware
/// offered before it left.
fn drawSettings(area: Rect) void {
    const actions = [_]Action{ .language, .layout_switch, .screen_next };
    for (actions, 0..) |action, i| {
        if (button_count == buttons.len) break;
        buttons[button_count] = .{
            .action = action,
            .rect = .{
                .x = area.x + 16,
                .y = area.y + @as(u32, @intCast(i)) * 40,
                .w = area.w - 32,
                .h = 32,
            },
        };
        drawButton(button_count);
        button_count += 1;
    }
    if (screen_pending) {
        drawText(i18n.t(.apply_needs_restart), area.x + 16, area.y + 3 * 40 + 4, warn_colour);
    }
}

var screen_pending = false;

fn drawTasks(area: Rect) void {
    const root = @import("root");
    var y = area.y + 10;
    drawText(i18n.t(.thread_column), area.x + 12, y, dim_colour);
    drawText(i18n.t(.class_column), area.x + 12 + 12 * cell_w, y, dim_colour);
    drawText(i18n.t(.cpu_column), area.x + area.w -| (glyphWidth(i18n.t(.cpu_column)) + 12), y, dim_colour);
    y += cell_h + 4;

    for (&root.scheduler.tasks) |*t| {
        if (!t.used) continue;
        if (y + cell_h > area.y + area.h) break;
        const colour = switch (t.state) {
            .running => good_colour,
            .ready => text_colour,
            else => dim_colour,
        };
        drawText(clip(t.nameText(), task_name_cols), area.x + 12, y, colour);
        drawText(clip(@tagName(t.class), 4), area.x + 12 + 12 * cell_w, y, dim_colour);
        // The last column is right-aligned against the panel's edge. Placing
        // it at a fixed column ran the milliseconds off the side as soon as
        // the numbers grew.
        // Seconds with one decimal rather than milliseconds: shorter, and
        // nobody reading a task list cares about the third digit.
        var cpu = klog.Line{};
        const tenths = t.cpu_ns / 100_000_000;
        cpu.decimal(tenths / 10);
        cpu.str(".");
        cpu.decimal(tenths % 10);
        cpu.str("s");
        const text = cpu.text();
        drawText(text, area.x + area.w -| (glyphWidth(text) + 12), y, dim_colour);
        y += cell_h;
    }

    y += 6;
    drawNumber(i18n.t(.switches), root.scheduler.stats().switches, "", area.x + 12, y, dim_colour);
    y += cell_h;
    drawNumber(i18n.t(.background_rounds), root.indexer_rounds / 1000, "k", area.x + 12, y, dim_colour);
    tasks_dirty = false;
}

fn drawWindow(index: usize) void {
    drawWindowChrome(index);
    switch (windows[index].kind) {
        .terminal => drawTerminal(index),
        else => {},
    }
}

// --- the two panels --------------------------------------------------------

/// What is on the volume that can be started. Read once when the desktop opens
/// and again whenever the launcher is pulled out, because a program can be
/// written to the disk between one and the other.
fn readStartable() void {
    const root = @import("root");
    startable_count = 0;
    var entries: [16]root.fat32.Entry = undefined;
    const count = root.fsList("/", &entries) catch return;
    for (entries[0..count]) |entry| {
        if (entry.is_dir or startable_count == max_listed) continue;
        const name = entry.text();
        if (name.len < 4) continue;
        const tail = name[name.len - 4 ..];
        if (!(tail[0] == '.' and (tail[1] | 0x20) == 'e' and
            (tail[2] | 0x20) == 'l' and (tail[3] | 0x20) == 'f')) continue;
        const take = @min(name.len, 13);
        @memcpy(startable[startable_count][0..take], name[0..take]);
        startable_len[startable_count] = @intCast(take);
        startable_count += 1;
    }
}

const row_height: u32 = 26;

fn launcherRect() Rect {
    return .{ .x = 0, .y = bar_height, .w = launcher.shown, .h = height - bar_height };
}

fn toolsRect() Rect {
    return .{
        .x = width - tools.shown,
        .y = bar_height,
        .w = tools.shown,
        .h = height - bar_height,
    };
}

/// The row a point falls on within a list drawn from `top`, or null.
fn rowAt(top: u32, count: usize, py: u32) ?usize {
    if (py < top) return null;
    const index = (py - top) / row_height;
    if (index >= count) return null;
    return index;
}

fn runningTop() u32 {
    return bar_height + 44;
}

fn startableTop() u32 {
    const root = @import("root");
    return runningTop() + @as(u32, @intCast(root.processes.count())) * row_height + 46;
}

fn drawLauncher() void {
    const root = @import("root");
    // Painted at its full width into the overlay: sliding shows more or less
    // of what is already there rather than drawing it again.
    const area = Rect{ .x = 0, .y = bar_height, .w = launcher.width, .h = height - bar_height };
    gfx.fillRect(area.x, area.y, area.w, area.h, 0x141E2E);
    gfx.fillRect(area.x + area.w - 1, area.y, 1, area.h, window_edge);

    drawText(i18n.t(.running), 14, bar_height + 18, accent);
    var y = runningTop();
    for (&root.processes.procs) |*p| {
        if (!p.used) continue;
        if (y + row_height > height) break;
        const holds = surface.owner != null and surface.owner.? == p.pid;
        const colour = if (holds and surface.hidden) warn_colour else if (holds) good_colour else text_colour;
        drawText(clip(p.nameText(), 16), 20, y + 6, colour);
        if (holds and surface.hidden) drawText(i18n.t(.put_away), 20 + 17 * cell_w, y + 6, dim_colour);
        y += row_height;
    }

    y = startableTop();
    drawText(i18n.t(.start_program), 14, y - 26, accent);
    var index: usize = 0;
    while (index < startable_count) : (index += 1) {
        if (y + row_height > height) break;
        drawText(startable[index][0..startable_len[index]], 20, y + 6, text_colour);
        y += row_height;
    }
}

fn drawTools() void {
    drawToolsTab();
    const area = Rect{
        .x = width - tools.width,
        .y = bar_height,
        .w = tools.width,
        .h = height - bar_height,
    };
    gfx.fillRect(area.x, area.y, area.w, area.h, panel_fill);
    gfx.fillRect(area.x, area.y, 1, area.h, window_edge);

    drawText(i18n.t(.control), area.x + 16, bar_height + 18, accent);
    drawControl(.{ .x = area.x, .y = bar_height + 36, .w = area.w, .h = 302 });

    drawText(i18n.t(.settings), area.x + 16, bar_height + 326, accent);
    drawSettings(.{ .x = area.x, .y = bar_height + 346, .w = area.w, .h = 150 });

    drawText(i18n.t(.tasks), area.x + 16, bar_height + 502, accent);
    drawTasks(.{ .x = area.x + 4, .y = bar_height + 522, .w = area.w - 8, .h = area.h -| 540 });
}

fn repaintAll() void {
    paintDesktop(.{ .x = 0, .y = bar_height, .w = width, .h = height - bar_height });
    drawStatusBar();
    var i: usize = 0;
    while (i < window_count) : (i += 1) drawWindow(i);
    paintPanels();
}

/// The panels live in their own layer and are painted only when what they say
/// changes — when they open, when a program starts or ends, and when the task
/// figures are refreshed. Not once per frame of an animation.
fn paintPanels() void {
    gfx.paintTo(.overlay);
    drawLauncher();
    drawTools();
    gfx.paintTo(.desktop);
}

// --- cursor ----------------------------------------------------------------

/// The pointer is a layer in the compositor: moving it damages where it was
/// and where it is going, and the shape is drawn during `present`. The saved
/// patch of screen this used to keep is gone, and with it the trail it left
/// whenever something repainted underneath.
fn drawCursor() void {
    gfx.moveCursor(cursor_x, cursor_y);
}

fn eraseCursor() void {}

pub fn enter() bool {
    if (!has_framebuffer) return false;
    if (!fb.ready()) return false;
    const dims = fb.dimensions();
    // The same floor the settings offer. Letting a screen be chosen that the
    // desktop then refuses to start on would leave someone with a serial
    // console and no way back.
    if (dims.width < 800 or dims.height < 600) return false;

    width = dims.width;
    height = dims.height;
    // The compositor owns the screen from here: everything below draws into
    // its layers and nothing reaches the framebuffer except `present`.
    if (!gfx.init(&@import("root").frames)) return false;
    sizePanels();
    active_now = true;
    dragging = null;
    hot_button = null;

    const margin: u32 = 24;
    const body_h = height - bar_height - margin * 2;

    // One window on the desktop: the shell. Control and tasks live in the
    // panel on the right, which is out of the way until the button is pressed.
    windows[0] = .{
        .kind = .terminal,
        .title = "",
        .rect = .{
            .x = margin,
            .y = bar_height + margin,
            .w = width - margin * 2,
            .h = body_h,
        },
    };
    window_count = 1;
    focused = 0;
    // Whatever was chosen on a previous run.
    if (comptime @hasDecl(hal.impl, "boot")) {
        const boot = hal.impl.boot;
        // boot.zig read the settings file before it handed the screen over;
        // reading it again here could only disagree with what is on screen.
        const stored = boot.stored;
        i18n.setLanguage(if (stored.language == 1) .russian else .english);
        chosen_screen = boot.screen_current;
        if (stored.screen_width != 0) {
            var index: usize = 0;
            while (index < boot.screen_count) : (index += 1) {
                const screen = boot.screens[index];
                if (screen.width == stored.screen_width and screen.height == stored.screen_height) {
                    chosen_screen = screen.mode;
                    break;
                }
            }
        }
        screen_pending = chosen_screen != boot.screen_current;
        var index: usize = 0;
        while (index < boot.screen_count) : (index += 1) {
            if (boot.screens[index].mode == chosen_screen) {
                setScreenLabel(boot.screens[index].width, boot.screens[index].height);
                break;
            }
        }
        if (screen_len == 0) setScreenLabel(width, height);
    }

    launcher.shown = 0;
    launcher.open = false;
    tools.shown = 0;
    tools.open = false;
    readStartable();

    cursor_x = width / 2;
    cursor_y = height / 2;

    // The text console has been on this framebuffer until now; from here the
    // desktop owns it and console output is routed into the terminal window.
    if (@hasDecl(fb, "setConsoleEnabled")) fb.setConsoleEnabled(false);
    klog.sink = termWrite;

    termWrite(i18n.t(.desktop_ready));
    termWrite("\n");
    repaintAll();
    drawCursor();
    return true;
}

pub fn leave() void {
    active_now = false;
    klog.sink = null;
    if (has_framebuffer) {
        if (@hasDecl(fb, "setConsoleEnabled")) fb.setConsoleEnabled(true);
        fb.resetConsole();
    }
}

// --- input -----------------------------------------------------------------

fn windowAt(px: u32, py: u32) ?usize {
    var i = window_count;
    while (i > 0) {
        i -= 1;
        if (windows[i].rect.contains(px, py)) return i;
    }
    return null;
}

fn buttonAt(px: u32, py: u32) ?usize {
    var i: usize = 0;
    while (i < button_count) : (i += 1) {
        if (buttons[i].rect.contains(px, py)) return i;
    }
    return null;
}

fn perform(action: Action) void {
    const root = @import("root");
    switch (action) {
        .power_cycle => {
            const next: power.Profile = switch (root.scheduler.governor.current) {
                .performance => .balanced,
                .balanced => .power_save,
                .power_save => .critical,
                .critical => .performance,
            };
            root.scheduler.setManualProfile(next);
            klog.info("power profile: {s}", .{next.label()});
        },
        .grant => {
            const id = root.registry.derive(
                root.shell_home_cap,
                root.shell_pid,
                root.agent_pid,
                .{ .read = true, .list = true },
                .{ .fs = cap.Path.from("/home/user/Documents") },
                .{ .lifetime_ns = 10 * 60 * 1_000_000_000, .purpose = "granted from the desktop" },
                hal.nowNs(),
            ) catch {
                klog.warn("grant refused", .{});
                return;
            };
            klog.info("token {d} granted to the agent for 10 minutes", .{id});
        },
        .revoke_all => {
            const n = root.registry.revokeAllOf(root.agent_pid, hal.nowNs());
            klog.info("revoked {d} token(s) from the agent", .{n});
        },
        .run_user => {
            const tid = root.startUserProgram(.hello) catch {
                klog.warn("a user program is already running", .{});
                return;
            };
            klog.info("user thread {d} started", .{tid});
        },
        .language => {
            i18n.setLanguage(if (i18n.language() == .english) .russian else .english);
            shell.languageChanged(true);
            remember();
            repaintAll();
        },
        .layout_switch => {
            if (has_keyboard) {
                const kbd = hal.impl.kbd;
                kbd.setSwitch(switch (kbd.currentSwitch()) {
                    .shift_alt => .shift_ctrl,
                    .shift_ctrl => .ctrl_space,
                    .ctrl_space => .shift_alt,
                });
            }
        },
        .screen_next => nextScreen(),
        .shut_down => powerOff(),
        .restart_machine => restartMachine(),
    }
}

/// Move to the next screen size the firmware offered. It cannot take effect
/// now — the code that changes a mode belongs to the firmware, and this kernel
/// took that memory for itself — so it is written down for the next start.
/// Stop the machine. Anything not yet on the disk would be lost, and the one
/// thing this system keeps there is the settings file, which is written the
/// moment a setting changes rather than at shutdown.
fn powerOff() void {
    if (comptime !@hasDecl(hal.impl, "powerOff")) {
        termWrite(i18n.t(.no_power_control));
        termWrite("\n");
        return;
    }
    if (!hal.impl.canPowerOff()) {
        termWrite(i18n.t(.no_power_control));
        termWrite("\n");
        term_dirty = true;
        return;
    }
    hal.impl.powerOff();
    // Still here: the write went somewhere that did not stop the machine.
    termWrite(i18n.t(.no_power_control));
    termWrite("\n");
    term_dirty = true;
}

fn restartMachine() void {
    if (comptime !@hasDecl(hal.impl, "restart")) return;
    hal.impl.restart();
    termWrite(i18n.t(.no_power_control));
    termWrite("\n");
    term_dirty = true;
}

fn nextScreen() void {
    // With a display of our own, the next size happens rather than being
    // promised. The panel is drawn again by the resize itself.
    if (comptime @hasDecl(hal.impl, "displayModes")) {
        if (liveDisplay()) {
            const modes = hal.impl.displayModes();
            var at: usize = 0;
            while (at < modes.len) : (at += 1) {
                if (modes[at].width == width and modes[at].height == height) break;
            }
            const wanted = modes[(at + 1) % modes.len];
            _ = applyScreen(wanted.width, wanted.height);
            return;
        }
    }

    if (comptime !@hasDecl(hal.impl, "boot")) return;
    const boot = hal.impl.boot;
    if (boot.screen_count == 0) return;

    var index: usize = 0;
    while (index < boot.screen_count) : (index += 1) {
        if (boot.screens[index].mode == chosen_screen) break;
    }
    index = (index + 1) % boot.screen_count;
    chosen_screen = boot.screens[index].mode;
    setScreenLabel(boot.screens[index].width, boot.screens[index].height);
    screen_pending = chosen_screen != boot.screen_current;
    remember();
}

var chosen_screen: u16 = 0xFFFF;

/// Whether this machine's display can be resized while it runs. When it can,
/// the sizes come from the driver; when it cannot, from the list the firmware
/// offered at boot and a choice waits for the next start.
fn liveDisplay() bool {
    if (comptime !@hasDecl(hal.impl, "displayModes")) return false;
    return hal.impl.displayModes().len > 0;
}

/// Whether choosing a screen takes effect now or at the next start. The
/// difference is the whole point of having a driver, and it is the difference
/// the person choosing needs told.
pub fn screenAppliesNow() bool {
    return liveDisplay();
}

/// List the screen sizes, marking the one in use and, on a machine that needs
/// a restart to change it, the one chosen for next time. Printing is the
/// caller's, so this works from a console with no desktop running.
pub fn reportScreens(print: anytype) void {
    if (comptime @hasDecl(hal.impl, "displayModes")) {
        if (liveDisplay()) {
            for (hal.impl.displayModes(), 0..) |mode, index| {
                const mark = if (mode.width == width and mode.height == height) " (in use)" else "";
                print("  {d}  {d}x{d}{s}", .{ index, mode.width, mode.height, mark });
            }
            return;
        }
    }

    if (comptime !@hasDecl(hal.impl, "boot")) return;
    const boot = hal.impl.boot;
    if (boot.screen_count == 0) {
        print("this machine offered no screen sizes", .{});
        return;
    }
    var index: usize = 0;
    while (index < boot.screen_count) : (index += 1) {
        const screen = boot.screens[index];
        const mark = if (screen.mode == boot.screen_current)
            " (in use)"
        else if (screen.mode == chosen_screen)
            " (at the next start)"
        else
            "";
        print("  {d}  {d}x{d}{s}", .{ index, screen.width, screen.height, mark });
    }
}

/// Choose a screen by its position in that list. On a machine with a driver of
/// our own this happens now; otherwise it is remembered for the next start.
pub fn chooseScreen(index: u32) bool {
    if (comptime @hasDecl(hal.impl, "displayModes")) {
        if (liveDisplay()) {
            const modes = hal.impl.displayModes();
            if (index >= modes.len) return false;
            return applyScreen(modes[index].width, modes[index].height);
        }
    }

    if (comptime !@hasDecl(hal.impl, "boot")) return false;
    const boot = hal.impl.boot;
    if (index >= boot.screen_count) return false;
    chosen_screen = boot.screens[index].mode;
    setScreenLabel(boot.screens[index].width, boot.screens[index].height);
    screen_pending = chosen_screen != boot.screen_current;
    remember();
    return true;
}

/// Change the size of the screen with the machine running.
///
/// Everything kept at screen size has to be rebuilt: the compositor's layers,
/// the window that fills the desktop, where the pointer is. The order matters
/// -- the display moves first, so the compositor asks the framebuffer what
/// size it is now and gets the new answer.
pub fn applyScreen(want_width: u32, want_height: u32) bool {
    if (comptime !@hasDecl(hal.impl, "displaySetMode")) return false;
    if (want_width == width and want_height == height) return true;
    if (want_width < 800 or want_height < 600) return false;

    const root = @import("root");
    if (!hal.impl.displaySetMode(want_width, want_height)) return false;
    if (!gfx.resize(&root.frames)) {
        // The screen is the new size but there is no memory to draw it with.
        // Going back is the only honest move left.
        _ = hal.impl.displaySetMode(width, height);
        _ = gfx.resize(&root.frames);
        return false;
    }

    width = want_width;
    height = want_height;
    sizePanels();
    layOutScreen();
    setScreenLabel(width, height);
    screen_pending = false;
    remember();

    repaintAll();
    drawCursor();
    return true;
}

/// Put the windows and the pointer where they belong for the current size.
/// Shared by the first start and every resize after it, so the two cannot
/// drift apart.
fn layOutScreen() void {
    const margin: u32 = 24;
    const body_h = height -| (bar_height + margin * 2);
    windows[0].rect = .{
        .x = margin,
        .y = bar_height + margin,
        .w = width -| margin * 2,
        .h = body_h,
    };
    var index: usize = 1;
    while (index < window_count) : (index += 1) {
        const rect = &windows[index].rect;
        if (rect.x + rect.w > width) rect.x = width -| rect.w;
        if (rect.y + rect.h > height) rect.y = height -| rect.h;
    }
    if (cursor_x >= width) cursor_x = width - 1;
    if (cursor_y >= height) cursor_y = height - 1;
}

/// Something outside changed a setting: keep it and repaint what says so.
pub fn settingsChanged() void {
    remember();
    if (active_now) repaintAll();
}

/// Keep the choices in the settings file, so they survive a restart and so a
/// person can read them. A machine with no writable disk falls back on the
/// UEFI variable, which is the only other place on such a machine that
/// remembers anything.
fn remember() void {
    if (comptime !@hasDecl(hal.impl, "boot")) return;
    const boot = hal.impl.boot;

    var size = boot.config.Values{ .language = @intFromEnum(i18n.language()) };
    if (liveDisplay()) {
        // What is on screen is what to remember. The firmware's mode numbers
        // mean nothing on a display the kernel drives itself.
        size.screen_width = width;
        size.screen_height = height;
    } else {
        var index: usize = 0;
        while (index < boot.screen_count) : (index += 1) {
            if (boot.screens[index].mode == chosen_screen) {
                size.screen_width = boot.screens[index].width;
                size.screen_height = boot.screens[index].height;
                break;
            }
        }
    }

    const root = @import("root");
    if (root.fsSaveConfig(size)) return;

    const kept = boot.settings.save(.{
        .language = size.language,
        .screen_mode = chosen_screen,
    });
    if (!kept) klog.warn("there is nowhere on this machine to keep settings", .{});
}

/// Where the right-hand panel is opened from: a tab on the edge, level with
/// the status bar, which is where a thing that slides out from the right
/// should be reached.
/// How wide a string is on screen. Cyrillic is two bytes a letter, and a
/// label measured in bytes comes out twice its size.
/// As much of a string as fits in `room` pixels, cut on a character boundary
/// so a Cyrillic letter is never left half-written.
/// As much of the status line as fits, cut between fields rather than inside
/// one. A line ending in a bare "up" with no number reads as a fault; a line
/// that stops after the last whole figure reads as a line that ran out of room.
fn clipToFields(text: []const u8, room: u32) []const u8 {
    const fits = clipToWidth(text, room);
    if (fits.len == text.len) return text;
    var end = fits.len;
    while (end > 0) : (end -= 1) {
        // Fields are separated by runs of spaces; cut at the start of one.
        if (fits[end - 1] == ' ' and end >= 2 and fits[end - 2] == ' ') {
            return fits[0 .. end - 2];
        }
    }
    return fits;
}

fn clipToWidth(text: []const u8, room: u32) []const u8 {
    var used: u32 = 0;
    var index: usize = 0;
    var last_boundary: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] & 0xC0 != 0x80) {
            last_boundary = index;
            if (used + cell_w > room) return text[0..index];
            used += cell_w;
        }
    }
    return text;
}

fn glyphWidth(text: []const u8) u32 {
    var glyphs: u32 = 0;
    for (text) |byte| {
        if (byte & 0xC0 != 0x80) glyphs += 1;
    }
    return glyphs * cell_w;
}

fn toolsTab() Rect {
    const indicator_w: u32 = 3 * cell_w + 16;
    // As wide as the word on it: a label that does not fit reads as a
    // different word, and the word changes with the language.
    const tab_w: u32 = glyphWidth(i18n.t(.control)) + 20;
    return .{ .x = width -| (indicator_w + tab_w + 12), .y = 0, .w = tab_w, .h = bar_height };
}

fn handlePress() void {
    // The panels are in front of everything, so they are asked first.
    if (within(toolsTab(), cursor_x, cursor_y)) {
        tools.open = !tools.open;
        paintPanels();
        return;
    }
    if (launcher.visible() and cursor_x < launcher.shown) {
        handleLauncherPress();
        return;
    }
    if (tools.shown == tools.width and cursor_x >= width - tools.shown) {
        if (buttonAt(cursor_x, cursor_y)) |index| {
            perform(buttons[index].action);
            term_dirty = true;
            paintPanels();
        }
        return;
    }

    const over_window = windowAt(cursor_x, cursor_y);
    if (over_window) |index| {
        if (index != focused) {
            const previous = focused;
            focused = index;
            drawWindowChrome(previous);
            drawWindowChrome(index);
        }
        // The title bar is the handle: pressing it starts a drag.
        if (cursor_y < windows[index].rect.y + 27) {
            dragging = index;
            drag_dx = @as(i64, cursor_x) - windows[index].rect.x;
            drag_dy = @as(i64, cursor_y) - windows[index].rect.y;
            return;
        }
    }
    if (buttonAt(cursor_x, cursor_y)) |index| {
        perform(buttons[index].action);
        term_dirty = true;
        tasks_dirty = true;
    }
}

fn within(rect: Rect, px: u32, py: u32) bool {
    return px >= rect.x and py >= rect.y and px < rect.x + rect.w and py < rect.y + rect.h;
}

/// A press in the launcher: a running program is brought back, and a program
/// on the volume is started.
fn handleLauncherPress() void {
    const root = @import("root");

    var listed: usize = 0;
    for (&root.processes.procs) |*p| {
        if (!p.used) continue;
        listed += 1;
    }
    if (rowAt(runningTop(), listed, cursor_y)) |row| {
        var seen: usize = 0;
        for (&root.processes.procs) |*p| {
            if (!p.used) continue;
            if (seen == row) {
                if (surface.owner != null and surface.owner.? == p.pid and surface.hidden) {
                    surface.show();
                    surface_dirty = true;
                    paintPanels();
                }
                return;
            }
            seen += 1;
        }
        return;
    }

    if (rowAt(startableTop(), startable_count, cursor_y)) |row| {
        var path: [16]u8 = @splat(0);
        path[0] = '/';
        const name = startable[row][0..startable_len[row]];
        @memcpy(path[1 .. 1 + name.len], name);
        _ = root.startElf(path[0 .. 1 + name.len], "") catch {
            termWrite("could not start that program\n");
            return;
        };
        launcher.open = false;
        paintPanels();
    }
}

fn moveWindow(index: usize) void {
    const w = &windows[index];
    const nx = @max(0, @min(@as(i64, cursor_x) - drag_dx, @as(i64, width) - @as(i64, w.rect.w)));
    const ny = @max(@as(i64, bar_height), @min(@as(i64, cursor_y) - drag_dy, @as(i64, height) - @as(i64, w.rect.h)));
    const new_x: u32 = @intCast(nx);
    const new_y: u32 = @intCast(ny);
    if (new_x == w.rect.x and new_y == w.rect.y) return;

    w.rect.x = new_x;
    w.rect.y = new_y;
    // Windows may overlap while one is being dragged, so the cheapest correct
    // answer is to paint the whole desktop again.
    repaintAll();
}

/// Consume input. Returns true when something happened, so the caller knows
/// whether to keep the CPU or hand it over.
/// The surface a program can be given, and the events that go with it.
///
/// One at a time and owned by a process: FR-5.3 asks for windows to be
/// contexts the shell manages, and this is the smallest honest version of that
/// — the shell hands over a rectangle and the input that lands in it, and
/// takes both back when the program ends or the user presses Escape.
pub const surface = struct {
    pub const EventKind = enum(u8) {
        none = 0,
        key = 1,
        move = 2,
        press = 3,
        release = 4,
        /// The shell has taken the surface back; stop drawing and finish.
        closed = 5,
        /// The window was dragged: x and y are its new origin on the screen.
        moved = 6,
        /// Put away, still running. Stop painting until `shown`.
        hidden = 7,
        shown = 8,
    };

    pub const Event = struct {
        kind: EventKind = .none,
        key: u8 = 0,
        buttons: u8 = 0,
        x: u16 = 0,
        y: u16 = 0,

        /// Packed into one machine word, so taking an event is a system call
        /// with no buffer and no copying.
        pub fn packed_(self: Event) u64 {
            return @as(u64, @intFromEnum(self.kind)) |
                (@as(u64, self.key) << 8) |
                (@as(u64, self.buttons) << 16) |
                (@as(u64, self.x) << 32) |
                (@as(u64, self.y) << 48);
        }
    };

    /// The compositor names this shape too; sharing it keeps one definition
    /// of where a window is.
    pub const Area = gfx.Rect;

    pub var owner: ?u32 = null;
    pub var area: Area = .{};

    const capacity = 64;
    var ring: [capacity]Event = @splat(.{});
    var head: usize = 0;
    var tail: usize = 0;

    /// Give the surface to a process. Refused while another holds it: two
    /// programs drawing over each other is a window manager, and this is not
    /// one yet.
    pub fn grab(pid: u32, x: u32, y: u32, w: u32, h: u32) bool {
        if (!has_framebuffer) return false;
        if (owner != null and owner.? != pid) return false;
        if (w == 0 or h == 0 or x + w > width or y + h > height) return false;
        if (w > gfx.max_surface_w or h > gfx.max_surface_h) return false;
        owner = pid;
        area = .{ .x = x, .y = y, .w = w, .h = h };
        head = 0;
        tail = 0;
        gfx.setSurface(.{ .x = x, .y = y, .w = w, .h = h }, true);
        return true;
    }

    /// Give the surface back at the program's own request: it knows.
    pub fn release(pid: u32) void {
        if (owner == null or owner.? != pid) return;
        owner = null;
        area = .{};
        head = 0;
        tail = 0;
        gfx.setSurface(.{}, false);
    }

    /// Take the surface away. The difference from `release` is who decided:
    /// the program is told, because a program that has lost its window and
    /// does not know it goes on running with nowhere to draw.
    pub fn revoke() void {
        if (owner == null) return;
        head = 0;
        tail = 0;
        push(.{ .kind = .closed });
        // The owner stays set until the program has had a chance to read the
        // event; it is cleared when it asks for the next one and finds none.
        closing = true;
    }

    var closing: bool = false;

    /// The bar the shell draws above a program's rectangle, so that there is
    /// something to take hold of and somewhere to put the two buttons every
    /// window system has had for thirty years.
    pub const title_height: u32 = 22;
    pub const button_size: u32 = 16;

    /// Hidden means the program keeps running with nowhere to draw: its
    /// pixels are not on the screen, its input goes elsewhere, and it is told
    /// so it can stop painting. The way back is the chip in the status bar.
    pub var hidden: bool = false;
    pub var name: [16]u8 = @splat(0);
    pub var name_len: u8 = 0;

    pub fn nameText() []const u8 {
        return name[0..name_len];
    }

    pub fn hide() void {
        if (owner == null or hidden) return;
        hidden = true;
        gfx.setSurface(area, false);
        push(.{ .kind = .hidden });
    }

    pub fn show() void {
        if (owner == null or !hidden) return;
        hidden = false;
        gfx.setSurface(area, true);
        push(.{ .kind = .shown });
    }

    /// Where the two buttons sit, in screen coordinates.
    fn closeBox() Area {
        return .{
            .x = area.x + area.w - button_size - 6,
            .y = area.y - title_height + 3,
            .w = button_size,
            .h = button_size,
        };
    }

    fn hideBox() Area {
        return .{
            .x = area.x + area.w - 2 * button_size - 12,
            .y = area.y - title_height + 3,
            .w = button_size,
            .h = button_size,
        };
    }

    fn inside(box: Area, px: u32, py: u32) bool {
        return px >= box.x and py >= box.y and px < box.x + box.w and py < box.y + box.h;
    }

    fn inTitle(px: u32, py: u32) bool {
        if (area.w == 0 or area.y < title_height) return false;
        return px >= area.x and px < area.x + area.w and
            py >= area.y - title_height and py < area.y;
    }

    pub fn moveTo(x: u32, y: u32) void {
        if (owner == null) return;
        if (x + area.w > width or y + area.h > height) return;
        area.x = x;
        area.y = y;
        gfx.setSurface(area, !hidden);
        push(.{ .kind = .moved, .x = @intCast(x), .y = @intCast(y) });
    }

    pub fn heldBy(pid: u32) bool {
        return owner != null and owner.? == pid;
    }

    pub fn push(event: Event) void {
        const next = (head + 1) % capacity;
        if (next == tail) return; // full: drop the oldest news, not the newest
        ring[head] = event;
        head = next;
    }

    fn pushPointer(kind: EventKind, px: u32, py: u32, held: u8) void {
        // Outside the surface is not this program's business.
        if (px < area.x or py < area.y) return;
        if (px >= area.x + area.w or py >= area.y + area.h) return;
        push(.{
            .kind = kind,
            .buttons = held,
            .x = @intCast(px - area.x),
            .y = @intCast(py - area.y),
        });
    }

    /// Ask the program to paint itself again. The desktop repaints the screen
    /// underneath it whenever a panel moves, and a program that is not told
    /// simply disappears until it next has news of its own.
    pub fn requestRepaint() void {
        if (owner == null or hidden) return;
        push(.{ .kind = .shown });
    }

    pub fn take(pid: u32) ?Event {
        if (owner == null or owner.? != pid) return null;
        if (tail == head) {
            // Nothing left, and the shell asked for the surface back: now it
            // is gone, and the next call will say so by refusing.
            if (closing) {
                owner = null;
                area = .{};
                closing = false;
            }
            return null;
        }
        const event = ring[tail];
        tail = (tail + 1) % capacity;
        return event;
    }
};

/// Repaint the desktop after a program's window goes away or moves.
var surface_dirty = false;
/// Where the pointer took hold of the title bar, so dragging keeps its grip.
var surface_drag: ?struct { dx: u32, dy: u32 } = null;
var surface_chrome_at: ?surface.Area = null;

/// The bar above a program's window: its name on the left, and on the right
/// the two buttons every window system has — put away, and close.
fn drawSurfaceChrome() void {
    if (surface.owner == null or surface.hidden) return;
    const area = surface.area;
    if (area.w == 0 or area.y < surface.title_height) return;

    const top = area.y - surface.title_height;
    gfx.fillRect(area.x, top, area.w, surface.title_height, title_fill_focused);
    gfx.fillRect(area.x, top, area.w, 1, window_edge);
    drawText(surface.nameText(), area.x + 8, top + 7, text_colour);

    const hide_box = surface.hideBox();
    gfx.fillRect(hide_box.x, hide_box.y, hide_box.w, hide_box.h, 0x00314A6B);
    // A minus, which is what "put this away" has looked like since 1995.
    gfx.fillRect(hide_box.x + 4, hide_box.y + hide_box.h / 2, hide_box.w - 8, 2, text_colour);

    const close_box = surface.closeBox();
    gfx.fillRect(close_box.x, close_box.y, close_box.w, close_box.h, 0x009A3B34);
    drawText("x", close_box.x + 5, close_box.y + 4, 0x00F6E9E7);

    surface_chrome_at = area;
}

/// The chip in the status bar that a put-away window comes back from.
fn hiddenChip() ?Rect {
    if (surface.owner == null or !surface.hidden) return null;
    const chip_w: u32 = 110;
    return .{ .x = 12, .y = bar_height + 6, .w = chip_w, .h = 20 };
}

fn drawHiddenChip() void {
    const chip = hiddenChip() orelse return;
    gfx.fillRect(chip.x, chip.y, chip.w, chip.h, title_fill_focused);
    drawFrame(chip, window_edge);
    drawText(surface.nameText(), chip.x + 8, chip.y + 6, text_colour);
}

pub fn poll() bool {
    if (!has_framebuffer) return false;
    if (!active_now) return false;
    var busy = false;

    while (hal.readKey()) |key| {
        busy = true;
        // Escape always comes back here: a program that has the surface must
        // not be able to keep the keyboard, or a wedged program would take the
        // machine with it.
        if (surface.owner != null and key != 27) {
            surface.push(.{ .kind = .key, .key = key });
            continue;
        }
        if (surface.owner != null and key == 27) {
            surface.revoke();
            surface_dirty = true;
            continue;
        }
        shell.handleKey(key);
    }

    var moved = false;
    var pressed = false;
    var released = false;

    while (hal.readPointer()) |event| {
        busy = true;
        if (event.dx != 0 or event.dy != 0) {
            const nx = @as(i64, cursor_x) + event.dx;
            const ny = @as(i64, cursor_y) + event.dy;
            cursor_x = @intCast(@max(0, @min(nx, @as(i64, width) - cursor_w)));
            cursor_y = @intCast(@max(0, @min(ny, @as(i64, height) - cursor_h)));
            moved = true;
        }
        const was_down = buttons_down & 1 != 0;
        buttons_down = event.buttons;
        if (!was_down and event.left()) pressed = true;
        if (was_down and !event.left()) released = true;
    }

    // The launcher comes out when the pointer reaches the edge and goes back
    // when it leaves, which is the one gesture that needs no button at all.
    if (moved) {
        if (cursor_x <= 2 and !launcher.open) {
            readStartable();
            launcher.open = true;
            paintPanels();
        } else if (launcher.open and cursor_x > launcher.width + 40) {
            launcher.open = false;
        }
    }

    var sliding = false;
    if (launcher.step()) sliding = true;
    if (tools.step()) sliding = true;
    // What the panels currently cover, told to the compositor every time round
    // rather than only while they move: a value that is one step behind is a
    // window drawn over a panel for exactly one frame, which is the kind of
    // thing that gets noticed and not reproduced.
    {
        const left = launcherRect();
        const right = toolsRect();
        gfx.setOverlay(
            .{ .x = left.x, .y = left.y, .w = left.w, .h = left.h },
            .{ .x = right.x, .y = right.y, .w = right.w, .h = right.h },
        );
    }

    const now = hal.nowNs();
    const status_due = now -% last_status_ns > 1_000_000_000;

    if (moved or pressed or released or term_dirty or status_due or sliding) {
        eraseCursor();
        // Sliding draws nothing at all: the panels are painted in their own
        // layer already, and the animation is the compositor showing a wider
        // or narrower piece of it.

        // A program holding the surface gets the pointer in its own
        // coordinates; the desktop keeps drawing the cursor, because a program
        // that has to draw one is a program that can lose it.
        if (surface.owner != null and surface.hidden) {
            // Put away: the only thing it can be reached by is its chip.
            if (pressed) {
                if (hiddenChip()) |chip| {
                    if (cursor_x >= chip.x and cursor_y >= chip.y and
                        cursor_x < chip.x + chip.w and cursor_y < chip.y + chip.h)
                    {
                        surface.show();
                        surface_dirty = true;
                    }
                }
            }
        } else if (surface.owner != null) {
            if (pressed and surface.inTitle(cursor_x, cursor_y)) {
                if (surface.inside(surface.closeBox(), cursor_x, cursor_y)) {
                    surface.revoke();
                    surface_dirty = true;
                } else if (surface.inside(surface.hideBox(), cursor_x, cursor_y)) {
                    surface.hide();
                    surface_dirty = true;
                } else {
                    surface_drag = .{
                        .dx = cursor_x - surface.area.x,
                        .dy = cursor_y -| (surface.area.y - surface.title_height),
                    };
                }
            } else if (released) {
                surface_drag = null;
                surface.pushPointer(.release, cursor_x, cursor_y, buttons_down);
            } else if (moved and surface_drag != null) {
                const grip = surface_drag.?;
                const nx = cursor_x -| grip.dx;
                const ny = (cursor_y -| grip.dy) + surface.title_height;
                surface.moveTo(nx, ny);
                surface_dirty = true;
            } else {
                if (moved) surface.pushPointer(.move, cursor_x, cursor_y, buttons_down);
                if (pressed) surface.pushPointer(.press, cursor_x, cursor_y, buttons_down);
            }
        } else {
            if (pressed) handlePress();
            if (released) dragging = null;
            if (moved and dragging != null) moveWindow(dragging.?);
        }

        if (moved) {
            const over = buttonAt(cursor_x, cursor_y);
            if (over != hot_button) {
                hot_button = over;
                var i: usize = 0;
                while (i < button_count) : (i += 1) drawButton(i);
            }
        }

        if (term_dirty) {
            var i: usize = 0;
            while (i < window_count) : (i += 1) {
                if (windows[i].kind == .terminal) drawTerminal(i);
            }
        }
        if (status_due) {
            last_status_ns = now;
            drawStatusBar();
            if (tools.shown == tools.width) paintPanels();
        }

        if (surface_dirty) {
            surface_dirty = false;
            repaintAll();
            drawSurfaceChrome();
        } else if (surface.owner != null and !surface.hidden) {
            const same = if (surface_chrome_at) |was|
                was.x == surface.area.x and was.y == surface.area.y
            else
                false;
            if (!same) drawSurfaceChrome();
        }

        drawCursor();
        gfx.present();
    }

    return busy;
}
