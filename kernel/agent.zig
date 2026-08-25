//! The natural language layer of the shell — the AI shell of section 5.0,
//! with the AI still missing.
//!
//! Today this is a rule-based recogniser: it matches phrases in Russian and
//! English against a table of intents and runs them. It is deliberately not
//! dressed up as understanding, and it says so when it fails.
//!
//! It exists in this shape so that Ascora can replace the recogniser without
//! touching anything else. The seam is `Intent`: the model's job will be to
//! turn a sentence into one of these, and the kernel's job stays what it is —
//! checking the capability, doing the work, writing the audit record. The
//! model proposes; the kernel disposes. That order matters, because a model
//! that could act directly would be a model that could bypass FR-2.1.

const hal = @import("hal/hal.zig");
const klog = @import("klog.zig");
const cap = @import("cap/cap.zig");
const power = @import("sched/power.zig");
const net = @import("net/net.zig");

/// Which recogniser turns text into intents.
pub const Backend = enum {
    /// Phrase tables, and honest about it.
    rules,
    /// Ascora Nano R1, once the weights, the tokenizer and the tensor runtime
    /// are in place. See docs/ASCORA.md for what that needs.
    ascora,
};

pub var backend: Backend = .rules;

pub const Language = enum { english, russian };

pub const Intent = union(enum) {
    show_memory,
    show_tasks,
    show_capabilities,
    show_network,
    set_power: power.Profile,
    grant_minutes: u64,
    revoke_agent,
    run_program,
    ping: net.Ip4,
    open_desktop,
    switch_layout,
    show_files,
    capabilities_of_the_shell,
    help,
    unknown,
};

// --- text handling ---------------------------------------------------------

/// Lowercase in place for ASCII and for the Russian alphabet, which lives in
/// two-byte UTF-8 sequences and cannot be shifted a byte at a time.
pub fn fold(text: []const u8, out: []u8) []const u8 {
    var length: usize = 0;
    var index: usize = 0;
    while (index < text.len and length + 2 <= out.len) {
        const c = text[index];
        if (c < 0x80) {
            out[length] = if (c >= 'A' and c <= 'Z') c + 32 else c;
            length += 1;
            index += 1;
            continue;
        }
        if (index + 1 >= text.len) break;
        const second = text[index + 1];
        // А..П is D0 90..9F, Р..Я is D0 A0..AF; а..п is D0 B0..BF and р..я is D1 80..8F.
        if (c == 0xD0 and second >= 0x90 and second <= 0x9F) {
            out[length] = 0xD0;
            out[length + 1] = second + 0x20;
        } else if (c == 0xD0 and second >= 0xA0 and second <= 0xAF) {
            out[length] = 0xD1;
            out[length + 1] = second - 0x20;
        } else if (c == 0xD0 and second == 0x81) {
            // Ё folds to е, which is what people type anyway.
            out[length] = 0xD0;
            out[length + 1] = 0xB5;
        } else {
            out[length] = c;
            out[length + 1] = second;
        }
        length += 2;
        index += 2;
    }
    return out[0..length];
}

pub fn languageOf(text: []const u8) Language {
    for (text) |c| {
        if (c == 0xD0 or c == 0xD1) return .russian;
    }
    return .english;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var i: usize = 0;
        while (i < needle.len and haystack[start + i] == needle[i]) : (i += 1) {}
        if (i == needle.len) return true;
    }
    return false;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (contains(haystack, needle)) return true;
    }
    return false;
}

fn firstNumber(text: []const u8) ?u64 {
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] < '0' or text[index] > '9') continue;
        var value: u64 = 0;
        while (index < text.len and text[index] >= '0' and text[index] <= '9') : (index += 1) {
            value = value * 10 + (text[index] - '0');
        }
        return value;
    }
    return null;
}

fn firstAddress(text: []const u8) ?net.Ip4 {
    var start: usize = 0;
    while (start < text.len) : (start += 1) {
        if (text[start] < '0' or text[start] > '9') continue;
        var end = start;
        while (end < text.len and (text[end] == '.' or (text[end] >= '0' and text[end] <= '9'))) : (end += 1) {}
        if (net.parseIp(text[start..end])) |address| return address;
        start = end;
    }
    return null;
}

// --- recognition -----------------------------------------------------------

// Russian words are matched by stem, because the endings change with case and
// a table of full forms would be a table of guesses.
const words_memory = [_][]const u8{ "memory", "ram", "mem ", "памят", "оператив" };
const words_tasks = [_][]const u8{ "task", "thread", "process", "задач", "поток", "процесс" };
const words_caps = [_][]const u8{ "capabilit", "token", "токен", "прав", "доступ" };
const words_network = [_][]const u8{ "network", "interface", "сет", "интерфейс" };
const words_power = [_][]const u8{ "power", "profile", "энерг", "питан", "профил" };
const words_grant = [_][]const u8{ "grant", "give", "allow", "выдай", "дай", "разреш" };
const words_revoke = [_][]const u8{ "revoke", "take away", "withdraw", "отзов", "отбер", "забер", "запрет" };
const words_run = [_][]const u8{ "run", "start", "launch", "запуст", "выполн" };
const words_ping = [_][]const u8{ "ping", "пинг", "достучись" };
const words_desktop = [_][]const u8{ "desktop", "window", "рабочий стол", "окн" };
const words_help = [_][]const u8{ "help", "what can you", "помощ", "что ты уме", "команд" };
const words_layout = [_][]const u8{ "layout", "keyboard", "язык", "раскладк", "клавиатур" };
const words_files = [_][]const u8{ "file", "disk", "folder", "directory", "файл", "диск", "папк", "каталог" };

const words_performance = [_][]const u8{ "performance", "fast", "производ", "быстр", "максим" };
const words_balanced = [_][]const u8{ "balanced", "normal", "баланс", "обычн" };
const words_saving = [_][]const u8{ "save", "saving", "economy", "эконом", "сберег" };
const words_critical = [_][]const u8{ "critical", "emergency", "критич", "аварий" };

/// Turn a sentence into an intent. This is the function Ascora replaces.
pub fn recognise(text: []const u8) Intent {
    var buffer: [256]u8 = undefined;
    const folded = fold(text, &buffer);

    if (containsAny(folded, &words_help)) return .help;

    if (containsAny(folded, &words_ping)) {
        if (firstAddress(folded)) |address| return .{ .ping = address };
        return .{ .ping = .{ 10, 0, 2, 2 } };
    }

    if (containsAny(folded, &words_power)) {
        if (containsAny(folded, &words_critical)) return .{ .set_power = .critical };
        if (containsAny(folded, &words_saving)) return .{ .set_power = .power_save };
        if (containsAny(folded, &words_balanced)) return .{ .set_power = .balanced };
        if (containsAny(folded, &words_performance)) return .{ .set_power = .performance };
    }

    if (containsAny(folded, &words_revoke)) return .revoke_agent;

    if (containsAny(folded, &words_grant)) {
        const minutes = firstNumber(folded) orelse 10;
        return .{ .grant_minutes = minutes };
    }

    if (containsAny(folded, &words_run)) return .run_program;
    if (containsAny(folded, &words_layout)) return .switch_layout;
    if (containsAny(folded, &words_files)) return .show_files;
    if (containsAny(folded, &words_desktop)) return .open_desktop;
    if (containsAny(folded, &words_memory)) return .show_memory;
    if (containsAny(folded, &words_tasks)) return .show_tasks;
    if (containsAny(folded, &words_network)) return .show_network;
    if (containsAny(folded, &words_caps)) return .show_capabilities;

    return .unknown;
}

// --- answering -------------------------------------------------------------

fn say(language: Language, english: []const u8, russian: []const u8) void {
    klog.raw(if (language == .russian) russian else english);
    klog.raw("\n");
}

fn sayNumber(language: Language, english: []const u8, russian: []const u8, value: u64, tail: []const u8) void {
    var line = klog.Line{};
    line.str(if (language == .russian) russian else english);
    line.decimal(value);
    line.str(tail);
    klog.raw(line.text());
    klog.raw("\n");
}

/// Run an intent. Everything that touches an object goes through the same
/// capability checks the typed commands use — the sentence does not get a
/// shortcut just because it was phrased politely.
pub fn perform(intent: Intent, language: Language) void {
    const root = @import("root");
    switch (intent) {
        .help => {
            say(
                language,
                "I can talk about memory, tasks, capabilities and the network,",
                "Я умею рассказать о памяти, задачах, правах и сети,",
            );
            say(
                language,
                "switch the power profile, grant or revoke the agent's access,",
                "переключить энергопрофиль, выдать или отозвать доступ агента,",
            );
            say(
                language,
                "run a user program, ping an address and open the desktop.",
                "запустить программу, пингануть адрес и открыть рабочий стол.",
            );
            say(
                language,
                "This is a phrase table, not a model: Ascora is not here yet.",
                "Это таблица фраз, а не модель: Ascora ещё не подключена.",
            );
        },
        .show_memory => {
            const stats = root.frames.stats();
            sayNumber(
                language,
                "free memory: ",
                "свободно памяти: ",
                stats.free_frames * stats.page_size / 1024 / 1024,
                if (language == .russian) " МиБ" else " MiB",
            );
        },
        .show_tasks => {
            const stats = root.scheduler.stats();
            sayNumber(language, "runnable tasks: ", "готовых задач: ", stats.runnable, "");
            sayNumber(language, "context switches: ", "переключений контекста: ", stats.switches, "");
        },
        .show_capabilities => {
            sayNumber(language, "live tokens: ", "живых токенов: ", root.registry.count(), "");
            sayNumber(language, "audit records: ", "записей аудита: ", root.registry.log.count(), "");
        },
        .show_files => {
            if (root.boot_volume == null) {
                say(
                    language,
                    "this machine has no disk I can read",
                    "на этой машине нет диска, который я могу прочитать",
                );
                return;
            }
            var entries: [16]root.fat32.Entry = undefined;
            const count = root.fsList("/", &entries) catch {
                say(
                    language,
                    "the boot volume did not answer",
                    "загрузочный том не ответил",
                );
                return;
            };
            sayNumber(language, "items in the root: ", "элементов в корне: ", count, "");
            for (entries[0..count]) |entry| {
                var line = klog.Line{};
                line.str("  ");
                line.str(entry.text());
                if (entry.is_dir) {
                    line.str(if (language == .russian) " (папка)" else " (folder)");
                } else {
                    line.str(" ");
                    line.decimal(entry.size);
                    line.str(if (language == .russian) " байт" else " bytes");
                }
                klog.raw(line.text());
                klog.raw("\n");
            }
        },
        .show_network => {
            if (hal.netAddress() == null) {
                say(language, "there is no network interface here", "сетевого интерфейса тут нет");
                return;
            }
            const stats = root.net.stats();
            sayNumber(language, "frames received: ", "кадров принято: ", stats.received, "");
            sayNumber(language, "frames sent: ", "кадров отправлено: ", stats.sent, "");
        },
        .set_power => |profile| {
            root.scheduler.setManualProfile(profile);
            var line = klog.Line{};
            line.str(if (language == .russian) "энергопрофиль: " else "power profile: ");
            line.str(profile.label());
            klog.raw(line.text());
            klog.raw("\n");
        },
        .grant_minutes => |minutes| {
            const id = root.registry.derive(
                root.shell_home_cap,
                root.shell_pid,
                root.agent_pid,
                .{ .read = true, .list = true },
                .{ .fs = cap.Path.from("/home/user/Documents") },
                .{ .lifetime_ns = minutes * 60 * 1_000_000_000, .purpose = "asked for in words" },
                hal.nowNs(),
            ) catch {
                say(language, "the grant was refused", "в выдаче отказано");
                return;
            };
            sayNumber(language, "token issued: ", "выдан токен: ", id, "");
            sayNumber(
                language,
                "it lasts ",
                "он живёт ",
                minutes,
                if (language == .russian) " минут" else " minutes",
            );
        },
        .revoke_agent => {
            const count = root.registry.revokeAllOf(root.agent_pid, hal.nowNs());
            sayNumber(language, "tokens revoked: ", "отозвано токенов: ", count, "");
        },
        .run_program => {
            const tid = root.startUserProgram(.hello) catch {
                say(language, "one is already running", "одна уже выполняется");
                return;
            };
            sayNumber(language, "started thread ", "запущен поток ", tid, "");
        },
        .ping => |address| {
            if (hal.netAddress() == null) {
                say(language, "there is no network interface here", "сетевого интерфейса тут нет");
                return;
            }
            if (root.ping(address)) |rtt| {
                sayNumber(
                    language,
                    "answered in ",
                    "ответ за ",
                    rtt / 1000,
                    if (language == .russian) " мкс" else " us",
                );
            } else {
                say(language, "no answer", "ответа нет");
            }
        },
        .open_desktop => {
            const gui = @import("gui.zig");
            if (gui.active()) {
                say(language, "the desktop is already up", "рабочий стол уже открыт");
            } else if (!gui.enter()) {
                say(language, "there is no screen for it", "экрана под него нет");
            }
        },
        .switch_layout => {
            if (!@hasDecl(hal.impl, "kbd")) {
                say(language, "there is no keyboard here", "клавиатуры тут нет");
                return;
            }
            const next = hal.impl.kbd.toggleLayout();
            var line = klog.Line{};
            line.str(if (language == .russian) "раскладка: " else "layout: ");
            line.str(next.label());
            klog.raw(line.text());
            klog.raw("\n");
        },
        .capabilities_of_the_shell => {},
        .unknown => {
            say(
                language,
                "I did not understand that. This is a phrase table, not a model yet.",
                "Не понял. Пока это таблица фраз, а не модель.",
            );
            say(
                language,
                "Ask for help, or type a command.",
                "Спроси «что умеешь» или набери команду.",
            );
        },
    }
}

/// The whole path: sentence in, action out.
pub fn handle(text: []const u8) void {
    const language = languageOf(text);
    const intent = recognise(text);
    perform(intent, language);
}

// --- tests -----------------------------------------------------------------

const testing = @import("std").testing;

test "agent: folding lowercases both alphabets" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("hello world", fold("Hello World", &buffer));
    try testing.expectEqualStrings("привет", fold("ПРИВЕТ", &buffer));
    try testing.expectEqualStrings("память", fold("Память", &buffer));
}

test "agent: the language of a sentence decides the language of the answer" {
    try testing.expectEqual(Language.english, languageOf("how much memory"));
    try testing.expectEqual(Language.russian, languageOf("сколько памяти"));
}

test "agent: memory is recognised in both languages" {
    try testing.expectEqual(Intent.show_memory, recognise("how much memory is free?"));
    try testing.expectEqual(Intent.show_memory, recognise("сколько свободной памяти"));
    try testing.expectEqual(Intent.show_memory, recognise("ПАМЯТЬ"));
}

test "agent: tasks, capabilities and the network are told apart" {
    try testing.expectEqual(Intent.show_tasks, recognise("show me the tasks"));
    try testing.expectEqual(Intent.show_tasks, recognise("какие процессы работают"));
    try testing.expectEqual(Intent.show_capabilities, recognise("какие права выданы"));
    try testing.expectEqual(Intent.show_network, recognise("network status"));
}

test "agent: power profiles are picked out of a sentence" {
    try testing.expectEqual(Intent{ .set_power = .critical }, recognise("switch the power profile to critical"));
    try testing.expectEqual(Intent{ .set_power = .power_save }, recognise("переключи энергопрофиль в экономию"));
    try testing.expectEqual(Intent{ .set_power = .performance }, recognise("power profile: maximum performance"));
}

test "agent: a grant carries its duration" {
    try testing.expectEqual(Intent{ .grant_minutes = 15 }, recognise("give the agent access for 15 minutes"));
    try testing.expectEqual(Intent{ .grant_minutes = 5 }, recognise("выдай агенту доступ на 5 минут"));
    // No number means the default.
    try testing.expectEqual(Intent{ .grant_minutes = 10 }, recognise("дай агенту доступ"));
}

test "agent: revoking wins over granting when both words appear" {
    try testing.expectEqual(Intent.revoke_agent, recognise("отзови у агента доступ, который выдал"));
    try testing.expectEqual(Intent.revoke_agent, recognise("revoke the access you granted"));
}

test "agent: an address is found inside a sentence" {
    try testing.expectEqual(Intent{ .ping = .{ 10, 0, 2, 2 } }, recognise("ping 10.0.2.2 please"));
    try testing.expectEqual(Intent{ .ping = .{ 8, 8, 8, 8 } }, recognise("пингани 8.8.8.8"));
    // Without one, the gateway is the obvious default.
    try testing.expectEqual(Intent{ .ping = .{ 10, 0, 2, 2 } }, recognise("ping the gateway"));
}

test "agent: nonsense is admitted rather than guessed at" {
    try testing.expectEqual(Intent.unknown, recognise("write me a poem about frogs"));
    try testing.expectEqual(Intent.unknown, recognise("напиши стихотворение про лягушек"));
}

test "agent: asking what it can do is understood in both languages" {
    try testing.expectEqual(Intent.help, recognise("what can you do?"));
    try testing.expectEqual(Intent.help, recognise("что ты умеешь"));
}

test "agent: files and disks are asked about in both languages" {
    try testing.expectEqual(Intent.show_files, recognise("what files are on the disk?"));
    try testing.expectEqual(Intent.show_files, recognise("show me the folders"));
    try testing.expectEqual(Intent.show_files, recognise("какие файлы на диске"));
    try testing.expectEqual(Intent.show_files, recognise("покажи каталоги"));
}
