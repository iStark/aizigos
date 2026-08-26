//! The language the interface speaks.
//!
//! Until now it spoke both at once: an English greeting with a Russian line
//! under it, English panel headings, and answers in whichever language the
//! question happened to be asked in. That is fine for a demonstration and
//! wrong for a system — someone reading a screen is reading one language.
//!
//! So: one setting, two columns, and a lookup. The agent is the exception and
//! stays as it is, because answering a Russian question in English would be a
//! different kind of rudeness.
//!
//! Adding a language means adding a column, and the compiler will name every
//! string that is missing from it — which is the point of a table over a
//! scattering of `if` statements.

pub const Language = enum {
    english,
    russian,

    pub fn label(self: Language) []const u8 {
        return switch (self) {
            .english => "English",
            .russian => "Русский",
        };
    }

    /// The two-letter form the status bar has room for.
    pub fn short(self: Language) []const u8 {
        return switch (self) {
            .english => "EN",
            .russian => "RU",
        };
    }
};

var current: Language = .english;

pub fn language() Language {
    return current;
}

pub fn setLanguage(next: Language) void {
    current = next;
}

/// Everything the interface says. Keys are named for what they mean rather
/// than for the English words, so that a change of wording is a change in one
/// place.
pub const Key = enum {
    running,
    start_program,
    put_away,
    control,
    tasks,
    shell,
    thread_column,
    switches,
    background_rounds,
    settings,
    interface_language,
    keyboard_layout,
    screen_size,
    apply_needs_restart,

    cycle_power,
    grant_agent,
    revoke_agent,
    run_program,

    greeting,
    greeting_hint,
    desktop_ready,
    unknown_command,

    memory,
    free_of,
    uptime,
    profile,
    memory_short,
    uptime_short,
    tasks_short,
};

const Row = struct {
    english: []const u8,
    russian: []const u8,
};

const table = blk: {
    var rows: [@typeInfo(Key).@"enum".fields.len]Row = undefined;
    rows[@intFromEnum(Key.running)] = .{ .english = "running", .russian = "запущено" };
    rows[@intFromEnum(Key.start_program)] = .{ .english = "start", .russian = "запустить" };
    rows[@intFromEnum(Key.put_away)] = .{ .english = "put away", .russian = "свёрнуто" };
    rows[@intFromEnum(Key.control)] = .{ .english = "control", .russian = "управление" };
    rows[@intFromEnum(Key.tasks)] = .{ .english = "tasks", .russian = "задачи" };
    rows[@intFromEnum(Key.shell)] = .{ .english = "shell", .russian = "оболочка" };
    rows[@intFromEnum(Key.thread_column)] = .{
        .english = "thread      cls  cpu",
        .russian = "поток       кл   цпу",
    };
    rows[@intFromEnum(Key.switches)] = .{ .english = "switches ", .russian = "переключений " };
    rows[@intFromEnum(Key.background_rounds)] = .{ .english = "bg rounds ", .russian = "фон циклов " };
    rows[@intFromEnum(Key.settings)] = .{ .english = "settings", .russian = "настройки" };
    rows[@intFromEnum(Key.interface_language)] = .{ .english = "language", .russian = "язык" };
    rows[@intFromEnum(Key.keyboard_layout)] = .{ .english = "layout", .russian = "раскладка" };
    rows[@intFromEnum(Key.screen_size)] = .{ .english = "screen", .russian = "экран" };
    rows[@intFromEnum(Key.apply_needs_restart)] = .{
        .english = "applies at the next start",
        .russian = "применится при следующем запуске",
    };

    rows[@intFromEnum(Key.cycle_power)] = .{
        .english = "cycle power profile",
        .russian = "сменить энергопрофиль",
    };
    rows[@intFromEnum(Key.grant_agent)] = .{
        .english = "grant agent 10 min",
        .russian = "выдать агенту 10 мин",
    };
    rows[@intFromEnum(Key.revoke_agent)] = .{
        .english = "revoke agent tokens",
        .russian = "отозвать права агента",
    };
    rows[@intFromEnum(Key.run_program)] = .{
        .english = "run user program",
        .russian = "запустить программу",
    };

    rows[@intFromEnum(Key.greeting)] = .{
        .english = "AIZigOS. Type 'help' for the commands, or just ask in plain words.",
        .russian = "AIZigOS. Наберите 'help' для списка команд или спросите словами.",
    };
    rows[@intFromEnum(Key.greeting_hint)] = .{
        .english = "For example: how much memory is free, what can you do.",
        .russian = "Например: сколько свободной памяти, что ты умеешь.",
    };
    rows[@intFromEnum(Key.desktop_ready)] = .{
        .english = "desktop ready; this window is the shell",
        .russian = "рабочий стол готов; это окно и есть оболочка",
    };
    rows[@intFromEnum(Key.unknown_command)] = .{
        .english = "not understood",
        .russian = "не понял",
    };

    rows[@intFromEnum(Key.memory)] = .{ .english = "mem", .russian = "память" };
    rows[@intFromEnum(Key.free_of)] = .{ .english = "free of", .russian = "свободно из" };
    rows[@intFromEnum(Key.uptime)] = .{ .english = "up", .russian = "время" };
    rows[@intFromEnum(Key.profile)] = .{ .english = "profile", .russian = "профиль" };
    rows[@intFromEnum(Key.memory_short)] = .{ .english = "mem", .russian = "память" };
    rows[@intFromEnum(Key.uptime_short)] = .{ .english = "up", .russian = "время" };
    rows[@intFromEnum(Key.tasks_short)] = .{ .english = "tasks", .russian = "задач" };
    break :blk rows;
};

/// The text for a key, in the language the interface is set to.
pub fn t(key: Key) []const u8 {
    const row = table[@intFromEnum(key)];
    return switch (current) {
        .english => row.english,
        .russian => row.russian,
    };
}

const std = @import("std");
const testing = std.testing;

test "every key has both languages" {
    for (table) |row| {
        try testing.expect(row.english.len > 0);
        try testing.expect(row.russian.len > 0);
    }
}

test "the setting changes what the interface says" {
    const before = language();
    defer setLanguage(before);

    setLanguage(.english);
    try testing.expectEqualStrings("running", t(.running));
    setLanguage(.russian);
    try testing.expectEqualStrings("запущено", t(.running));
}
