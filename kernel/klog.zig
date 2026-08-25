//! Kernel logging on top of the HAL console.
//!
//! Formatting is homegrown rather than `std.fmt`: the standard formatter drags
//! in Io infrastructure and tables worth hundreds of kilobytes of .rodata in
//! ReleaseSmall, which hits the kernel budget from FR-1.5 directly.
//! Supported specifiers: {s} (string), {d} (decimal), {x} (hexadecimal),
//! {c} (character), {b} (yes/no), and {{ for a literal brace.

const hal = @import("hal/hal.zig");

pub const Level = enum(u8) {
    err,
    warn,
    info,
    debug,

    fn tag(self: Level) []const u8 {
        return switch (self) {
            .err => "[err ] ",
            .warn => "[warn] ",
            .info => "[info] ",
            .debug => "[dbg ] ",
        };
    }
};

pub var min_level: Level = .info;

/// Where output goes when something other than the console owns the screen —
/// the desktop's terminal window, for instance. The console still gets a copy,
/// which on a real machine means the serial line keeps the full log.
pub var sink: ?*const fn ([]const u8) void = null;

const line_capacity = 256;

pub const Line = struct {
    buf: [line_capacity]u8 = undefined,
    len: usize = 0,
    truncated: bool = false,

    pub fn text(self: *const Line) []const u8 {
        return self.buf[0..self.len];
    }

    fn byte(self: *Line, c: u8) void {
        if (self.len == self.buf.len) {
            self.truncated = true;
            return;
        }
        self.buf[self.len] = c;
        self.len += 1;
    }

    pub fn str(self: *Line, s: []const u8) void {
        for (s) |c| self.byte(c);
    }

    pub fn decimal(self: *Line, n0: u64) void {
        var digits: [20]u8 = undefined;
        var n: usize = 0;
        var v = n0;
        if (v == 0) {
            self.byte('0');
            return;
        }
        while (v != 0) : (v /= 10) {
            digits[n] = '0' + @as(u8, @intCast(v % 10));
            n += 1;
        }
        while (n > 0) {
            n -= 1;
            self.byte(digits[n]);
        }
    }

    pub fn signed(self: *Line, n0: i64) void {
        if (n0 < 0) {
            self.byte('-');
            self.decimal(@intCast(-n0));
        } else {
            self.decimal(@intCast(n0));
        }
    }

    pub fn hex(self: *Line, n0: u64) void {
        const alphabet = "0123456789abcdef";
        if (n0 == 0) {
            self.byte('0');
            return;
        }
        var digits: [16]u8 = undefined;
        var n: usize = 0;
        var v = n0;
        while (v != 0) : (v >>= 4) {
            digits[n] = alphabet[@intCast(v & 0xF)];
            n += 1;
        }
        while (n > 0) {
            n -= 1;
            self.byte(digits[n]);
        }
    }

    /// Pad what was just written out to `width`. Left alignment appends
    /// spaces; right alignment shifts the text along and fills in front of it.
    /// A value wider than the column is left alone: a table with one long name
    /// in it is easier to read than a name with its end cut off.
    fn padTo(self: *Line, start: usize, width: usize, left: bool) void {
        const written = self.len - start;
        if (written >= width) return;
        const missing = @min(width - written, self.buf.len - self.len);
        if (missing == 0) {
            self.truncated = true;
            return;
        }
        if (left) {
            var n: usize = 0;
            while (n < missing) : (n += 1) self.byte(' ');
            return;
        }
        var at = self.len;
        while (at > start) : (at -= 1) self.buf[at + missing - 1] = self.buf[at - 1];
        var fill = start;
        while (fill < start + missing) : (fill += 1) self.buf[fill] = ' ';
        self.len += missing;
    }

    fn value(self: *Line, comptime spec: []const u8, arg: anytype) void {
        const layout = comptime parseSpec(spec);
        const start = self.len;
        self.render(layout.kind, arg);
        if (layout.width > 0) self.padTo(start, layout.width, layout.left);
    }

    fn render(self: *Line, comptime spec: []const u8, arg: anytype) void {
        const T = @TypeOf(arg);
        const type_info = @typeInfo(T);
        if (comptime eq(spec, "s")) {
            self.str(arg);
        } else if (comptime eq(spec, "c")) {
            self.byte(arg);
        } else if (comptime eq(spec, "b")) {
            self.str(if (arg) "yes" else "no");
        } else if (comptime eq(spec, "x")) {
            self.hex(@intCast(arg));
        } else switch (type_info) {
            .int, .comptime_int => {
                if (arg < 0) self.signed(@intCast(arg)) else self.decimal(@intCast(arg));
            },
            .bool => self.str(if (arg) "yes" else "no"),
            .@"enum" => self.str(@tagName(arg)),
            .pointer => self.str(arg),
            else => self.str("?"),
        }
    }

    pub fn print(self: *Line, comptime fmt: []const u8, args: anytype) void {
        comptime var arg_index: usize = 0;
        comptime var i: usize = 0;
        inline while (i < fmt.len) {
            if (fmt[i] == '{') {
                if (i + 1 < fmt.len and fmt[i + 1] == '{') {
                    self.byte('{');
                    i += 2;
                    continue;
                }
                const close = comptime closeBrace(fmt, i);
                const spec = fmt[i + 1 .. close];
                self.value(spec, args[arg_index]);
                arg_index += 1;
                i = close + 1;
            } else if (fmt[i] == '}' and i + 1 < fmt.len and fmt[i + 1] == '}') {
                self.byte('}');
                i += 2;
            } else {
                self.byte(fmt[i]);
                i += 1;
            }
        }
        if (arg_index != args.len) @compileError("klog: argument count does not match the format string");
    }
};

/// A column in a table: what to print, how wide, and which side the spaces go.
const Layout = struct {
    kind: []const u8,
    width: usize = 0,
    left: bool = true,
};

/// Understands the part of Zig's format syntax this kernel actually uses:
/// "{s}", "{d}", and a width with an alignment, as in "{s:<14}" or "{d:>6}".
/// Anything else is a mistake in the format string and says so at compile time
/// rather than printing something surprising at three in the morning.
fn parseSpec(comptime spec: []const u8) Layout {
    comptime var colon: usize = spec.len;
    inline for (spec, 0..) |c, i| {
        if (c == ':') {
            colon = i;
            break;
        }
    }
    if (colon == spec.len) return .{ .kind = spec };

    comptime var rest: []const u8 = spec[colon + 1 ..];
    // An explicit fill character is allowed as long as it is a space: this
    // formatter writes into a fixed line and has no use for decorated columns.
    if (rest.len > 1 and (rest[1] == '<' or rest[1] == '>' or rest[1] == '^')) {
        if (rest[0] != ' ') @compileError("klog: only a space fill is supported");
        rest = rest[1..];
    }
    if (rest.len == 0) @compileError("klog: a format spec with ':' needs an alignment");

    const left = switch (rest[0]) {
        '<' => true,
        '>' => false,
        else => @compileError("klog: alignment must be '<' or '>'"),
    };
    comptime var width: usize = 0;
    inline for (rest[1..]) |c| {
        if (c < '0' or c > '9') @compileError("klog: width must be a number");
        width = width * 10 + (c - '0');
    }
    if (width == 0) @compileError("klog: a column needs a width");
    return .{ .kind = spec[0..colon], .width = width, .left = left };
}

fn eq(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn closeBrace(comptime fmt: []const u8, comptime open: usize) usize {
    comptime var j = open + 1;
    inline while (j < fmt.len) : (j += 1) {
        if (fmt[j] == '}') return j;
    }
    @compileError("klog: unclosed brace in the format string");
}

pub fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) > @intFromEnum(min_level)) return;
    var line = Line{};
    line.print(fmt, args);

    const guard = hal.IrqGuard.acquire();
    defer guard.release();
    hal.consoleWrite(level.tag());
    hal.consoleWrite(line.text());
    if (line.truncated) hal.consoleWrite("...");
    hal.consoleWrite("\n");
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}
pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}

pub fn raw(text: []const u8) void {
    if (sink) |write| write(text);
    hal.consoleWrite(text);
}

// --- tests ---------------------------------------------------------------

const testing = @import("std").testing;

test "klog: substitutes strings, decimals and hexadecimals" {
    var line = Line{};
    line.print("{s}: {d} bytes at 0x{x}", .{ "kernel", @as(u64, 1234), @as(u64, 0x40080000) });
    try testing.expectEqualStrings("kernel: 1234 bytes at 0x40080000", line.text());
}

test "klog: brace escaping and boolean output" {
    var line = Line{};
    line.print("{{{b}}}", .{true});
    try testing.expectEqualStrings("{yes}", line.text());
}

test "klog: columns pad on the side the alignment asks for" {
    var line = Line{};
    line.print("[{s: <8}][{d: >6}]", .{ "efi", @as(u64, 42) });
    try testing.expectEqualStrings("[efi     ][    42]", line.text());
}

test "klog: a value wider than its column is printed whole" {
    var line = Line{};
    line.print("{s:<4}|", .{"BOOTX64.EFI"});
    try testing.expectEqualStrings("BOOTX64.EFI|", line.text());
}

test "klog: an overlong line is flagged and never corrupts memory" {
    var line = Line{};
    const long = "x" ** 400;
    line.str(long);
    try testing.expect(line.truncated);
    try testing.expectEqual(@as(usize, line_capacity), line.len);
}
