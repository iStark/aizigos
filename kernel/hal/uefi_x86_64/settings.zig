//! Settings that outlive a boot, kept where the firmware keeps its own.
//!
//! There is nowhere else to put them. The filesystem is read only by design,
//! and a setting that is forgotten when the machine restarts is not a setting.
//! UEFI variables are the mechanism every machine with this firmware already
//! has, and unlike boot services, runtime services stay callable after the
//! handover — their code lives in memory this kernel marks reserved and never
//! reuses.
//!
//! One variable holds everything, because two would mean two chances to be
//! half-written.

const std = @import("std");
const uefi = std.os.uefi;

/// Our own namespace, so nothing here can collide with the firmware's or a
/// bootloader's variables.
const vendor = uefi.Guid{
    .time_low = 0xA1219052,
    .time_mid = 0x5A6C,
    .time_high_and_version = 0x4B31,
    .clock_seq_high_and_reserved = 0x9C,
    .clock_seq_low = 0x4D,
    .node = .{ 0x41, 0x49, 0x5A, 0x69, 0x67, 0x00 },
};

const name = std.unicode.utf8ToUtf16LeStringLiteral("AIZigOS");

/// What is remembered. Deliberately small and versioned: a struct that grows
/// has to be readable in its older shape, and a byte for the version is a
/// cheaper answer than a parser.
pub const Stored = extern struct {
    version: u8 = 1,
    /// 0 English, 1 Russian.
    language: u8 = 0,
    /// The GOP mode to ask for at the next start, or 0xFFFF for "whatever the
    /// firmware chose".
    screen_mode: u16 = 0xFFFF,

    pub const unset = Stored{};
};

/// Read the settings, or the defaults when there are none. A machine whose
/// firmware refuses to read variables gets the defaults and no complaint:
/// there is nothing the user could do about it.
pub fn load() Stored {
    const rs = uefi.system_table.runtime_services;
    var buffer: [@sizeOf(Stored)]u8 = undefined;
    const found = rs.getVariable(name, &vendor, &buffer) catch return .unset;
    const got = found orelse return .unset;
    if (got[0].len != @sizeOf(Stored)) return .unset;

    var value: Stored = .unset;
    @memcpy(std.mem.asBytes(&value), got[0]);
    if (value.version != 1) return .unset;
    return value;
}

/// Write the settings back. False means the firmware would not keep them —
/// worth telling the user, because their choice will not survive a restart.
pub fn save(value: Stored) bool {
    const rs = uefi.system_table.runtime_services;
    const bytes = std.mem.asBytes(&value);
    rs.setVariable(name, &vendor, .{
        .non_volatile = true,
        .bootservice_access = true,
        .runtime_access = true,
    }, bytes) catch return false;
    return true;
}
