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
const syscall = @import("syscall.zig");
const gui = @import("gui.zig");
const net = @import("net/net.zig");
const agent = @import("agent.zig");

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
                // Bytes above 0x7F are UTF-8 continuation: a question asked in
                // Russian is as valid as one asked in English.
                if (c < 32 or c == 127) return .ignored;
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

/// Output goes through klog so that whoever owns the screen — the text
/// console or the desktop's terminal window — receives it.
fn out(comptime fmt: []const u8, args: anytype) void {
    var line = klog.Line{};
    line.print(fmt, args);
    klog.raw(line.text());
    klog.raw("\n");
}

fn raw(text: []const u8) void {
    klog.raw(text);
}

// --- the shell itself -----------------------------------------------------

var editor: Editor = .{};

pub fn start() void {
    raw("\n");
    out("AIZigOS. Type 'help' for the commands, or just ask in plain words.", .{});
    out("Спрашивайте по-русски: сколько свободной памяти, что ты умеешь.", .{});
    raw(prompt);
}

/// Consume whatever has been typed. Returns false when nothing was pending,
/// which is the shell thread's cue to get out of the way.
pub fn poll() bool {
    var consumed = false;
    while (hal.readKey()) |c| {
        consumed = true;
        handleKey(c);
    }
    return consumed;
}

/// One typed character. The desktop calls this for its terminal window; the
/// text console calls it from `poll`.
pub fn handleKey(c: u8) void {
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
    if (eql(command, "sys")) return cmdSys();
    if (eql(command, "user")) return cmdUser(&words);
    if (eql(command, "gui")) return cmdGui();
    if (eql(command, "net")) return cmdNet();
    if (eql(command, "ping")) return cmdPing(&words);
    if (eql(command, "disk")) return cmdDisk();
    if (eql(command, "ls") or eql(command, "dir")) return cmdList(&words);
    if (eql(command, "cat") or eql(command, "type")) return cmdCat(&words);
    if (eql(command, "libc")) return cmdLibc();
    if (eql(command, "lang")) return cmdLang(&words);
    if (eql(command, "clear")) return cmdClear();
    if (eql(command, "echo")) return out("{s}", .{words.remainder()});

    // Section 5.0 asks for a chat rather than a command line, so anything that
    // is not a command is handed to the agent, which answers in the language
    // it was asked in. It is a phrase table today and says so.
    agent.handle(line);
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
    out("sys                   exercise the system call boundary", .{});
    out("user [hello|fault]    run a program in user mode, well behaved or not", .{});
    out("net                   network interface and stack counters", .{});
    out("ping <ip>             echo request, checked against a capability", .{});
    out("gui                   pointer-driven surface on the framebuffer", .{});
    out("disk                  the drive this kernel booted from", .{});
    out("ls [path]             list a directory on the boot volume", .{});
    out("cat <path>            print a file from the boot volume", .{});
    out("libc                  run the C library self test", .{});
    out("lang [en|ru|switch X] keyboard layout and how to switch it", .{});
    out("clear                 clear the screen", .{});
    out("", .{});
    out("Anything else is treated as a sentence: try \"how much memory is free\"", .{});
    out("or \"выдай агенту доступ на 5 минут\".", .{});
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
    if (@hasDecl(hal.impl, "onOwnPageTables")) {
        out("page tables: {s}", .{if (hal.impl.onOwnPageTables()) "the kernel's own" else "inherited from firmware"});
    }
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
    out("background work: {d} rounds completed by the indexer", .{root.indexer_rounds});
    out(" tid  class        prio  state     cpu(us)  stack  name", .{});
    for (&root.scheduler.tasks) |*t| {
        if (!t.used) continue;
        out(" {d}    {s}  {d}    {s}  {d}  {d}  {s}", .{
            t.tid,
            @tagName(t.class),
            t.prio,
            @tagName(t.state),
            t.cpu_ns / 1000,
            root.stackHighWater(t.tid),
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

/// Everything here goes through the trap instruction: `svc` on AArch64,
/// `int 0x80` on x86_64. The point is the last two lines, where a file access
/// is decided by a capability rather than by the caller being in the kernel.
fn cmdSys() void {
    const root = @import("root");

    const tid = syscall.invoke(.task_id, 0, 0, 0);
    const time_ns = syscall.invoke(.time_ns, 0, 0, 0);
    const records = syscall.invoke(.audit_len, 0, 0, 0);

    const message = "  write() reached the console through a trap\n";
    const written = syscall.invoke(.write, @intFromPtr(message.ptr), message.len, 0);

    out("task_id  -> {d}", .{tid});
    out("time_ns  -> {d} ms", .{time_ns / 1_000_000});
    out("audit    -> {d} records", .{records});
    out("write    -> {d} bytes", .{written});

    reportAccess("/home/user/Documents/report.md", root.shell_home_cap);
    reportAccess("/etc/shadow", root.shell_home_cap);
}

fn reportAccess(path: []const u8, token: cap.CapId) void {
    const result = syscall.invoke(
        .fs_access,
        token,
        @intFromPtr(path.ptr),
        syscall.packAccess(path.len, .{ .read = true }),
    );
    if (syscall.failed(result)) {
        out("fs_access {s} -> call failed", .{path});
        return;
    }
    const decision: cap.Decision = @enumFromInt(result);
    out("fs_access {s} -> {s}", .{ path, @tagName(decision) });
}

fn cmdUser(words: *Words) void {
    const root = @import("root");
    const user = @import("user.zig");
    var program: user.Program = .hello;
    if (words.next()) |arg| {
        if (eql(arg, "fault")) {
            program = .faulting;
        } else if (!eql(arg, "hello")) {
            out("usage: user [hello|fault]", .{});
            return;
        }
    }
    const tid = root.startUserProgram(program) catch |e| {
        out("could not start it: {s}", .{@errorName(e)});
        return;
    };
    out("thread {d} is dropping to user mode; watch the log", .{tid});
}

fn cmdNet() void {
    const root = @import("root");
    const mac = hal.netAddress() orelse {
        out("no network interface on this machine", .{});
        return;
    };
    out("mac      {x}:{x}:{x}:{x}:{x}:{x}", .{ mac[0], mac[1], mac[2], mac[3], mac[4], mac[5] });
    const config = root.net.config;
    out("address  {d}.{d}.{d}.{d}, gateway {d}.{d}.{d}.{d}", .{
        config.ip[0],      config.ip[1],      config.ip[2],      config.ip[3],
        config.gateway[0], config.gateway[1], config.gateway[2], config.gateway[3],
    });
    const stats = root.net.stats();
    out("frames   {d} in, {d} out, {d} dropped", .{ stats.received, stats.sent, stats.dropped });
    out("icmp     {d} sent, {d} answered", .{ stats.pings_sent, stats.pongs });
}

fn cmdPing(words: *Words) void {
    const root = @import("root");
    const arg = words.next() orelse {
        out("usage: ping <address>", .{});
        return;
    };
    const target = net.parseIp(arg) orelse {
        out("'{s}' is not an address", .{arg});
        return;
    };
    if (hal.netAddress() == null) {
        out("no network interface on this machine", .{});
        return;
    }

    // A socket is an object like any other: reaching the network needs a token
    // that says which hosts and ports are allowed (FR-2.1).
    const decision = root.registry.use(root.net_cap, root.shell_pid, .{
        .object = .{ .kind = .socket },
        .rights = .{ .send = true },
        .path = arg,
        .port = 0,
    }, hal.nowNs());
    if (!decision.ok()) {
        out("denied by the capability: {s}", .{@tagName(decision)});
        return;
    }

    out("pinging {s} ...", .{arg});
    if (root.ping(target)) |rtt| {
        out("reply from {s} in {d} us", .{ arg, rtt / 1000 });
    } else {
        out("no reply from {s}", .{arg});
    }
}

fn cmdGui() void {
    if (!gui.available()) {
        out("no framebuffer on this target; the shell is the interface here", .{});
        return;
    }
    if (gui.active()) {
        out("the desktop is already up", .{});
        return;
    }
    if (!gui.enter()) out("the framebuffer is too small for it", .{});
}

fn cmdLang(words: *Words) void {
    if (!@hasDecl(hal.impl, "kbd")) {
        out("this target has no keyboard of its own", .{});
        return;
    }
    const kbd = hal.impl.kbd;

    if (words.next()) |arg| {
        if (eql(arg, "en")) {
            kbd.setLayout(.english);
        } else if (eql(arg, "ru")) {
            kbd.setLayout(.russian);
        } else if (eql(arg, "switch")) {
            const combo = words.next() orelse {
                out("usage: lang switch shift-alt|shift-ctrl|ctrl-space", .{});
                return;
            };
            if (eql(combo, "shift-alt")) {
                kbd.setSwitch(.shift_alt);
            } else if (eql(combo, "shift-ctrl")) {
                kbd.setSwitch(.shift_ctrl);
            } else if (eql(combo, "ctrl-space")) {
                kbd.setSwitch(.ctrl_space);
            } else {
                out("unknown combination '{s}'", .{combo});
                return;
            }
        } else {
            out("usage: lang [en|ru|switch <combination>]", .{});
            return;
        }
    }

    out("layout: {s}, switched with {s}", .{
        kbd.currentLayout().label(),
        kbd.currentSwitch().label(),
    });
}

fn cmdDisk() void {
    const root = @import("root");
    if (!hal.diskPresent()) {
        out("no disk this kernel can read on this machine", .{});
        return;
    }
    if (@hasDecl(hal.impl, "ata")) {
        const ata = hal.impl.ata;
        out("drive: {s}", .{ata.modelName()});
        out("size : {d} sectors, {d} MiB", .{
            ata.sectorCount(),
            ata.sectorCount() * 512 / (1024 * 1024),
        });
    }
    if (root.boot_volume) |volume| {
        out("volume: FAT32 at LBA {d}", .{volume.partition_lba});
        out("       {d} clusters of {d} bytes, root at cluster {d}", .{
            volume.cluster_count,
            volume.bytes_per_cluster,
            volume.root_cluster,
        });
    } else {
        out("volume: nothing this kernel knows how to read", .{});
    }
}

/// Both listing and reading go through the kernel, which checks the token
/// first. The shell never touches the driver, so neither does anything that
/// drives the shell.
fn cmdList(words: *Words) void {
    const root = @import("root");
    const path = trimmed(words.remainder(), "/");

    var entries: [32]root.fat32.Entry = undefined;
    const count = root.fsList(path, &entries) catch |e| return fsComplaint(path, e);

    var files: usize = 0;
    var bytes: u64 = 0;
    for (entries[0..count]) |entry| {
        if (entry.is_dir) {
            out("  {s: <14} {s: >10}", .{ entry.text(), "<dir>" });
        } else {
            out("  {s: <14} {d: >10} bytes", .{ entry.text(), entry.size });
            files += 1;
            bytes += entry.size;
        }
    }
    out("{d} item(s), {d} file(s), {d} bytes", .{ count, files, bytes });
}

fn cmdCat(words: *Words) void {
    const root = @import("root");
    const path = trimmed(words.remainder(), "");
    if (path.len == 0) {
        out("usage: cat <path>   (try /README.TXT)", .{});
        return;
    }

    const file = root.fsStat(path) catch |e| return fsComplaint(path, e);
    if (file.is_dir) {
        out("{s} is a directory", .{path});
        return;
    }

    // A window at a time: printing a file must not depend on having room for
    // all of it, and the kernel keeps no buffer the size of a disk.
    var window: [512]u8 = undefined;
    var offset: u64 = 0;
    var printed: usize = 0;
    while (offset < file.size and printed < 16 * 1024) {
        const got = root.fsRead(path, offset, &window) catch |e| return fsComplaint(path, e);
        if (got == 0) break;
        raw(window[0..got]);
        offset += got;
        printed += got;
    }
    raw("\n");
    if (offset < file.size) out("... {d} more bytes", .{file.size - offset});
}

/// Say what went wrong in the words a person would use.
fn fsComplaint(path: []const u8, e: anyerror) void {
    const reason = switch (e) {
        error.NoDisk => "this machine has no readable disk",
        error.Denied => "the shell holds no capability for that path (FR-2.1)",
        error.NotFound => "no such file or directory",
        error.NotADirectory => "a component of that path is a file",
        error.IsADirectory => "that is a directory",
        error.BadName => "not a short name this volume can hold",
        error.NoRoom => "more entries than the listing buffer holds",
        error.ReadFailed => "the drive did not answer",
        else => "the volume is not one this kernel can read",
    };
    out("{s}: {s}", .{ path, reason });
}

/// The remainder of a command line, trimmed, or a default when it is empty.
fn trimmed(text: []const u8, fallback: []const u8) []const u8 {
    var from: usize = 0;
    var to: usize = text.len;
    while (from < to and text[from] == ' ') from += 1;
    while (to > from and (text[to - 1] == ' ' or text[to - 1] == '\r')) to -= 1;
    if (from == to) return fallback;
    return text[from..to];
}

fn cmdLibc() void {
    const root = @import("root");
    const libc = @import("libc_port.zig");
    const before = root.kernel_heap.stats();
    out("running C code compiled into this kernel...", .{});
    const failures = libc.aizigos_libc_selftest();
    const after = root.kernel_heap.stats();
    out("failures: {d}", .{failures});
    out("heap: {d} allocation(s), {d} free(s), {d} page(s) held", .{
        after.allocations - before.allocations,
        after.frees - before.frees,
        after.pages_held,
    });
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
