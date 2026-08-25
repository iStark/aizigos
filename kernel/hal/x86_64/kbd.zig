//! PS/2 keyboard (i8042), scan code set 1, with two layouts.
//!
//! Works both from the IRQ1 handler and by polling, so a shell stays usable
//! even when interrupt delivery is not yet trusted on a given machine.
//!
//! A system that answers in Russian has to let Russian be typed, so the driver
//! carries a second layout and a switch. Which combination switches it is a
//! setting, because everyone who has used two layouts has an opinion about it.

const io = @import("serial.zig");

const data_port: u16 = 0x60;
const status_port: u16 = 0x64;

pub const irq_line: u8 = 1;

pub const Layout = enum {
    english,
    russian,

    pub fn label(self: Layout) []const u8 {
        return switch (self) {
            .english => "EN",
            .russian => "RU",
        };
    }
};

/// The combinations people expect. Shift+Alt is the default because it is the
/// one Windows has used for thirty years.
pub const Switch = enum {
    shift_alt,
    shift_ctrl,
    ctrl_space,

    pub fn label(self: Switch) []const u8 {
        return switch (self) {
            .shift_alt => "shift+alt",
            .shift_ctrl => "shift+ctrl",
            .ctrl_space => "ctrl+space",
        };
    }
};

var layout: Layout = .english;
var switch_combo: Switch = .shift_alt;

pub fn currentLayout() Layout {
    return layout;
}

pub fn setLayout(next: Layout) void {
    layout = next;
}

pub fn currentSwitch() Switch {
    return switch_combo;
}

pub fn setSwitch(next: Switch) void {
    switch_combo = next;
}

pub fn toggleLayout() Layout {
    layout = if (layout == .english) .russian else .english;
    return layout;
}

const ring_size = 64;
var ring: [ring_size]u8 = @splat(0);
var head: usize = 0;
var tail: usize = 0;

var shift_down = false;
var ctrl_down = false;
var alt_down = false;
var caps_lock = false;
var extended = false;

fn push(c: u8) void {
    const next = (head + 1) % ring_size;
    if (next == tail) return; // full: drop, a human cannot outrun this
    ring[head] = c;
    head = next;
}

/// Russian letters are two bytes in UTF-8, so one key press becomes two bytes
/// in the ring and whoever reads it decodes as usual.
fn pushCodePoint(code: u21) void {
    if (code < 0x80) {
        push(@intCast(code));
        return;
    }
    push(@intCast(0xC0 | (code >> 6)));
    push(@intCast(0x80 | (code & 0x3F)));
}

/// Pop the next byte, or null when nothing has been typed.
pub fn getKey() ?u8 {
    poll();
    if (tail == head) return null;
    const c = ring[tail];
    tail = (tail + 1) % ring_size;
    return c;
}

pub fn hasKey() bool {
    poll();
    return tail != head;
}

/// Drain whatever the controller has ready. Safe to call with interrupts off.
pub fn poll() void {
    var guard: usize = 0;
    while (guard < 16) : (guard += 1) {
        const status = io.inb(status_port);
        if (status & 0x01 == 0) return; // output buffer empty
        if (status & 0x20 != 0) {
            _ = io.inb(data_port); // mouse byte, not ours
            continue;
        }
        handleScancode(io.inb(data_port));
    }
}

/// Called from the IRQ1 handler.
pub fn onIrq() void {
    const status = io.inb(status_port);
    if (status & 0x01 == 0) return;
    if (status & 0x20 != 0) return;
    handleScancode(io.inb(data_port));
}

/// Did this key press complete the layout switch?
fn isSwitchPress(make: u8) bool {
    return switch (switch_combo) {
        .shift_alt => (make == 0x38 and shift_down) or ((make == 0x2A or make == 0x36) and alt_down),
        .shift_ctrl => (make == 0x1D and shift_down) or ((make == 0x2A or make == 0x36) and ctrl_down),
        .ctrl_space => make == 0x39 and ctrl_down,
    };
}

fn handleScancode(code: u8) void {
    if (code == 0xE0) {
        extended = true;
        return;
    }
    const from_extension = extended;
    extended = false;

    const released = code & 0x80 != 0;
    const make = code & 0x7F;

    // Modifiers first: they change what every other key means, and the layout
    // switch is a combination of them.
    switch (make) {
        0x2A, 0x36 => {
            if (!released and isSwitchPress(make)) {
                _ = toggleLayout();
                return;
            }
            shift_down = !released;
            return;
        },
        0x1D => {
            if (!released and isSwitchPress(make)) {
                _ = toggleLayout();
                return;
            }
            ctrl_down = !released;
            return;
        },
        0x38 => {
            if (!released and isSwitchPress(make)) {
                _ = toggleLayout();
                return;
            }
            alt_down = !released;
            return;
        },
        0x3A => {
            if (!released) caps_lock = !caps_lock;
            return;
        },
        else => {},
    }

    if (released) return;
    // Arrows and the keypad's extended twins carry no character yet.
    if (from_extension) return;

    if (isSwitchPress(make)) {
        _ = toggleLayout();
        return;
    }
    // Control sequences are not text; swallow them rather than typing letters.
    if (ctrl_down or alt_down) return;

    const code_point = translate(make);
    if (code_point != 0) pushCodePoint(code_point);
}

fn translate(make: u8) u21 {
    if (make >= plain.len) return 0;

    if (layout == .russian) {
        const letter = russian[make];
        if (letter != 0) {
            const upper = shift_down != caps_lock;
            // The whole Cyrillic block sits 0x20 below its capitals, except Ё.
            if (!upper) return letter;
            return if (letter == 0x451) 0x401 else letter - 0x20;
        }
        // Digits and punctuation keep their Latin meaning: a Russian layout
        // rearranges the symbol row too, and guessing at that would be worse
        // than leaving it alone.
    }

    var c: u21 = if (shift_down) shifted[make] else plain[make];
    if (caps_lock and c >= 'a' and c <= 'z' and !shift_down) c -= 32;
    if (caps_lock and c >= 'A' and c <= 'Z' and shift_down) c += 32;
    return c;
}

// Scan code set 1, make codes 0x00..0x58. 0 means "no character".
const plain = [_]u8{
    0, 0, '1', '2', '3', '4', '5', '6', // 0x00
    '7', '8', '9', '0', '-', '=', 8, '\t', // 0x08
    'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', // 0x10
    'o', 'p', '[', ']', '\n', 0, 'a', 's', // 0x18
    'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', // 0x20
    '\'', '`', 0, '\\', 'z', 'x', 'c', 'v', // 0x28
    'b', 'n', 'm', ',', '.', '/', 0, '*', // 0x30
    0, ' ', 0, 0, 0, 0, 0, 0, // 0x38
    0, 0, 0, 0, 0, 0, 0, '7', // 0x40
    '8', '9', '-', '4', '5', '6', '+', '1', // 0x48
    '2', '3', '0', '.', 0, 0, 0, 0, // 0x50
};

const shifted = [_]u8{
    0, 0, '!', '@', '#', '$', '%', '^', // 0x00
    '&', '*', '(', ')', '_', '+', 8, '\t', // 0x08
    'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', // 0x10
    'O', 'P', '{', '}', '\n', 0, 'A', 'S', // 0x18
    'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', // 0x20
    '"', '~', 0, '|', 'Z', 'X', 'C', 'V', // 0x28
    'B', 'N', 'M', '<', '>', '?', 0, '*', // 0x30
    0, ' ', 0, 0, 0, 0, 0, 0, // 0x38
    0, 0, 0, 0, 0, 0, 0, '7', // 0x40
    '8', '9', '-', '4', '5', '6', '+', '1', // 0x48
    '2', '3', '0', '.', 0, 0, 0, 0, // 0x50
};

/// ЙЦУКЕН, in the small letters; the capitals are computed from these.
const russian = [_]u21{
    0, 0, 0, 0, 0, 0, 0, 0, // 0x00
    0, 0, 0, 0, 0, 0, 0, 0, // 0x08
    0x0439, 0x0446, 0x0443, 0x043A, 0x0435, 0x043D, 0x0433, 0x0448, // й ц у к е н г ш
    0x0449, 0x0437, 0x0445, 0x044A, 0, 0, 0x0444, 0x044B, // щ з х ъ . . ф ы
    0x0432, 0x0430, 0x043F, 0x0440, 0x043E, 0x043B, 0x0434, 0x0436, // в а п р о л д ж
    0x044D, 0x0451, 0, 0, 0x044F, 0x0447, 0x0441, 0x043C, // э ё . . я ч с м
    0x0438, 0x0442, 0x044C, 0x0431, 0x044E, 0, 0, 0, // и т ь б ю
    0, 0, 0, 0, 0, 0, 0, 0, // 0x38
    0, 0, 0, 0, 0, 0, 0, 0, // 0x40
    0, 0, 0, 0, 0, 0, 0, 0, // 0x48
    0, 0, 0, 0, 0, 0, 0, 0, // 0x50
};

comptime {
    if (plain.len != shifted.len) @compileError("keymap tables must match in size");
    if (russian.len != plain.len) @compileError("the Russian layout must cover the same keys");
}

/// Flush anything the firmware left in the controller buffer.
pub fn init() void {
    var guard: usize = 0;
    while (io.inb(status_port) & 0x01 != 0 and guard < 32) : (guard += 1) {
        _ = io.inb(data_port);
    }
    head = 0;
    tail = 0;
    shift_down = false;
    ctrl_down = false;
    alt_down = false;
    caps_lock = false;
    extended = false;
}
