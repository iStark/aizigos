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

/// What the launcher lists: programs on the volume, and what is running.
const max_listed = 8;
var startable: [max_listed][13]u8 = @splat(@splat(0));
var startable_len: [max_listed]u8 = @splat(0);
var startable_count: usize = 0;

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

fn drawToolsTab() void {
    const tab = toolsTab();
    fb.fillRect(tab.x, tab.y + 3, tab.w, tab.h - 6, if (tools.open) accent else title_fill_focused);
    drawText("control", tab.x + 10, 7, if (tools.open) 0x0E1626 else text_colour);
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
    const reserved = indicator_w + toolsTab().w + 36;
    const x = if (width > text_width + reserved) width - text_width - reserved else 0;
    drawText(text, x, 7, bar_text);
    drawToolsTab();

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

fn drawControl(area: Rect) void {
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
const task_name_cols = 11;
const task_class_cols = 5;

fn clip(text: []const u8, columns: usize) []const u8 {
    return text[0..@min(text.len, columns)];
}

fn drawTasks(area: Rect) void {
    const root = @import("root");
    var y = area.y + 10;
    drawText("thread      cls  cpu", area.x + 12, y, dim_colour);
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
        drawNumber("", t.cpu_ns / 1_000_000, "ms", area.x + 12 + 17 * cell_w, y, dim_colour);
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
    if (!launcher.visible()) return;
    const root = @import("root");
    const area = launcherRect();
    fb.fillRect(area.x, area.y, area.w, area.h, 0x141E2E);
    fb.fillRect(area.x + area.w - 1, area.y, 1, area.h, window_edge);

    drawText("running", 14, bar_height + 18, accent);
    var y = runningTop();
    for (&root.processes.procs) |*p| {
        if (!p.used) continue;
        if (y + row_height > height) break;
        const holds = surface.owner != null and surface.owner.? == p.pid;
        const colour = if (holds and surface.hidden) warn_colour else if (holds) good_colour else text_colour;
        drawText(clip(p.nameText(), 16), 20, y + 6, colour);
        if (holds and surface.hidden) drawText("put away", 20 + 17 * cell_w, y + 6, dim_colour);
        y += row_height;
    }

    y = startableTop();
    drawText("start", 14, y - 26, accent);
    var index: usize = 0;
    while (index < startable_count) : (index += 1) {
        if (y + row_height > height) break;
        drawText(startable[index][0..startable_len[index]], 20, y + 6, text_colour);
        y += row_height;
    }
}

fn drawTools() void {
    drawToolsTab();
    if (!tools.visible()) return;
    const area = toolsRect();
    fb.fillRect(area.x, area.y, area.w, area.h, 0x141E2E);
    fb.fillRect(area.x, area.y, 1, area.h, window_edge);
    if (tools.shown < tools.width) return; // mid-slide: the frame is enough

    drawText("control", area.x + 16, bar_height + 18, accent);
    drawControl(.{ .x = area.x, .y = bar_height + 36, .w = area.w, .h = 210 });
    drawText("tasks", area.x + 16, bar_height + 264, accent);
    drawTasks(.{ .x = area.x + 4, .y = bar_height + 282, .w = area.w - 8, .h = area.h - 300 });
}

fn repaintAll() void {
    paintDesktop(.{ .x = 0, .y = bar_height, .w = width, .h = height - bar_height });
    drawStatusBar();
    var i: usize = 0;
    while (i < window_count) : (i += 1) drawWindow(i);
    drawLauncher();
    drawTools();
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
    const body_h = height - bar_height - margin * 2;

    // One window on the desktop: the shell. Control and tasks live in the
    // panel on the right, which is out of the way until the button is pressed.
    windows[0] = .{
        .kind = .terminal,
        .title = "shell",
        .rect = .{
            .x = margin,
            .y = bar_height + margin,
            .w = width - margin * 2,
            .h = body_h,
        },
    };
    window_count = 1;
    focused = 0;
    launcher.shown = 0;
    launcher.open = false;
    tools.shown = 0;
    tools.open = false;
    readStartable();

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

/// Where the right-hand panel is opened from: a tab on the edge, level with
/// the status bar, which is where a thing that slides out from the right
/// should be reached.
fn toolsTab() Rect {
    const indicator_w: u32 = 3 * cell_w + 16;
    // Wide enough for the word: a label that does not fit is a label that
    // reads as something else.
    const tab_w: u32 = 7 * cell_w + 20;
    return .{ .x = width - indicator_w - tab_w - 12, .y = 0, .w = tab_w, .h = bar_height };
}

fn handlePress() void {
    // The panels are in front of everything, so they are asked first.
    if (within(toolsTab(), cursor_x, cursor_y)) {
        tools.open = !tools.open;
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
            drawTools();
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

    pub const Area = struct { x: u32 = 0, y: u32 = 0, w: u32 = 0, h: u32 = 0 };

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
        owner = pid;
        area = .{ .x = x, .y = y, .w = w, .h = h };
        head = 0;
        tail = 0;
        return true;
    }

    /// Give the surface back at the program's own request: it knows.
    pub fn release(pid: u32) void {
        if (owner == null or owner.? != pid) return;
        owner = null;
        area = .{};
        head = 0;
        tail = 0;
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
        push(.{ .kind = .hidden });
    }

    pub fn show() void {
        if (owner == null or !hidden) return;
        hidden = false;
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
    fb.fillRect(area.x, top, area.w, surface.title_height, title_fill_focused);
    fb.fillRect(area.x, top, area.w, 1, window_edge);
    drawText(surface.nameText(), area.x + 8, top + 7, text_colour);

    const hide_box = surface.hideBox();
    fb.fillRect(hide_box.x, hide_box.y, hide_box.w, hide_box.h, 0x00314A6B);
    // A minus, which is what "put this away" has looked like since 1995.
    fb.fillRect(hide_box.x + 4, hide_box.y + hide_box.h / 2, hide_box.w - 8, 2, text_colour);

    const close_box = surface.closeBox();
    fb.fillRect(close_box.x, close_box.y, close_box.w, close_box.h, 0x009A3B34);
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
    fb.fillRect(chip.x, chip.y, chip.w, chip.h, title_fill_focused);
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
        } else if (launcher.open and cursor_x > launcher.width + 40) {
            launcher.open = false;
        }
    }

    var sliding = false;
    if (launcher.step()) sliding = true;
    if (tools.step()) sliding = true;

    const now = hal.nowNs();
    const status_due = now -% last_status_ns > 1_000_000_000;

    if (moved or pressed or released or term_dirty or status_due or sliding) {
        eraseCursor();
        if (sliding) {
            // Sliding uncovers whatever was behind, so the desktop underneath
            // is repainted and the panels drawn over it. A whole repaint each
            // step is honest and, at this size, fast enough to look smooth.
            repaintAll();
            drawSurfaceChrome();
            surface.requestRepaint();
        }

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
            if (tools.shown == tools.width) drawTools();
        }

        if (surface_dirty) {
            surface_dirty = false;
            repaintAll();
            drawSurfaceChrome();
            surface.requestRepaint();
        } else if (surface.owner != null and !surface.hidden) {
            const same = if (surface_chrome_at) |was|
                was.x == surface.area.x and was.y == surface.area.y
            else
                false;
            if (!same) drawSurfaceChrome();
        }

        drawCursor();
    }

    return busy;
}
