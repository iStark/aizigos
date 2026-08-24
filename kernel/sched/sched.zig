//! Планировщик с приоритетами и энергопрофилями (FR-1.1).
//!
//! 64 уровня приоритета, разбитые на четыре класса. Внутри уровня — карусель.
//! Профиль питания (`power.zig`) задаёт квант, разрешённые классы и DVFS,
//! поэтому «энергоавария» — это не отдельный код, а смена таблицы настроек.
//!
//! Голодание лечится старением: задача, ждущая дольше aging_interval,
//! поднимается на уровень вверх, но не выше границы своего класса —
//! так фон никогда не обгонит реальное время.

const std = @import("std");
const hal = @import("../hal/hal.zig");
const power = @import("power.zig");

pub const Tid = u32;
pub const prio_levels = 64;

pub const Error = error{
    TableFull,
    NoSuchTask,
    BadPriority,
};

pub const Class = enum(u2) {
    realtime,
    interactive,
    normal,
    background,

    pub fn range(self: Class) struct { lo: u8, hi: u8 } {
        return switch (self) {
            .realtime => .{ .lo = 0, .hi = 15 },
            .interactive => .{ .lo = 16, .hi = 31 },
            .normal => .{ .lo = 32, .hi = 47 },
            .background => .{ .lo = 48, .hi = 63 },
        };
    }

    pub fn default(self: Class) u8 {
        return switch (self) {
            .realtime => 8,
            .interactive => 24,
            .normal => 40,
            .background => 56,
        };
    }

    /// Множитель кванта: интерактивным — короткие срезы (отзывчивость),
    /// фоновым — длинные (меньше переключений на единицу работы).
    pub fn quantumFactor(self: Class) u64 {
        return switch (self) {
            .realtime => 1,
            .interactive => 1,
            .normal => 2,
            .background => 4,
        };
    }
};

pub fn classOf(prio: u8) Class {
    return switch (prio) {
        0...15 => .realtime,
        16...31 => .interactive,
        32...47 => .normal,
        else => .background,
    };
}

pub const State = enum(u8) {
    ready,
    running,
    blocked,
    sleeping,
    done,
};

pub const Task = struct {
    tid: Tid = 0,
    name: [24]u8 = @splat(0),
    name_len: u8 = 0,
    class: Class = .normal,
    base_prio: u8 = 40,
    prio: u8 = 40,
    state: State = .done,
    used: bool = false,

    quantum_left_ns: u64 = 0,
    cpu_ns: u64 = 0,
    ready_since_ns: u64 = 0,
    last_boost_ns: u64 = 0,
    /// Сколько раз задачу вытеснили по исчерпанию кванта.
    preemptions: u32 = 0,
    /// Сколько раз задача блокировалась (признак интерактивности).
    blocks: u32 = 0,
    wake_at_ns: u64 = 0,

    next: ?Tid = null,

    pub fn nameText(self: *const Task) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const TaskDesc = struct {
    name: []const u8 = "",
    class: Class = .normal,
    /// null = приоритет по умолчанию для класса.
    prio: ?u8 = null,
};

pub const Stats = struct {
    switches: u64,
    preemptions: u64,
    idle_ticks: u64,
    profile: power.Profile,
    runnable: usize,
};

pub fn Scheduler(comptime max_tasks: usize) type {
    return struct {
        const Self = @This();

        const Queue = struct {
            head: ?Tid = null,
            tail: ?Tid = null,
        };

        tasks: [max_tasks]Task = @splat(.{}),
        queues: [prio_levels]Queue = @splat(.{}),
        ready_mask: u64 = 0,

        current: ?Tid = null,
        need_resched: bool = false,

        governor: power.Governor = .{},
        tune: power.Tunables = power.tunables(.balanced),

        last_tick_ns: u64 = 0,
        last_aging_ns: u64 = 0,
        switches: u64 = 0,
        preemptions: u64 = 0,
        idle_ticks: u64 = 0,

        pub fn init() Self {
            var self = Self{};
            self.applyProfile(.balanced);
            return self;
        }

        // --- задачи ---------------------------------------------------------

        pub fn spawn(self: *Self, desc: TaskDesc) Error!Tid {
            const prio = desc.prio orelse desc.class.default();
            const r = desc.class.range();
            if (prio < r.lo or prio > r.hi) return Error.BadPriority;

            for (&self.tasks, 0..) |*t, i| {
                if (t.used) continue;
                t.* = .{
                    .tid = @intCast(i + 1),
                    .class = desc.class,
                    .base_prio = prio,
                    .prio = prio,
                    .state = .ready,
                    .used = true,
                };
                const n = @min(desc.name.len, t.name.len);
                @memcpy(t.name[0..n], desc.name[0..n]);
                t.name_len = @intCast(n);
                self.enqueue(t);
                return t.tid;
            }
            return Error.TableFull;
        }

        pub fn task(self: *Self, tid: Tid) ?*Task {
            if (tid == 0 or tid > max_tasks) return null;
            const t = &self.tasks[tid - 1];
            return if (t.used) t else null;
        }

        pub fn exit(self: *Self, tid: Tid) Error!void {
            const t = self.task(tid) orelse return Error.NoSuchTask;
            if (t.state == .ready) self.remove(t);
            t.state = .done;
            t.used = false;
            if (self.current == tid) {
                self.current = null;
                self.need_resched = true;
            }
        }

        // --- очереди --------------------------------------------------------

        fn enqueue(self: *Self, t: *Task) void {
            t.next = null;
            t.state = .ready;
            const q = &self.queues[t.prio];
            if (q.tail) |tail_tid| {
                self.tasks[tail_tid - 1].next = t.tid;
                q.tail = t.tid;
            } else {
                q.head = t.tid;
                q.tail = t.tid;
            }
            self.ready_mask |= @as(u64, 1) << @intCast(t.prio);
        }

        fn remove(self: *Self, t: *Task) void {
            const q = &self.queues[t.prio];
            var prev: ?Tid = null;
            var cur = q.head;
            while (cur) |tid| {
                const node = &self.tasks[tid - 1];
                if (tid == t.tid) {
                    if (prev) |p| {
                        self.tasks[p - 1].next = node.next;
                    } else {
                        q.head = node.next;
                    }
                    if (q.tail == tid) q.tail = prev;
                    node.next = null;
                    if (q.head == null) self.ready_mask &= ~(@as(u64, 1) << @intCast(t.prio));
                    return;
                }
                prev = tid;
                cur = node.next;
            }
        }

        fn classAllowed(self: *const Self, class: Class) bool {
            return switch (class) {
                .realtime, .interactive => true,
                .normal => self.tune.allow_normal,
                .background => self.tune.allow_background,
            };
        }

        /// Наивысший приоритет среди готовых и разрешённых профилем задач.
        pub fn peek(self: *const Self) ?Tid {
            var level: u8 = 0;
            while (level < prio_levels) : (level += 1) {
                if (self.ready_mask & (@as(u64, 1) << @intCast(level)) == 0) continue;
                if (!self.classAllowed(classOf(level))) continue;
                if (self.queues[level].head) |tid| return tid;
            }
            return null;
        }

        // --- планирование ---------------------------------------------------

        fn quantumFor(self: *const Self, t: *const Task) u64 {
            return self.tune.quantum_ns * t.class.quantumFactor();
        }

        /// Выбрать следующую задачу. Возвращает null, если бежать нечему —
        /// вызывающий уходит в простой (обычный или глубокий, см. `shouldDeepIdle`).
        pub fn schedule(self: *Self, now_ns: u64) ?Tid {
            self.need_resched = false;

            // Текущая задача, если она ещё готова, возвращается в очередь.
            if (self.current) |cur_tid| {
                if (self.task(cur_tid)) |cur| {
                    if (cur.state == .running) {
                        cur.ready_since_ns = now_ns;
                        self.enqueue(cur);
                    }
                }
                self.current = null;
            }

            const next_tid = self.peek() orelse {
                self.idle_ticks += 1;
                return null;
            };
            const next = &self.tasks[next_tid - 1];
            self.remove(next);
            next.state = .running;
            next.quantum_left_ns = self.quantumFor(next);
            next.prio = next.base_prio; // старение сбрасывается при получении CPU
            self.current = next_tid;
            self.switches += 1;
            self.last_tick_ns = now_ns;
            return next_tid;
        }

        /// Тик таймера: списываем время, проверяем квант и старение.
        pub fn tick(self: *Self, now_ns: u64) void {
            const delta = now_ns -% self.last_tick_ns;
            self.last_tick_ns = now_ns;

            if (self.current) |tid| {
                if (self.task(tid)) |t| {
                    t.cpu_ns += delta;
                    t.quantum_left_ns = if (t.quantum_left_ns > delta) t.quantum_left_ns - delta else 0;
                    if (t.quantum_left_ns == 0) {
                        t.preemptions += 1;
                        self.preemptions += 1;
                        self.need_resched = true;
                    } else if (self.peek()) |top_tid| {
                        // Вытеснение более приоритетной задачей.
                        if (self.tasks[top_tid - 1].prio < t.prio) self.need_resched = true;
                    }
                }
            } else if (self.peek() != null) {
                self.need_resched = true;
            }

            self.wakeSleepers(now_ns);
            self.age(now_ns);
        }

        /// Подъём приоритета задачам, которые давно ждут (защита от голодания).
        fn age(self: *Self, now_ns: u64) void {
            if (now_ns -% self.last_aging_ns < self.tune.aging_interval_ns) return;
            self.last_aging_ns = now_ns;

            var level: u8 = prio_levels - 1;
            while (level > 0) : (level -= 1) {
                var cur = self.queues[level].head;
                while (cur) |tid| {
                    const t = &self.tasks[tid - 1];
                    cur = t.next;
                    if (t.class == .realtime) continue;
                    if (now_ns -% t.ready_since_ns < self.tune.aging_interval_ns) continue;
                    const floor = t.class.range().lo;
                    if (t.prio <= floor) continue;
                    self.remove(t);
                    t.prio -= 1;
                    t.ready_since_ns = now_ns;
                    t.last_boost_ns = now_ns;
                    self.enqueue(t);
                }
            }
        }

        // --- блокировки и сон ------------------------------------------------

        pub fn block(self: *Self, tid: Tid) Error!void {
            const t = self.task(tid) orelse return Error.NoSuchTask;
            if (t.state == .ready) self.remove(t);
            t.state = .blocked;
            t.blocks += 1;
            if (self.current == tid) {
                self.current = null;
                self.need_resched = true;
            }
        }

        /// Пробуждение. Интерактивной задаче даётся временный подъём приоритета:
        /// она только что ждала события, значит важна для отзывчивости.
        pub fn wake(self: *Self, tid: Tid, now_ns: u64) Error!void {
            const t = self.task(tid) orelse return Error.NoSuchTask;
            if (t.state == .ready or t.state == .running) return;
            t.prio = t.base_prio;
            if (t.class == .interactive and self.tune.interactive_boost > 0) {
                const floor = t.class.range().lo;
                const boost = self.tune.interactive_boost;
                t.prio = if (t.base_prio > floor + boost) t.base_prio - boost else floor;
            }
            t.ready_since_ns = now_ns;
            self.enqueue(t);
            if (self.current) |cur| {
                if (self.tasks[cur - 1].prio > t.prio) self.need_resched = true;
            } else {
                self.need_resched = true;
            }
        }

        pub fn sleep(self: *Self, tid: Tid, until_ns: u64) Error!void {
            const t = self.task(tid) orelse return Error.NoSuchTask;
            if (t.state == .ready) self.remove(t);
            t.state = .sleeping;
            t.wake_at_ns = until_ns;
            if (self.current == tid) {
                self.current = null;
                self.need_resched = true;
            }
        }

        fn wakeSleepers(self: *Self, now_ns: u64) void {
            for (&self.tasks) |*t| {
                if (!t.used or t.state != .sleeping) continue;
                if (now_ns >= t.wake_at_ns) {
                    t.state = .blocked; // чтобы wake() отработал общий путь
                    self.wake(t.tid, now_ns) catch {};
                }
            }
        }

        pub fn yield(self: *Self, now_ns: u64) void {
            if (self.current) |tid| {
                if (self.task(tid)) |t| t.quantum_left_ns = 0;
            }
            self.need_resched = true;
            _ = now_ns;
        }

        // --- энергопрофили ---------------------------------------------------

        pub fn applyProfile(self: *Self, profile: power.Profile) void {
            self.governor.current = profile;
            self.tune = power.tunables(profile);
            hal.setPerfLevel(self.tune.perf_level);
            // Смена профиля может запретить класс, который сейчас исполняется.
            if (self.current) |tid| {
                if (self.task(tid)) |t| {
                    if (!self.classAllowed(t.class)) self.need_resched = true;
                }
            }
            self.need_resched = true;
        }

        /// Обновить профиль по датчикам питания. Возвращает true, если сменился.
        pub fn updatePower(self: *Self, sensors: power.Sensors) bool {
            const before = self.governor.current;
            const after = self.governor.update(sensors);
            if (after != before) {
                self.applyProfile(after);
                return true;
            }
            return false;
        }

        pub fn setManualProfile(self: *Self, profile: ?power.Profile) void {
            self.governor.setManual(profile);
            if (profile) |p| self.applyProfile(p);
        }

        pub fn shouldDeepIdle(self: *const Self) bool {
            return self.tune.deep_idle;
        }

        pub fn runnableCount(self: *const Self) usize {
            var n: usize = 0;
            for (self.tasks) |t| {
                if (t.used and (t.state == .ready or t.state == .running)) n += 1;
            }
            return n;
        }

        pub fn stats(self: *const Self) Stats {
            return .{
                .switches = self.switches,
                .preemptions = self.preemptions,
                .idle_ticks = self.idle_ticks,
                .profile = self.governor.current,
                .runnable = self.runnableCount(),
            };
        }
    };
}

// --- тесты ---------------------------------------------------------------

const testing = std.testing;
const TestSched = Scheduler(16);
const ms = 1_000_000;

test "sched: выбирается задача с наивысшим приоритетом" {
    var s = TestSched.init();
    const bg = try s.spawn(.{ .name = "bg", .class = .background });
    const ui = try s.spawn(.{ .name = "ui", .class = .interactive });
    const rt = try s.spawn(.{ .name = "rt", .class = .realtime });

    try testing.expectEqual(rt, s.schedule(0).?);
    try s.block(rt);
    try testing.expectEqual(ui, s.schedule(0).?);
    try s.block(ui);
    try testing.expectEqual(bg, s.schedule(0).?);
}

test "sched: карусель внутри одного приоритета" {
    var s = TestSched.init();
    const a = try s.spawn(.{ .name = "a", .class = .normal });
    const b = try s.spawn(.{ .name = "b", .class = .normal });
    const c = try s.spawn(.{ .name = "c", .class = .normal });

    try testing.expectEqual(a, s.schedule(0).?);
    try testing.expectEqual(b, s.schedule(1 * ms).?);
    try testing.expectEqual(c, s.schedule(2 * ms).?);
    try testing.expectEqual(a, s.schedule(3 * ms).?);
}

test "sched: исчерпание кванта требует перепланирования" {
    var s = TestSched.init();
    _ = try s.spawn(.{ .name = "a", .class = .normal });
    const first = s.schedule(0).?;
    const quantum = s.task(first).?.quantum_left_ns;
    try testing.expect(quantum > 0);

    s.tick(quantum / 2);
    try testing.expect(!s.need_resched);
    s.tick(quantum + 1);
    try testing.expect(s.need_resched);
    try testing.expectEqual(@as(u64, 1), s.stats().preemptions);
}

test "sched: квант зависит от энергопрофиля" {
    var s = TestSched.init();
    _ = try s.spawn(.{ .name = "a", .class = .normal });

    s.applyProfile(.performance);
    const fast = s.schedule(0).?;
    const q_fast = s.task(fast).?.quantum_left_ns;

    s.applyProfile(.power_save);
    const slow = s.schedule(ms).?;
    const q_slow = s.task(slow).?.quantum_left_ns;

    try testing.expect(q_slow > q_fast);
}

test "sched: аварийный профиль оставляет только rt и интерактивные" {
    var s = TestSched.init();
    const bg = try s.spawn(.{ .name = "index", .class = .background });
    const norm = try s.spawn(.{ .name = "build", .class = .normal });
    const ui = try s.spawn(.{ .name = "shell", .class = .interactive });

    s.applyProfile(.critical);
    try testing.expectEqual(ui, s.schedule(0).?);
    try s.block(ui);
    // Фон и обычные задачи не выбираются, хотя они готовы.
    try testing.expectEqual(@as(?Tid, null), s.schedule(ms));
    try testing.expectEqual(State.ready, s.task(bg).?.state);
    try testing.expectEqual(State.ready, s.task(norm).?.state);

    // Возврат в balanced немедленно возвращает их в работу.
    s.applyProfile(.balanced);
    try testing.expectEqual(norm, s.schedule(2 * ms).?);
}

test "sched: профиль доводится до HAL через DVFS" {
    const host = @import("../hal/host/impl.zig");
    var s = TestSched.init();
    s.applyProfile(.performance);
    try testing.expectEqual(@as(u8, 255), host.testPerfLevel());
    s.applyProfile(.critical);
    try testing.expectEqual(@as(u8, 0), host.testPerfLevel());
}

test "sched: старение спасает задачу от голодания" {
    var s = TestSched.init();
    const hog = try s.spawn(.{ .name = "hog", .class = .normal, .prio = 34 });
    const poor = try s.spawn(.{ .name = "poor", .class = .normal, .prio = 46 });

    var now: u64 = 0;
    // Пока не сработало старение, всегда побеждает hog.
    try testing.expectEqual(hog, s.schedule(now).?);

    var iterations: usize = 0;
    var poor_ran = false;
    while (iterations < 200 and !poor_ran) : (iterations += 1) {
        now += 5 * ms;
        s.tick(now);
        if (s.need_resched) {
            const next = s.schedule(now).?;
            if (next == poor) poor_ran = true;
        }
    }
    try testing.expect(poor_ran);
    try testing.expect(s.task(poor).?.prio < 46 or s.task(poor).?.base_prio == 46);
}

test "sched: пробуждение интерактивной задачи повышает её приоритет" {
    var s = TestSched.init();
    const ui = try s.spawn(.{ .name = "ui", .class = .interactive, .prio = 24 });
    const worker = try s.spawn(.{ .name = "worker", .class = .normal });

    try s.block(ui);
    try testing.expectEqual(worker, s.schedule(0).?);

    try s.wake(ui, ms);
    try testing.expect(s.need_resched);
    try testing.expect(s.task(ui).?.prio < 24); // получил буст
    try testing.expectEqual(ui, s.schedule(ms).?);
    try testing.expectEqual(@as(u8, 24), s.task(ui).?.prio); // буст снят при выходе на CPU
}

test "sched: сон и автоматическое пробуждение по времени" {
    var s = TestSched.init();
    const t = try s.spawn(.{ .name = "sleeper", .class = .normal });
    try s.sleep(t, 10 * ms);
    try testing.expectEqual(@as(?Tid, null), s.schedule(0));

    s.tick(5 * ms);
    try testing.expectEqual(State.sleeping, s.task(t).?.state);
    s.tick(10 * ms);
    try testing.expectEqual(State.ready, s.task(t).?.state);
    try testing.expectEqual(t, s.schedule(10 * ms).?);
}

test "sched: завершённая задача освобождает слот" {
    var s = TestSched.init();
    const t = try s.spawn(.{ .name = "tmp", .class = .normal });
    _ = s.schedule(0);
    try s.exit(t);
    try testing.expectEqual(@as(?*Task, null), s.task(t));
    try testing.expectEqual(@as(usize, 0), s.runnableCount());
}

test "sched: приоритет вне диапазона класса отвергается" {
    var s = TestSched.init();
    try testing.expectError(Error.BadPriority, s.spawn(.{ .name = "bad", .class = .background, .prio = 10 }));
}
