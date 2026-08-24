//! Capability audit log (FR-2.3).
//!
//! Fixed-size ring buffer: the kernel allocates nothing, and on overflow
//! it honestly counts the records it dropped (`dropped`).
//! The log is readable by the user and is the basis for revocation.

const std = @import("std");

pub const EventKind = enum(u8) {
    /// Root capability issued by the kernel.
    issued,
    /// Derived capability issued from a parent one (delegation).
    derived,
    /// Check on use: allowed.
    used,
    /// Check on use: denied.
    denied,
    /// Revoked by the user or by the holder.
    revoked,
    /// Lifetime expired or use budget exhausted.
    expired,
    /// Transferred to another process over IPC.
    transferred,
};

pub const Decision = enum(u8) {
    allow,
    no_cap,
    wrong_object,
    missing_rights,
    out_of_scope,
    expired,
    revoked,
    exhausted,
    wrong_holder,

    pub fn ok(self: Decision) bool {
        return self == .allow;
    }
};

pub const Entry = struct {
    seq: u64 = 0,
    ts_ns: u64 = 0,
    kind: EventKind = .issued,
    decision: Decision = .allow,
    cap: u64 = 0,
    parent: u64 = 0,
    holder: u32 = 0,
    object_kind: u8 = 0,
    object_id: u64 = 0,
    rights: u16 = 0,
    /// Human-readable reason for the grant, e.g. "index Documents for task X".
    purpose: [48]u8 = @splat(0),
    purpose_len: u8 = 0,

    pub fn purposeText(self: *const Entry) []const u8 {
        return self.purpose[0..self.purpose_len];
    }
};

pub fn Log(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        entries: [capacity]Entry = @splat(.{}),
        head: usize = 0,
        len: usize = 0,
        next_seq: u64 = 1,
        dropped: u64 = 0,

        pub fn record(self: *Self, entry: Entry) u64 {
            var e = entry;
            e.seq = self.next_seq;
            self.next_seq += 1;
            if (self.len == capacity) {
                self.dropped += 1;
                self.entries[self.head] = e;
                self.head = (self.head + 1) % capacity;
            } else {
                self.entries[(self.head + self.len) % capacity] = e;
                self.len += 1;
            }
            return e.seq;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        /// Records from oldest to newest.
        pub fn at(self: *const Self, i: usize) ?Entry {
            if (i >= self.len) return null;
            return self.entries[(self.head + i) % capacity];
        }

        pub fn last(self: *const Self) ?Entry {
            if (self.len == 0) return null;
            return self.entries[(self.head + self.len - 1) % capacity];
        }

        /// How many records belong to a holder process (for the user panel).
        pub fn countForHolder(self: *const Self, holder: u32) usize {
            var n: usize = 0;
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (self.at(i).?.holder == holder) n += 1;
            }
            return n;
        }

        /// Every event for one capability: its grant and usage history.
        pub fn countForCap(self: *const Self, cap: u64) usize {
            var n: usize = 0;
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (self.at(i).?.cap == cap) n += 1;
            }
            return n;
        }

        pub fn clear(self: *Self) void {
            self.head = 0;
            self.len = 0;
            self.dropped = 0;
        }
    };
}

pub fn makePurpose(text: []const u8) struct { buf: [48]u8, len: u8 } {
    var buf: [48]u8 = @splat(0);
    const n = @min(text.len, buf.len);
    @memcpy(buf[0..n], text[0..n]);
    return .{ .buf = buf, .len = @intCast(n) };
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

test "audit: records stay ordered and numbered" {
    var log = Log(4){};
    _ = log.record(.{ .kind = .issued, .cap = 1, .holder = 7 });
    _ = log.record(.{ .kind = .used, .cap = 1, .holder = 7 });
    try testing.expectEqual(@as(usize, 2), log.count());
    try testing.expectEqual(@as(u64, 1), log.at(0).?.seq);
    try testing.expectEqual(@as(u64, 2), log.at(1).?.seq);
    try testing.expectEqual(EventKind.used, log.last().?.kind);
}

test "audit: ring overflow counts drops without losing order" {
    var log = Log(3){};
    for (0..5) |i| _ = log.record(.{ .cap = @intCast(i) });
    try testing.expectEqual(@as(usize, 3), log.count());
    try testing.expectEqual(@as(u64, 2), log.dropped);
    try testing.expectEqual(@as(u64, 2), log.at(0).?.cap);
    try testing.expectEqual(@as(u64, 4), log.at(2).?.cap);
}

test "audit: query by process and by capability" {
    var log = Log(8){};
    _ = log.record(.{ .cap = 1, .holder = 10 });
    _ = log.record(.{ .cap = 2, .holder = 11 });
    _ = log.record(.{ .cap = 1, .holder = 10 });
    try testing.expectEqual(@as(usize, 2), log.countForHolder(10));
    try testing.expectEqual(@as(usize, 1), log.countForHolder(11));
    try testing.expectEqual(@as(usize, 2), log.countForCap(1));
}
