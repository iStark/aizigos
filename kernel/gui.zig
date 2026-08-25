//! A pointer-driven surface on the framebuffer.
//!
//! This is not the browser runtime of section 4.5 and does not pretend to be.
//! It is the smallest thing that makes the machine feel like a machine you
//! point at: a cursor that moves with the mouse, a window, and buttons that do
//! real work — switching the power profile, granting the agent a token,
//! revoking it, starting a user program. Every button ends up in the same
//! kernel state the shell prints, which is the point of building it here
//! rather than mocking it up.

const hal = @import("hal/hal.zig");
const klog = @import("klog.zig");
const cap = @import("cap/cap.zig");
const power = @import("sched/power.zig");

const has_framebuffer = @hasDecl(hal.impl, "fb");
const has_mouse = @hasDecl(hal.impl, "mouse");
const fb = if (has_framebuffer) hal.impl.fb else struct {};

const colour = struct {
    const desktop: u32 = 0x101828;
    const window: u32 = 0x1E2A3A;
    const title: u32 = 0x2D4059;
    const border: u32 = 0x4A6FA5;
    const text: u32 = 0xD8E0EA;
    const dim: u32 = 0x8AA0B8;
    const button: u32 = 0x2F5D8A;
    const button_hot: u32 = 0x4A86C8;
    const cursor: u32 = 0xF2F5F8;
    const cursor_edge: u32 = 0x101010;
};

pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    pub fn contains(self: Rect, px: u32, py: u32) bool {
        return px >= self.x and px < self.x + self.w and
            py >= self.y and py < self.y + self.h;
    }
};

pub const Action = enum {
    power_cycle,
    grant,
    revoke_all,
    run_user,
    quit,

    fn label(self: Action) []const u8 {
        return switch (self) {
            .power_cycle => "power profile",
            .grant => "grant 10 min",
            .revoke_all => "revoke agent",
            .run_user => "run program",
            .quit => "back to shell",
        };
    }
};

const Button = struct {
    rect: Rect,
    action: Action,
};

const cursor_w = 8;
const cursor_h = 12;
/// The pixels the cursor is covering, so it can be lifted before it moves.
var cursor_backing: [cursor_w * cursor_h]u32 = @splat(0);
var cursor_saved = false;
/// Where the cursor was actually painted. Erasing at the current position
/// instead leaves a trail behind every movement.
var drawn_x: u32 = 0;
var drawn_y: u32 = 0;

var active_now = false;
var cursor_x: u32 = 0;
var cursor_y: u32 = 0;
var buttons_down: u8 = 0;

var window: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var buttons: [5]Button = undefined;
var button_count: usize = 0;
var hot: ?usize = null;

const log_lines = 6;
const log_width = 60;
var log_text: [log_lines][log_width]u8 = @splat(@splat(' '));
var log_len: [log_lines]usize = @splat(0);
var log_used: usize = 0;

pub fn available() bool {
    if (!has_framebuffer) return false;
    return fb.ready();
}

pub fn active() bool {
    return active_now;
}

fn note(text: []const u8) void {
    if (log_used == log_lines) {
        var i: usize = 1;
        while (i < log_lines) : (i += 1) {
            log_text[i - 1] = log_text[i];
            log_len[i - 1] = log_len[i];
        }
        log_used -= 1;
    }
    const n = @min(text.len, log_width);
    @memcpy(log_text[log_used][0..n], text[0..n]);
    log_len[log_used] = n;
    log_used += 1;
}

fn noteNumber(prefix: []const u8, value: u64) void {
    var line = klog.Line{};
    line.str(prefix);
    line.decimal(value);
    note(line.text());
}

// --- drawing ---------------------------------------------------------------

fn drawButton(index: usize) void {
    const b = buttons[index];
    const fill = if (hot != null and hot.? == index) colour.button_hot else colour.button;
    fb.fillRect(b.rect.x, b.rect.y, b.rect.w, b.rect.h, fill);
    fb.fillRect(b.rect.x, b.rect.y, b.rect.w, 1, colour.border);
    fb.fillRect(b.rect.x, b.rect.y + b.rect.h - 1, b.rect.w, 1, colour.border);
    const label = b.action.label();
    const text_w = label.len * 8 * 2;
    const tx = b.rect.x + (b.rect.w -| @as(u32, @intCast(text_w))) / 2;
    const ty = b.rect.y + (b.rect.h - 16) / 2;
    fb.drawTextAt(label, tx, ty, colour.text, 2);
}

fn drawLog() void {
    const x = window.x + 16;
    var y = window.y + 210;
    fb.fillRect(x, y, window.w - 32, log_lines * 18 + 8, colour.desktop);
    var i: usize = 0;
    while (i < log_used) : (i += 1) {
        fb.drawTextAt(log_text[i][0..log_len[i]], x + 6, y + 4, colour.dim, 2);
        y += 18;
    }
}

fn drawWindow() void {
    fb.fillRect(window.x, window.y, window.w, window.h, colour.window);
    fb.fillRect(window.x, window.y, window.w, 28, colour.title);
    fb.fillRect(window.x, window.y, window.w, 1, colour.border);
    fb.fillRect(window.x, window.y + window.h - 1, window.w, 1, colour.border);
    fb.fillRect(window.x, window.y, 1, window.h, colour.border);
    fb.fillRect(window.x + window.w - 1, window.y, 1, window.h, colour.border);
    fb.drawTextAt("AIZigOS", window.x + 12, window.y + 6, colour.text, 2);

    var i: usize = 0;
    while (i < button_count) : (i += 1) drawButton(i);
    drawLog();
}

fn drawCursor() void {
    if (cursor_saved) return;
    drawn_x = cursor_x;
    drawn_y = cursor_y;
    fb.saveRect(drawn_x, drawn_y, cursor_w, cursor_h, &cursor_backing);
    cursor_saved = true;
    // A plain arrow: a filled triangle with a dark edge so it stays visible
    // over both the window and the desktop.
    var row: u32 = 0;
    while (row < cursor_h) : (row += 1) {
        const width = @min(cursor_w, 1 + row / 2 + 1);
        fb.fillRect(drawn_x, drawn_y + row, width, 1, colour.cursor);
        fb.fillRect(drawn_x + width - 1, drawn_y + row, 1, 1, colour.cursor_edge);
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
    if (dims.width < 480 or dims.height < 360) return false;

    active_now = true;
    hot = null;
    log_used = 0;

    window = .{
        .x = dims.width / 2 - 240,
        .y = dims.height / 2 - 170,
        .w = 480,
        .h = 340,
    };

    button_count = 0;
    const actions = [_]Action{ .power_cycle, .grant, .revoke_all, .run_user, .quit };
    for (actions, 0..) |action, i| {
        const row: u32 = @intCast(i / 2);
        const col: u32 = @intCast(i % 2);
        buttons[button_count] = .{
            .action = action,
            .rect = .{
                .x = window.x + 16 + col * 228,
                .y = window.y + 48 + row * 48,
                .w = 216,
                .h = 36,
            },
        };
        button_count += 1;
    }

    cursor_x = dims.width / 2;
    cursor_y = dims.height / 2;
    cursor_saved = false;

    fb.fillRect(0, 0, dims.width, dims.height, colour.desktop);
    fb.drawTextAt("point at something", 16, 16, colour.dim, 2);
    if (has_mouse and hal.impl.mouse.detected()) {
        note("mouse ready");
    } else {
        note("no mouse reported; use the shell");
    }
    drawWindow();
    drawCursor();
    return true;
}

pub fn leave() void {
    active_now = false;
    if (has_framebuffer) fb.resetConsole();
}

// --- input -----------------------------------------------------------------

fn hitTest(px: u32, py: u32) ?usize {
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
            var line = klog.Line{};
            line.str("power profile: ");
            line.str(next.label());
            note(line.text());
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
                note("grant refused");
                return;
            };
            noteNumber("granted token ", id);
        },
        .revoke_all => {
            const n = root.registry.revokeAllOf(root.agent_pid, hal.nowNs());
            noteNumber("revoked tokens: ", n);
        },
        .run_user => {
            const tid = root.startUserProgram(.hello) catch {
                note("a user program is already running");
                return;
            };
            noteNumber("user thread ", tid);
        },
        .quit => leave(),
    }
}

/// Consume input. Returns true when something happened, so the caller knows
/// whether to keep the CPU or hand it over.
pub fn poll() bool {
    if (!has_framebuffer) return false;
    if (!active_now) return false;
    var busy = false;

    while (hal.readKey()) |key| {
        busy = true;
        // Escape leaves; the shell is still there underneath.
        if (key == 27 or key == 'q') {
            leave();
            return true;
        }
    }

    const dims = fb.dimensions();
    var moved = false;
    var pressed = false;

    while (hal.readPointer()) |event| {
        busy = true;
        if (event.dx != 0 or event.dy != 0) {
            const nx = @as(i64, cursor_x) + event.dx;
            const ny = @as(i64, cursor_y) + event.dy;
            cursor_x = @intCast(@max(0, @min(nx, @as(i64, dims.width) - cursor_w)));
            cursor_y = @intCast(@max(0, @min(ny, @as(i64, dims.height) - cursor_h)));
            moved = true;
        }
        const was_down = buttons_down & 1 != 0;
        buttons_down = event.buttons;
        if (!was_down and event.left()) pressed = true;
    }

    if (moved or pressed) {
        eraseCursor();
        const over = hitTest(cursor_x, cursor_y);
        if (over != hot) {
            hot = over;
            var i: usize = 0;
            while (i < button_count) : (i += 1) drawButton(i);
        }
        if (pressed) {
            if (over) |index| {
                perform(buttons[index].action);
                if (!active_now) return true;
                drawLog();
            }
        }
        drawCursor();
    }

    return busy;
}
