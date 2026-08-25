//! The interactive kernel shell: the system's first interface.
//!
//! It is deliberately shaped like the AI shell from section 5.0 — a prompt you
//! talk to, not a desktop — but there is no model behind it yet. What it does
//! have is direct access to the kernel it runs in: memory, tasks, power
//! profiles, capabilities and the audit log. Everything the shell shows is
//! read out of live kernel state, nothing is faked.

const hal = @import("hal/hal.zig");
const klog = @import("klog.zig");
const cap = @import("cap/cap.zig");
const sched = @import("sched/sched.zig");
const power = @import("sched/power.zig");

pub const prompt = "aizig> ";

// --- line editing (no kernel state, covered by tests) ---------------------

pub const Editor = struct {
    pub const capacity = 120;

    buf: [capacity]u8 = @splat(0),
    len: usize = 0,

    pub fn text(self: *const Editor) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn reset(self: *Editor) void {
        self.len = 0;
    }

    pub const Event = union(enum) {
        /// Nothing visible happened.
        ignored,
        /// The character was appended and should be echoed.
        echo: u8,
        /// A character was removed.
        erase,
        /// Enter was pressed; the line is ready.
        submit,
    };

    pub fn feed(self: *Editor, c: u8) Event {
        switch (c) {
            '\r', '\n' => return .submit,
            8, 127 => {
                if (self.len == 0) return .ignored;
                self.len -= 1;
                return .erase;
            },
            else => {
                if (c < 32 or c > 126) return .ignored;
                if (self.len == capacity) return .ignored;
                self.buf[self.len] = c;
                self.len += 1;
                return .{ .echo = c };
            },
        }
    }
};

/// Splits a command line on spaces without allocating.
pub const Words = struct {
    rest: []const u8,

    pub fn init(line: []const u8) Words {
        return .{ .rest = line };
    }

    pub fn next(self: *Words) ?[]const u8 {
        var from: usize = 0;
        while (from < self.rest.len and self.rest[from] == ' ') from += 1;
        if (from == self.rest.len) {
            self.rest = self.rest[from..];
            return null;
        }
        var to = from;
        while (to < self.rest.len and self.rest[to] != ' ') to += 1;
        const word = self.rest[from..to];
        self.rest = self.rest[to..];
        return word;
    }

    /// Everything that is left, with leading spaces trimmed.
    pub fn remainder(self: *Words) []const u8 {
        var from: usize = 0;
        while (from < self.rest.len and self.rest[from] == ' ') from += 1;
        return self.rest[from..];
    }
};

pub fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

pub fn parseUint(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var value: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
    }
    return value;
}

// --- output helpers -------------------------------------------------------

fn out(comptime fmt: []const u8, args: anytype) void {
    var line = klog.Line{};
    line.print(fmt, args);
    hal.consoleWrite(line.text());
    hal.consoleWrite("\n");
}

fn raw(text: []const u8) void {
    hal.consoleWrite(text);
}

// --- the shell itself -----------------------------------------------------

var editor: Editor = .{};

pub fn start() void {
    raw("\n");
    out("AIZigOS shell. Type 'help' for what this kernel can tell you.", .{});
    raw(prompt);
}

/// Called from the kernel idle loop: consumes whatever has been typed.
pub fn poll() void {
    while (hal.readKey()) |c| {
        switch (editor.feed(c)) {
            .ignored => {},
            .echo => |ch| raw(&[_]u8{ch}),
            .erase => raw(&[_]u8{ 8, ' ', 8 }),
            .submit => {
                raw("\n");
                const line = editor.text();
                editor.reset();
                execute(line);
                raw(prompt);
            },
        }
    }
}

fn execute(line: []const u8) void {
    var words = Words.init(line);
    const command = words.next() orelse return;

    if (eql(command, "help")) return cmdHelp();
    if (eql(command, "ver") or eql(command, "uname")) return cmdVersion();
    if (eql(command, "mem")) return cmdMemory();
    if (eql(command, "ps")) return cmdTasks();
    if (eql(command, "power")) return cmdPower(&words);
    if (eql(command, "caps")) return cmdCaps();
    if (eql(command, "grant")) return cmdGrant(&words);
    if (eql(command, "revoke")) return cmdRevoke(&words);
    if (eql(command, "audit")) return cmdAudit(&words);
    if (eql(command, "clear")) return cmdClear();
    if (eql(command, "echo")) return out("{s}", .{words.remainder()});

    // Section 5.0 calls for a chat, not a command line. Until an agent lives
    // here, say so plainly instead of pretending to understand.
    out("I only speak commands so far, not language: '{s}' is not one of them.", .{command});
    out("Try 'help'.", .{});
}

fn cmdHelp() void {
    out("help                  this list", .{});
    out("ver                   version, HAL target, uptime", .{});
    out("mem                   physical memory from the PMM", .{});
    out("ps                    tasks in the scheduler", .{});
    out("power [profile]       show or set performance|balanced|power-save|critical", .{});
    out("caps                  capability tokens the kernel has issued", .{});
    out("grant <minutes>       give the agent Documents access for a while (FR-2.2)", .{});
    out("revoke <id>           revoke a token and everything derived from it", .{});
    out("audit [n]             last n audit records (default 10)", .{});
    out("clear                 clear the screen", .{});
}

fn cmdVersion() void {
    const root = @import("root");
    out("AIZigOS {s}", .{root.version});
    out("HAL target: {s}, page size {d}", .{ hal.target_name, hal.page_size });
    out("uptime: {d} ms", .{hal.nowNs() / 1_000_000});
}

fn cmdMemory() void {
    const root = @import("root");
    const st = root.frames.stats();
    out("frames: {d} total, {d} free, {d} used ({d} KiB page)", .{
        st.total_frames,
        st.free_frames,
        st.used_frames,
        st.page_size / 1024,
    });
    out("memory: {d} KiB free of {d} KiB", .{
        st.free_frames * st.page_size / 1024,
        st.total_frames * st.page_size / 1024,
    });
    const map = hal.memoryMap();
    out("HAL reports {d} memory regions", .{map.len});
}

fn cmdTasks() void {
    const root = @import("root");
    const stats = root.scheduler.stats();
    out("profile {s}, quantum {d} us, {d} runnable, {d} switches, {d} preemptions", .{
        stats.profile.label(),
        root.scheduler.tune.quantum_ns / 1000,
        stats.runnable,
        stats.switches,
        stats.preemptions,
    });
    out(" tid  class        prio  state     cpu(us)  name", .{});
    for (root.scheduler.tasks) |t| {
        if (!t.used) continue;
        out(" {d}    {s}  {d}    {s}  {d}  {s}", .{
            t.tid,
            @tagName(t.class),
            t.prio,
            @tagName(t.state),
            t.cpu_ns / 1000,
            t.nameText(),
        });
    }
}

fn cmdPower(words: *Words) void {
    const root = @import("root");
    if (words.next()) |name| {
        const profile: ?power.Profile = if (eql(name, "performance"))
            .performance
        else if (eql(name, "balanced"))
            .balanced
        else if (eql(name, "power-save") or eql(name, "power_save"))
            .power_save
        else if (eql(name, "critical"))
            .critical
        else
            null;
        if (profile) |p| {
            root.scheduler.setManualProfile(p);
            out("power profile set to {s}", .{p.label()});
        } else {
            out("unknown profile '{s}'", .{name});
            return;
        }
    }
    const tune = root.scheduler.tune;
    out("profile {s}: quantum {d} us, dvfs {d}, background {b}, normal {b}, deep idle {b}", .{
        root.scheduler.governor.current.label(),
        tune.quantum_ns / 1000,
        tune.perf_level,
        tune.allow_background,
        tune.allow_normal,
        tune.deep_idle,
    });
}

fn rightsText(r: cap.Rights, buf: []u8) []const u8 {
    const flags = [_]struct { on: bool, c: u8 }{
        .{ .on = r.read, .c = 'r' },
        .{ .on = r.write, .c = 'w' },
        .{ .on = r.execute, .c = 'x' },
        .{ .on = r.list, .c = 'l' },
        .{ .on = r.create, .c = 'c' },
        .{ .on = r.delete, .c = 'd' },
        .{ .on = r.send, .c = 's' },
        .{ .on = r.recv, .c = 'v' },
        .{ .on = r.grant, .c = 'g' },
        .{ .on = r.revoke, .c = 'R' },
    };
    var n: usize = 0;
    for (flags) |f| {
        if (f.on and n < buf.len) {
            buf[n] = f.c;
            n += 1;
        }
    }
    if (n == 0 and buf.len > 0) {
        buf[0] = '-';
        n = 1;
    }
    return buf[0..n];
}

/// Takes a pointer on purpose: `Path.text` borrows from the path, so a
/// by-value switch capture would hand back a slice into a dead copy.
fn scopeText(scope: *const cap.Scope) []const u8 {
    return switch (scope.*) {
        .any => "*",
        .fs => |*p| p.text(),
        .net => |*n| n.host.text(),
        .device => |d| @tagName(d),
    };
}

fn cmdCaps() void {
    const root = @import("root");
    const now = hal.nowNs();
    out(" id  holder  rights      state    ttl(s)  scope / purpose", .{});
    for (&root.registry.slots) |*slot| {
        if (slot.*) |*c| {
            var rbuf: [12]u8 = undefined;
            const ttl: u64 = if (c.remainingNs(now)) |left| left / 1_000_000_000 else 0;
            out(" {d}   {d}      {s}  {s}  {d}   {s} / {s}", .{
                c.id,
                c.holder,
                rightsText(c.rights, &rbuf),
                @tagName(c.state),
                ttl,
                scopeText(&c.scope),
                c.purposeText(),
            });
        }
    }
}

fn cmdGrant(words: *Words) void {
    const root = @import("root");
    const minutes = if (words.next()) |arg| (parseUint(arg) orelse {
        out("usage: grant <minutes>", .{});
        return;
    }) else 10;

    const now = hal.nowNs();
    const id = root.registry.derive(
        root.shell_home_cap,
        root.shell_pid,
        root.agent_pid,
        .{ .read = true, .list = true },
        .{ .fs = cap.Path.from("/home/user/Documents") },
        .{ .lifetime_ns = minutes * 60 * 1_000_000_000, .purpose = "shell grant to agent" },
        now,
    ) catch |e| {
        out("grant refused: {s} (parent cap {d}, shell pid {d}, agent pid {d})", .{
            @errorName(e),
            root.shell_home_cap,
            root.shell_pid,
            root.agent_pid,
        });
        return;
    };
    out("token {d} issued to pid {d}: read+list on /home/user/Documents for {d} min", .{ id, root.agent_pid, minutes });
    out("(the audit log has it; 'revoke {d}' takes it back)", .{id});
}

fn cmdRevoke(words: *Words) void {
    const root = @import("root");
    const arg = words.next() orelse {
        out("usage: revoke <id>", .{});
        return;
    };
    const id = parseUint(arg) orelse {
        out("'{s}' is not a token id", .{arg});
        return;
    };
    const n = root.registry.revoke(id, hal.nowNs());
    if (n == 0) {
        out("no such live token: {d}", .{id});
    } else {
        out("revoked {d} token(s), derived ones included", .{n});
    }
}

fn cmdAudit(words: *Words) void {
    const root = @import("root");
    const want: usize = if (words.next()) |arg| @intCast(parseUint(arg) orelse 10) else 10;
    const log = &root.registry.log;
    const total = log.count();
    const show = if (want < total) want else total;
    out("audit: {d} records kept, {d} dropped", .{ total, log.dropped });
    var i = total - show;
    while (i < total) : (i += 1) {
        const e = log.at(i) orelse continue;
        out(" #{d} {s}/{s} cap {d} holder {d} at {d} ms  {s}", .{
            e.seq,
            @tagName(e.kind),
            @tagName(e.decision),
            e.cap,
            e.holder,
            e.ts_ns / 1_000_000,
            e.purposeText(),
        });
    }
}

fn cmdClear() void {
    if (@hasDecl(hal.impl, "fb")) {
        if (hal.impl.fb.ready()) {
            hal.impl.fb.clear();
            return;
        }
    }
    // Serial consoles get the ANSI equivalent.
    raw("\x1b[2J\x1b[H");
}

// --- tests ---------------------------------------------------------------

const testing = @import("std").testing;

test "shell: the editor collects a line and submits it" {
    var e = Editor{};
    for ("caps") |c| _ = e.feed(c);
    try testing.expectEqualStrings("caps", e.text());
    try testing.expectEqual(Editor.Event.submit, e.feed('\r'));
}

test "shell: backspace erases, control characters are ignored" {
    var e = Editor{};
    for ("abc") |c| _ = e.feed(c);
    try testing.expectEqual(Editor.Event.erase, e.feed(8));
    try testing.expectEqualStrings("ab", e.text());
    try testing.expectEqual(Editor.Event.ignored, e.feed(0));
    try testing.expectEqual(Editor.Event.ignored, e.feed(7));
    try testing.expectEqualStrings("ab", e.text());
}

test "shell: an empty line cannot be backspaced past its start" {
    var e = Editor{};
    try testing.expectEqual(Editor.Event.ignored, e.feed(8));
    try testing.expectEqual(@as(usize, 0), e.text().len);
}

test "shell: the editor refuses to overflow" {
    var e = Editor{};
    for (0..Editor.capacity + 20) |_| _ = e.feed('x');
    try testing.expectEqual(@as(usize, Editor.capacity), e.text().len);
}

test "shell: words split on spaces and keep a remainder" {
    var w = Words.init("grant  15 minutes please");
    try testing.expectEqualStrings("grant", w.next().?);
    try testing.expectEqualStrings("15", w.next().?);
    try testing.expectEqualStrings("minutes please", w.remainder());
    try testing.expectEqualStrings("minutes", w.next().?);
    try testing.expectEqualStrings("please", w.next().?);
    try testing.expectEqual(@as(?[]const u8, null), w.next());
}

test "shell: numbers parse, junk does not" {
    try testing.expectEqual(@as(?u64, 42), parseUint("42"));
    try testing.expectEqual(@as(?u64, null), parseUint("4x"));
    try testing.expectEqual(@as(?u64, null), parseUint(""));
}

test "shell: rights render as flags" {
    var buf: [12]u8 = undefined;
    try testing.expectEqualStrings("rlg", rightsText(.{ .read = true, .list = true, .grant = true }, &buf));
    try testing.expectEqualStrings("-", rightsText(.{}, &buf));
}

test "shell: scope renders the filesystem prefix" {
    const fs_scope = cap.Scope{ .fs = cap.Path.from("/home/user/Documents") };
    try testing.expectEqualStrings("/home/user/Documents", scopeText(&fs_scope));
    const any_scope: cap.Scope = .any;
    try testing.expectEqualStrings("*", scopeText(&any_scope));
}
