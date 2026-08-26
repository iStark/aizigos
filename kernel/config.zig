//! Settings as a file on the boot volume.
//!
//! They used to live in a UEFI variable, because the filesystem could only be
//! read. Now that it can be written to, they belong where settings belong: in
//! a file, in text, that a person can read with `cat` and fix with an editor
//! when the machine will not start far enough to fix them from inside.
//!
//! The screen is remembered as a size and not as a firmware mode number. Mode
//! numbers are an index into a list the firmware builds; a firmware update can
//! renumber them, and "1024x768" survives that where "mode 3" does not. It
//! also means something to whoever opens the file.
//!
//! One file, parsed leniently: an unknown key is skipped rather than treated
//! as damage, so a newer system's settings do not stop an older one booting.

const std = @import("std");
const fat32 = @import("fs/fat32.zig");

pub const path = "/AIZIGOS.CFG";

/// Room for the whole file. Settings that outgrow this want a different
/// format, not a bigger buffer.
pub const max_bytes = 512;

pub const Values = struct {
    /// 0 English, 1 Russian.
    language: u8 = 0,
    /// 0 by 0 means "whatever the firmware chose".
    screen_width: u32 = 0,
    screen_height: u32 = 0,

    pub const defaults = Values{};
};

/// Read `key=value` lines, ignoring blanks, comments and anything unknown.
pub fn parse(text: []const u8) Values {
    var values = Values.defaults;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        const split = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..split], " \t");
        const value = std.mem.trim(u8, line[split + 1 ..], " \t");

        if (std.mem.eql(u8, key, "language")) {
            values.language = if (std.mem.eql(u8, value, "ru")) 1 else 0;
        } else if (std.mem.eql(u8, key, "screen")) {
            const by = std.mem.indexOfScalar(u8, value, 'x') orelse continue;
            values.screen_width = parseNumber(value[0..by]) orelse 0;
            values.screen_height = parseNumber(value[by + 1 ..]) orelse 0;
        }
    }
    return values;
}

fn parseNumber(text: []const u8) ?u32 {
    if (text.len == 0 or text.len > 5) return null;
    var out: u32 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        out = out * 10 + (c - '0');
    }
    return out;
}

/// Write the file's text into `buffer` and return the part used. Written by
/// hand rather than through a formatter: this runs where there is no
/// allocator and the output has to be predictable.
pub fn render(values: Values, buffer: []u8) []u8 {
    var used: usize = 0;
    const put = struct {
        fn text(into: []u8, at: *usize, what: []const u8) void {
            const room = @min(what.len, into.len - at.*);
            @memcpy(into[at.* .. at.* + room], what[0..room]);
            at.* += room;
        }
        fn number(into: []u8, at: *usize, value: u32) void {
            var digits: [10]u8 = undefined;
            var count: usize = 0;
            var left = value;
            while (true) {
                digits[count] = '0' + @as(u8, @intCast(left % 10));
                count += 1;
                left /= 10;
                if (left == 0) break;
            }
            while (count > 0) {
                count -= 1;
                if (at.* < into.len) {
                    into[at.*] = digits[count];
                    at.* += 1;
                }
            }
        }
    };

    put.text(buffer, &used, "# AIZigOS settings. Edit by hand if you like.\n");
    put.text(buffer, &used, "language=");
    put.text(buffer, &used, if (values.language == 1) "ru" else "en");
    put.text(buffer, &used, "\n");
    if (values.screen_width != 0 and values.screen_height != 0) {
        put.text(buffer, &used, "screen=");
        put.number(buffer, &used, values.screen_width);
        put.text(buffer, &used, "x");
        put.number(buffer, &used, values.screen_height);
        put.text(buffer, &used, "\n");
    }
    return buffer[0..used];
}

/// Read the settings off a mounted volume. Anything that goes wrong — no file,
/// an unreadable one — means the defaults, because a machine that will not
/// start because its settings file is missing is a worse machine.
pub fn loadFrom(volume: *fat32.Volume) Values {
    const file = volume.open(path) catch return .defaults;
    if (file.is_dir) return .defaults;
    var buffer: [max_bytes]u8 = undefined;
    const got = volume.read(file, 0, &buffer) catch return .defaults;
    return parse(buffer[0..got]);
}

pub fn saveTo(volume: *fat32.Volume, values: Values) bool {
    var buffer: [max_bytes]u8 = undefined;
    const text = render(values, &buffer);
    volume.writeFile(path, text) catch return false;
    return true;
}

const testing = std.testing;

test "an empty file means the defaults" {
    const values = parse("");
    try testing.expectEqual(@as(u8, 0), values.language);
    try testing.expectEqual(@as(u32, 0), values.screen_width);
}

test "keys are read and unknown ones ignored" {
    const values = parse("# a comment\nlanguage = ru\nscreen=1024x768\nfuture=42\n");
    try testing.expectEqual(@as(u8, 1), values.language);
    try testing.expectEqual(@as(u32, 1024), values.screen_width);
    try testing.expectEqual(@as(u32, 768), values.screen_height);
}

test "what is written can be read back" {
    const original = Values{ .language = 1, .screen_width = 800, .screen_height = 600 };
    var buffer: [max_bytes]u8 = undefined;
    const values = parse(render(original, &buffer));
    try testing.expectEqual(original.language, values.language);
    try testing.expectEqual(original.screen_width, values.screen_width);
    try testing.expectEqual(original.screen_height, values.screen_height);
}

test "a damaged screen line does not take the language with it" {
    const values = parse("language=ru\nscreen=wide\n");
    try testing.expectEqual(@as(u8, 1), values.language);
    try testing.expectEqual(@as(u32, 0), values.screen_width);
}
