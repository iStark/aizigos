//! Энергетические профили и губернатор (FR-1.1, вторая половина).
//!
//! Профиль задаёт планировщику кванты, разрешённые классы задач и уровень DVFS.
//! `critical` — аварийный профиль: при разряде батареи или перегреве в системе
//! остаются только реального времени и интерактивные задачи.

const std = @import("std");
const hal_types = @import("../hal/types.zig");

pub const Profile = enum(u8) {
    performance,
    balanced,
    power_save,
    /// Энергоаварийный режим.
    critical,

    pub fn label(self: Profile) []const u8 {
        return switch (self) {
            .performance => "performance",
            .balanced => "balanced",
            .power_save => "power-save",
            .critical => "critical",
        };
    }
};

pub const Tunables = struct {
    /// Базовый квант планирования.
    quantum_ns: u64,
    /// Уровень производительности CPU, передаётся в HAL.
    perf_level: hal_types.PerfLevel,
    /// Уходить ли в глубокий сон при простое.
    deep_idle: bool,
    /// Разрешено ли исполнять фоновые задачи.
    allow_background: bool,
    /// Разрешены ли обычные (не интерактивные) задачи.
    allow_normal: bool,
    /// Насколько повышается приоритет интерактивных задач после пробуждения.
    interactive_boost: u8,
    /// Как часто поднимать приоритет голодающим задачам.
    aging_interval_ns: u64,
};

const ms = 1_000_000;

pub fn tunables(profile: Profile) Tunables {
    return switch (profile) {
        .performance => .{
            .quantum_ns = 2 * ms,
            .perf_level = hal_types.perf_max,
            .deep_idle = false,
            .allow_background = true,
            .allow_normal = true,
            .interactive_boost = 4,
            .aging_interval_ns = 20 * ms,
        },
        .balanced => .{
            .quantum_ns = 5 * ms,
            .perf_level = hal_types.perf_nominal,
            .deep_idle = true,
            .allow_background = true,
            .allow_normal = true,
            .interactive_boost = 2,
            .aging_interval_ns = 50 * ms,
        },
        .power_save => .{
            .quantum_ns = 12 * ms,
            .perf_level = 64,
            .deep_idle = true,
            .allow_background = false,
            .allow_normal = true,
            .interactive_boost = 1,
            .aging_interval_ns = 120 * ms,
        },
        .critical => .{
            .quantum_ns = 20 * ms,
            .perf_level = hal_types.perf_min,
            .deep_idle = true,
            .allow_background = false,
            .allow_normal = false,
            .interactive_boost = 0,
            .aging_interval_ns = 250 * ms,
        },
    };
}

/// Показания датчиков, на основании которых губернатор принимает решение.
pub const Sensors = struct {
    on_ac: bool = true,
    battery_present: bool = false,
    battery_pct: u8 = 100,
    /// Температура самого горячего датчика.
    temp_c: i16 = 40,
};

pub const Thresholds = struct {
    battery_critical: u8 = 7,
    battery_critical_exit: u8 = 12,
    battery_low: u8 = 25,
    battery_low_exit: u8 = 30,
    temp_throttle_c: i16 = 85,
    temp_emergency_c: i16 = 95,
    temp_release_c: i16 = 75,
};

pub const Governor = struct {
    thresholds: Thresholds = .{},
    current: Profile = .balanced,
    /// Ручной выбор пользователя перекрывает автоматику, кроме аварии.
    manual: ?Profile = null,
    /// Сколько раз система входила в аварийный профиль (для журнала).
    emergencies: u32 = 0,

    pub fn setManual(self: *Governor, profile: ?Profile) void {
        self.manual = profile;
    }

    /// Решение по датчикам с гистерезисом, чтобы профиль не дребезжал.
    pub fn update(self: *Governor, s: Sensors) Profile {
        const t = self.thresholds;
        const on_battery = !s.on_ac and s.battery_present;

        // Аварийные условия перекрывают ручной выбор.
        const emergency = (on_battery and s.battery_pct <= t.battery_critical) or
            s.temp_c >= t.temp_emergency_c;
        if (emergency) {
            if (self.current != .critical) self.emergencies += 1;
            self.current = .critical;
            return self.current;
        }

        // Выход из аварии требует запаса (гистерезис).
        if (self.current == .critical) {
            const battery_ok = !on_battery or s.battery_pct >= t.battery_critical_exit;
            const temp_ok = s.temp_c <= t.temp_release_c;
            if (!battery_ok or !temp_ok) return self.current;
        }

        if (self.manual) |m| {
            self.current = m;
            return m;
        }

        const want_low = (on_battery and s.battery_pct <= t.battery_low) or s.temp_c >= t.temp_throttle_c;
        if (want_low) {
            self.current = .power_save;
            return self.current;
        }

        if (self.current == .power_save) {
            const battery_ok = !on_battery or s.battery_pct >= t.battery_low_exit;
            const temp_ok = s.temp_c < t.temp_throttle_c;
            if (!battery_ok or !temp_ok) return self.current;
        }

        self.current = if (s.on_ac and s.temp_c < t.temp_throttle_c) .performance else .balanced;
        return self.current;
    }

    pub fn currentTunables(self: *const Governor) Tunables {
        return tunables(self.current);
    }
};

// --- тесты ---------------------------------------------------------------

const testing = std.testing;

test "power: на сети выбирается performance, на батарее — balanced" {
    var g = Governor{};
    try testing.expectEqual(Profile.performance, g.update(.{ .on_ac = true, .battery_present = true, .battery_pct = 80 }));
    try testing.expectEqual(Profile.balanced, g.update(.{ .on_ac = false, .battery_present = true, .battery_pct = 80 }));
}

test "power: низкий заряд включает power-save, критический — аварию" {
    var g = Governor{};
    try testing.expectEqual(Profile.power_save, g.update(.{ .on_ac = false, .battery_present = true, .battery_pct = 20 }));
    try testing.expectEqual(Profile.critical, g.update(.{ .on_ac = false, .battery_present = true, .battery_pct = 5 }));
    try testing.expectEqual(@as(u32, 1), g.emergencies);
}

test "power: гистерезис не даёт профилю дребезжать" {
    var g = Governor{};
    _ = g.update(.{ .on_ac = false, .battery_present = true, .battery_pct = 5 });
    // 9% — выше порога входа, но ниже порога выхода: остаёмся в аварии.
    try testing.expectEqual(Profile.critical, g.update(.{ .on_ac = false, .battery_present = true, .battery_pct = 9 }));
    // 14% — вышли из аварии, но всё ещё мало заряда.
    try testing.expectEqual(Profile.power_save, g.update(.{ .on_ac = false, .battery_present = true, .battery_pct = 14 }));
    // 28% — ниже порога выхода из power-save.
    try testing.expectEqual(Profile.power_save, g.update(.{ .on_ac = false, .battery_present = true, .battery_pct = 28 }));
    try testing.expectEqual(Profile.balanced, g.update(.{ .on_ac = false, .battery_present = true, .battery_pct = 35 }));
}

test "power: перегрев уводит в power-save и в аварию" {
    var g = Governor{};
    try testing.expectEqual(Profile.power_save, g.update(.{ .on_ac = true, .temp_c = 88 }));
    try testing.expectEqual(Profile.critical, g.update(.{ .on_ac = true, .temp_c = 97 }));
    // Остывание до 80 ещё не выпускает из аварии (порог выхода 75).
    try testing.expectEqual(Profile.critical, g.update(.{ .on_ac = true, .temp_c = 80 }));
    try testing.expectEqual(Profile.performance, g.update(.{ .on_ac = true, .temp_c = 60 }));
}

test "power: ручной выбор перекрывает автоматику, но не аварию" {
    var g = Governor{};
    g.setManual(.power_save);
    try testing.expectEqual(Profile.power_save, g.update(.{ .on_ac = true, .temp_c = 40 }));
    try testing.expectEqual(Profile.critical, g.update(.{ .on_ac = false, .battery_present = true, .battery_pct = 3 }));
}

test "power: аварийный профиль запрещает фон и обычные задачи" {
    const t = tunables(.critical);
    try testing.expect(!t.allow_background);
    try testing.expect(!t.allow_normal);
    try testing.expectEqual(hal_types.perf_min, t.perf_level);
    try testing.expect(t.deep_idle);

    const p = tunables(.performance);
    try testing.expect(p.allow_background and p.allow_normal);
    try testing.expect(p.quantum_ns < tunables(.power_save).quantum_ns);
}
