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
const font = if (has_framebuffer) @import("hal/uefi_x86_64/font.zig") else struct {};

// --- theme -----------------------------------------------------------------

const desktop_top: u32 = 0x0B1220;
const desktop_bottom: u32 = 0x1C2C48;
const bar_fill: u32 = 0x0E1626;
const bar_text: u32 = 0x93A7C4;
const accent: u32 = 0x6FA8FF;

const window_fill: u32 = 0x18212F;
const window_edge: u32 = 0x33465F;
const window_edge_focused: u32 = 0x6FA8FF;
const title_fill: u32 = 0x223146;
const title_fill_focused: u32 = 0x2C4368;
const shadow_colour: u32 = 0x070B12;

const text_colour: u32 = 0xD9E2EF;
const dim_colour: u32 = 0x8095AC;
const good_colour: u32 = 0x7BD88F;
const warn_colour: u32 = 0xE0B341;

const button_fill: u32 = 0x2B4568;
const button_hot: u32 = 0x3E6FA8;
const button_edge: u32 = 0x4F7CB0;

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

    fn label(self: Action) []const u8 {
        return switch (self) {
            .power_cycle => "cycle power profile",
            .grant => "grant agent 10 min",
            .revoke_all => "revoke agent tokens",
            .run_user => "run user program",
        };
    }
};

const Button = struct {
    rect: Rect,
    action: Action,
};

var windows: [3]Window = undefined;
var window_count: usize = 0;
var focused: usize = 0;

var buttons: [4]Button = undefined;
var button_count: usize = 0;
var hot_button: ?usize = null;

// --- state -----------------------------------------------------------------

const cursor_w = 10;
const cursor_h = 16;
var cursor_backing: [cursor_w * cursor_h]u32 = @splat(0);
var cursor_saved = false;
/// Where the cursor was painted. Erasing at the current position instead
/// leaves a trail behind every movement.
var drawn_x: u32 = 0;
var drawn_y: u32 = 0;

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
        fb.fillRect(area.x, y, area.w, 1, colour);
    }
}

fn drawFrame(rect: Rect, colour: u32) void {
    fb.fillRect(rect.x, rect.y, rect.w, 1, colour);
    fb.fillRect(rect.x, rect.y + rect.h - 1, rect.w, 1, colour);
    fb.fillRect(rect.x, rect.y, 1, rect.h, colour);
    fb.fillRect(rect.x + rect.w - 1, rect.y, 1, rect.h, colour);
}

fn drawText(text: []const u8, x: u32, y: u32, colour: u32) void {
    fb.drawTextAt(text, x, y, colour, scale);
}

fn drawNumber(prefix: []const u8, value: u64, suffix: []const u8, x: u32, y: u32, colour: u32) void {
    var line = klog.Line{};
    line.str(prefix);
    line.decimal(value);
    line.str(suffix);
    drawText(line.text(), x, y, colour);
}

fn drawStatusBar() void {
    const root = @import("root");
    fb.fillRect(0, 0, width, bar_height, bar_fill);
    fb.fillRect(0, bar_height - 1, width, 1, window_edge);
    drawText("AIZigOS", 12, 7, accent);

    const stats = root.scheduler.stats();
    const memory = root.frames.stats();
    var line = klog.Line{};
    line.str(stats.profile.label());
    line.str("   mem ");
    line.decimal(memory.free_frames * memory.page_size / 1024 / 1024);
    line.str(" MiB   tasks ");
    line.decimal(stats.runnable);
    line.str("   up ");
    line.decimal(hal.nowNs() / 1_000_000_000);
    line.str("s");

    const text = line.text();
    const text_width: u32 = @intCast(text.len * cell_w);
    const indicator_w: u32 = 3 * cell_w + 16;
    const x = if (width > text_width + indicator_w + 12) width - text_width - indicator_w - 12 else 0;
    drawText(text, x, 7, bar_text);

    // The layout indicator sits at the right edge, where a taskbar would put
    // it, and is the only part of the bar with a background of its own.
    if (has_keyboard) {
        const label = hal.impl.kbd.currentLayout().label();
        const box_x = width - indicator_w + 4;
        fb.fillRect(box_x, 4, indicator_w - 12, bar_height - 9, title_fill_focused);
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

fn drawWindowChrome(index: usize) void {
    const w = windows[index];
    const is_focused = index == focused;

    // A soft shadow: two darker rectangles offset from the frame.
    fb.fillRect(w.rect.x + 4, w.rect.y + w.rect.h, w.rect.w, 3, shadow_colour);
    fb.fillRect(w.rect.x + w.rect.w, w.rect.y + 4, 3, w.rect.h - 1, shadow_colour);

    fb.fillRect(w.rect.x, w.rect.y, w.rect.w, w.rect.h, window_fill);
    fb.fillRect(w.rect.x, w.rect.y, w.rect.w, 27, if (is_focused) title_fill_focused else title_fill);
    drawFrame(w.rect, if (is_focused) window_edge_focused else window_edge);
    drawText(w.title, w.rect.x + 12, w.rect.y + 6, if (is_focused) text_colour else dim_colour);
}

/// How many bytes of a UTF-8 line fit in a number of character cells. Cutting
/// at a byte count would slice a Russian letter in half.
fn bytesForColumns(line: []const u8, columns: u32) usize {
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
    fb.fillRect(area.x, area.y, area.w, area.h, 0x0C131E);

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

fn drawButton(index: usize) void {
    const b = buttons[index];
    const fill = if (hot_button != null and hot_button.? == index) button_hot else button_fill;
    fb.fillRect(b.rect.x, b.rect.y, b.rect.w, b.rect.h, fill);
    drawFrame(b.rect, button_edge);
    const label = b.action.label();
    const label_width: u32 = @intCast(label.len * cell_w);
    const x = b.rect.x + (b.rect.w -| label_width) / 2;
    drawText(label, x, b.rect.y + (b.rect.h - glyph_h * scale) / 2, text_colour);
}

fn drawControl(index: usize) void {
    const area = contentRect(windows[index]);
    fb.fillRect(area.x, area.y, area.w, area.h, window_fill);

    button_count = 0;
    const actions = [_]Action{ .power_cycle, .grant, .revoke_all, .run_user };
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
const task_name_cols = 13;
const task_class_cols = 5;

fn clip(text: []const u8, columns: usize) []const u8 {
    return text[0..@min(text.len, columns)];
}

fn drawTasks(index: usize) void {
    const root = @import("root");
    const area = contentRect(windows[index]);
    fb.fillRect(area.x, area.y, area.w, area.h, window_fill);

    var y = area.y + 10;
    drawText("thread        class cpu", area.x + 12, y, dim_colour);
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
        drawText(clip(@tagName(t.class), task_class_cols), area.x + 12 + 14 * cell_w, y, dim_colour);
        drawNumber("", t.cpu_ns / 1_000_000, "ms", area.x + 12 + 20 * cell_w, y, dim_colour);
        y += cell_h;
    }

    y += 6;
    drawNumber("switches ", root.scheduler.stats().switches, "", area.x + 12, y, dim_colour);
    y += cell_h;
    drawNumber("bg rounds ", root.indexer_rounds / 1000, "k", area.x + 12, y, dim_colour);
    tasks_dirty = false;
}

fn drawWindow(index: usize) void {
    drawWindowChrome(index);
    switch (windows[index].kind) {
        .terminal => drawTerminal(index),
        .control => drawControl(index),
        .tasks => drawTasks(index),
    }
}

fn repaintAll() void {
    paintDesktop(.{ .x = 0, .y = bar_height, .w = width, .h = height - bar_height });
    drawStatusBar();
    var i: usize = 0;
    while (i < window_count) : (i += 1) drawWindow(i);
}

// --- cursor ----------------------------------------------------------------

/// A plain arrow, drawn as rows of a triangle with a dark right edge so it
/// stays visible over both the desktop and a window.
fn drawCursor() void {
    if (cursor_saved) return;
    drawn_x = cursor_x;
    drawn_y = cursor_y;
    fb.saveRect(drawn_x, drawn_y, cursor_w, cursor_h, &cursor_backing);
    cursor_saved = true;

    var row: u32 = 0;
    while (row < cursor_h) : (row += 1) {
        // Rows 0..9 widen into the arrow head, 10..12 taper, the rest is the
        // tail. Every branch has to stay positive: the shape is computed in
        // unsigned pixels.
        const w: u32 = if (row < 10) row + 1 else if (row < 13) 13 - row else 3;
        const x = if (row < 13) drawn_x else drawn_x + 4;
        fb.fillRect(x, drawn_y + row, @min(w, cursor_w), 1, cursor_colour);
        fb.fillRect(x + @min(w, cursor_w) - 1, drawn_y + row, 1, 1, cursor_edge);
    }
}

fn eraseCursor() void {
    if (!cursor_saved) return;
    fb.restoreRect(drawn_x, drawn_y, cursor_w, cursor_h, &cursor_backing);
    cursor_saved = false;
}

// --- lifecycle -------------------------------------------------------------

pub fn enter() bool {
    if (!has_framebuffer) return false;
    if (!fb.ready()) return false;
    const dims = fb.dimensions();
    if (dims.width < 900 or dims.height < 600) return false;

    width = dims.width;
    height = dims.height;
    active_now = true;
    dragging = null;
    hot_button = null;

    const margin: u32 = 24;
    const right_w: u32 = 420;
    const term_w = width - right_w - margin * 3;
    const body_h = height - bar_height - margin * 2;

    windows[0] = .{
        .kind = .terminal,
        .title = "shell",
        .rect = .{ .x = margin, .y = bar_height + margin, .w = term_w, .h = body_h },
    };
    windows[1] = .{
        .kind = .control,
        .title = "control",
        .rect = .{ .x = margin * 2 + term_w, .y = bar_height + margin, .w = right_w, .h = 232 },
    };
    windows[2] = .{
        .kind = .tasks,
        .title = "tasks",
        .rect = .{
            .x = margin * 2 + term_w,
            .y = bar_height + margin + 256,
            .w = right_w,
            .h = body_h - 256,
        },
    };
    window_count = 3;
    focused = 0;

    cursor_x = width / 2;
    cursor_y = height / 2;
    cursor_saved = false;

    // The text console has been on this framebuffer until now; from here the
    // desktop owns it and console output is routed into the terminal window.
    if (@hasDecl(fb, "setConsoleEnabled")) fb.setConsoleEnabled(false);
    klog.sink = termWrite;

    termWrite("desktop ready; this window is the shell\n");
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
    }
}

fn handlePress() void {
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
pub fn poll() bool {
    if (!has_framebuffer) return false;
    if (!active_now) return false;
    var busy = false;

    while (hal.readKey()) |key| {
        busy = true;
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

    const now = hal.nowNs();
    const status_due = now -% last_status_ns > 1_000_000_000;

    if (moved or pressed or released or term_dirty or status_due) {
        eraseCursor();

        if (pressed) handlePress();
        if (released) dragging = null;
        if (moved and dragging != null) moveWindow(dragging.?);

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
            var i: usize = 0;
            while (i < window_count) : (i += 1) {
                if (windows[i].kind == .tasks) drawTasks(i);
            }
        }

        drawCursor();
    }

    return busy;
}
