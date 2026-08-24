//! Power profiles and the governor (the second half of FR-1.1).
//!
//! A profile gives the scheduler its quantum, the permitted task classes and
//! the DVFS level. `critical` is the emergency profile: on a flat battery or
//! overheating, only realtime and interactive tasks remain.

const std = @import("std");
const hal_types = @import("../hal/types.zig");

pub const Profile = enum(u8) {
    performance,
    balanced,
    power_save,
    /// The power emergency mode.
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
    /// Base scheduling quantum.
    quantum_ns: u64,
    /// CPU performance level, forwarded to the HAL.
    perf_level: hal_types.PerfLevel,
    /// Whether idling goes into deep sleep.
    deep_idle: bool,
    /// Whether background tasks may run.
    allow_background: bool,
    /// Whether ordinary (non-interactive) tasks may run.
    allow_normal: bool,
    /// How much an interactive task is boosted after waking.
    interactive_boost: u8,
    /// How often starving tasks get their priority raised.
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

/// The sensor readings the governor decides on.
pub const Sensors = struct {
    on_ac: bool = true,
    battery_present: bool = false,
    battery_pct: u8 = 100,
    /// Temperature of the hottest sensor.
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
    /// A manual choice overrides the automation, except in an emergency.
    manual: ?Profile = null,
    /// How many times the system entered the emergency profile (for the log).
    emergencies: u32 = 0,

    pub fn setManual(self: *Governor, profile: ?Profile) void {
        self.manual = profile;
    }

    /// Decide from the sensors, with hysteresis so the profile does not flap.
    pub fn update(self: *Governor, s: Sensors) Profile {
        const t = self.thresholds;
        const on_battery = !s.on_ac and s.battery_present;

        // Emergency conditions override the manual choice.
        const emergency = (on_battery and s.battery_pct <= t.battery_critical) or
            s.temp_c >= t.temp_emergency_c;
        if (emergency) {
            if (self.current != .critical) self.emergencies += 1;
            self.current = .critical;
            return self.current;
        }

        // Leaving the emergency needs headroom (hysteresis).
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

// --- tests ---------------------------------------------------------------

const testing = std.testing;

test "power: on AC it picks performance, on battery balanced" {
    var g = Governor{};
    try testing.expectEqual(Profile.performance, g.update(.{ .on_ac = true, .battery_present = true, .battery_pct = 80 }));
    try testing.expectEqual(Profile.balanced, g.update(.{ .on_ac = false, .battery_present = true, .battery_pct = 80 }));
}

test "power: a low charge switches to power-save, a critical one to emergency" {
    var g = Governor{};
    try testing.expectEqual(Profile.power_save, g.update(.{ .on_ac = false, .battery_present = true, .battery_pct = 20 }));
    try testing.expectEqual(Profile.critical, g.update(.{ .on_ac = false, .battery_present = true, .battery_pct = 5 }));
    try testing.expectEqual(@as(u32, 1), g.emergencies);
}

test "power: hysteresis keeps the profile from flapping" {
    var g = Governor{};
    _ = g.update(.{ .on_ac = false, .battery_present = true, .battery_pct = 5 });
    // 9% is above the entry threshold but below the exit one: stay in emergency.
    try testing.expectEqual(Profile.critical, g.update(.{ .on_ac = false, .battery_present = true, .battery_pct = 9 }));
    // 14% leaves the emergency, but the charge is still low.
    try testing.expectEqual(Profile.power_save, g.update(.{ .on_ac = false, .battery_present = true, .battery_pct = 14 }));
    // 28% is below the power-save exit threshold.
    try testing.expectEqual(Profile.power_save, g.update(.{ .on_ac = false, .battery_present = true, .battery_pct = 28 }));
    try testing.expectEqual(Profile.balanced, g.update(.{ .on_ac = false, .battery_present = true, .battery_pct = 35 }));
}

test "power: overheating drives power-save and then emergency" {
    var g = Governor{};
    try testing.expectEqual(Profile.power_save, g.update(.{ .on_ac = true, .temp_c = 88 }));
    try testing.expectEqual(Profile.critical, g.update(.{ .on_ac = true, .temp_c = 97 }));
    // Cooling to 80 does not yet leave the emergency (exit threshold is 75).
    try testing.expectEqual(Profile.critical, g.update(.{ .on_ac = true, .temp_c = 80 }));
    try testing.expectEqual(Profile.performance, g.update(.{ .on_ac = true, .temp_c = 60 }));
}

test "power: a manual choice overrides automation but not an emergency" {
    var g = Governor{};
    g.setManual(.power_save);
    try testing.expectEqual(Profile.power_save, g.update(.{ .on_ac = true, .temp_c = 40 }));
    try testing.expectEqual(Profile.critical, g.update(.{ .on_ac = false, .battery_present = true, .battery_pct = 3 }));
}

test "power: the emergency profile forbids background and normal tasks" {
    const t = tunables(.critical);
    try testing.expect(!t.allow_background);
    try testing.expect(!t.allow_normal);
    try testing.expectEqual(hal_types.perf_min, t.perf_level);
    try testing.expect(t.deep_idle);

    const p = tunables(.performance);
    try testing.expect(p.allow_background and p.allow_normal);
    try testing.expect(p.quantum_ns < tunables(.power_save).quantum_ns);
}
