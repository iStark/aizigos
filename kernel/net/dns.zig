//! DNS resolver: query builder, a careful parser, a small TTL cache.
//!
//! Compression pointers are bounded: a pointer may not jump backwards into a
//! label already visited, may not exceed the packet, and may not hop more
//! than a handful of times.

const std = @import("std");
const net = @import("net.zig");

pub const Error = error{
    Truncated,
    BadName,
    Loop,
    NotResponse,
    WrongId,
    NoQuestion,
};

const max_name = 253;
const max_hops = 10;
const cache_slots = 8;
const type_a: u16 = 1;
const class_in: u16 = 1;

const Entry = struct {
    name: [max_name]u8 = @splat(0),
    name_len: u8 = 0,
    ip: net.Ip4 = .{ 0, 0, 0, 0 },
    expire_ns: u64 = 0,
    live: bool = false,
};

pub const Dns = struct {
    slots: [cache_slots]Entry = @splat(.{}),

    pub fn lookup(self: *const Dns, name: []const u8, now_ns: u64) ?net.Ip4 {
        const folded = foldName(name) orelse return null;
        for (self.slots) |slot| {
            if (!slot.live) continue;
            if (now_ns >= slot.expire_ns) continue;
            if (eqlIgnoreCase(slot.name[0..slot.name_len], folded.slice())) return slot.ip;
        }
        return null;
    }

    pub fn store(self: *Dns, name: []const u8, ip: net.Ip4, now_ns: u64, ttl_s: u32) void {
        const folded = foldName(name) orelse return;
        const expire = now_ns +% @as(u64, ttl_s) * 1_000_000_000;
        for (&self.slots) |*slot| {
            if (slot.live and eqlIgnoreCase(slot.name[0..slot.name_len], folded.slice())) {
                slot.ip = ip;
                slot.expire_ns = expire;
                return;
            }
        }
        for (&self.slots) |*slot| {
            if (!slot.live or now_ns >= slot.expire_ns) {
                slot.* = .{
                    .name_len = folded.len,
                    .ip = ip,
                    .expire_ns = expire,
                    .live = true,
                };
                @memcpy(slot.name[0..folded.len], folded.slice());
                return;
            }
        }
        self.slots[0] = .{
            .name_len = folded.len,
            .ip = ip,
            .expire_ns = expire,
            .live = true,
        };
        @memcpy(self.slots[0].name[0..folded.len], folded.slice());
    }
};

const Folded = struct {
    buf: [max_name]u8 = undefined,
    len: u8 = 0,
    fn slice(self: *const Folded) []const u8 {
        return self.buf[0..self.len];
    }
};

fn foldName(name: []const u8) ?Folded {
    if (name.len == 0 or name.len > max_name) return null;
    var out: Folded = .{};
    for (name) |c| {
        const lower: u8 = if (c >= 'A' and c <= 'Z') c + 32 else c;
        if (lower != '.' and (lower < 'a' or lower > 'z') and (lower < '0' or lower > '9') and lower != '-') {
            return null;
        }
        out.buf[out.len] = lower;
        out.len += 1;
    }
    return out;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const lx: u8 = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const ly: u8 = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (lx != ly) return false;
    }
    return true;
}

/// Encode a query for `name` (A, IN) into `out`. Returns the packet length.
pub fn buildQuery(name: []const u8, id: u16, out: []u8) ?usize {
    if (out.len < 12 + name.len + 6) return null;
    @memset(out[0..12], 0);
    std.mem.writeInt(u16, out[0..2], id, .big);
    out[2] = 0x01; // recursion desired
    std.mem.writeInt(u16, out[4..6], 1, .big); // QDCOUNT
    var off: usize = 12;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= name.len) : (i += 1) {
        if (i == name.len or name[i] == '.') {
            const lab = name[start..i];
            if (lab.len == 0 or lab.len > 63) return null;
            if (off + 1 + lab.len + 5 > out.len) return null;
            out[off] = @intCast(lab.len);
            off += 1;
            for (lab) |c| {
                out[off] = if (c >= 'A' and c <= 'Z') c + 32 else c;
                off += 1;
            }
            start = i + 1;
        }
    }
    out[off] = 0;
    off += 1;
    std.mem.writeInt(u16, out[off..][0..2], type_a, .big);
    std.mem.writeInt(u16, out[off + 2 ..][0..2], class_in, .big);
    return off + 4;
}

pub const Answer = struct {
    ip: net.Ip4,
    ttl_s: u32,
};

/// Parse an A record out of a response. Compression pointers are checked.
pub fn parseAnswer(packet: []const u8, id: u16) Error!?Answer {
    if (packet.len < 12) return Error.Truncated;
    const got_id = std.mem.readInt(u16, packet[0..2], .big);
    if (got_id != id) return Error.WrongId;
    if (packet[2] & 0x80 == 0) return Error.NotResponse;
    const rcode = packet[3] & 0x0F;
    if (rcode != 0) return null;
    const qd = std.mem.readInt(u16, packet[4..6], .big);
    const an = std.mem.readInt(u16, packet[6..8], .big);
    if (qd == 0) return Error.NoQuestion;

    var off: usize = 12;
    var q: u16 = 0;
    while (q < qd) : (q += 1) {
        off = try skipName(packet, off);
        if (off + 4 > packet.len) return Error.Truncated;
        off += 4; // QTYPE QCLASS
    }

    var a: u16 = 0;
    while (a < an) : (a += 1) {
        off = try skipName(packet, off);
        if (off + 10 > packet.len) return Error.Truncated;
        const typ = std.mem.readInt(u16, packet[off..][0..2], .big);
        const class = std.mem.readInt(u16, packet[off + 2 ..][0..2], .big);
        const ttl = std.mem.readInt(u32, packet[off + 4 ..][0..4], .big);
        const rdlen = std.mem.readInt(u16, packet[off + 8 ..][0..2], .big);
        off += 10;
        if (off + rdlen > packet.len) return Error.Truncated;
        if (typ == type_a and class == class_in and rdlen == 4) {
            return .{
                .ip = .{ packet[off], packet[off + 1], packet[off + 2], packet[off + 3] },
                .ttl_s = if (ttl == 0) 1 else ttl,
            };
        }
        off += rdlen;
    }
    return null;
}

fn skipName(packet: []const u8, start: usize) Error!usize {
    var off = start;
    var hops: u8 = 0;
    var jumped = false;
    var return_off: usize = 0;
    while (hops < max_hops) : (hops += 1) {
        if (off >= packet.len) return Error.Truncated;
        const len = packet[off];
        if (len == 0) {
            off += 1;
            return if (jumped) return_off else off;
        }
        if (len & 0xC0 == 0xC0) {
            if (off + 2 > packet.len) return Error.Truncated;
            const ptr = (@as(usize, len & 0x3F) << 8) | packet[off + 1];
            if (ptr >= packet.len) return Error.Truncated;
            if (ptr >= off and !jumped) return Error.Loop;
            if (!jumped) {
                return_off = off + 2;
                jumped = true;
            }
            off = ptr;
            continue;
        }
        if (len & 0xC0 != 0) return Error.BadName;
        if (len > 63) return Error.BadName;
        off += 1 + @as(usize, len);
        if (off > packet.len) return Error.Truncated;
    }
    return Error.Loop;
}

const testing = std.testing;

test "dns: a query encodes labels and the parser reads a compressed A" {
    var q: [64]u8 = undefined;
    const qlen = buildQuery("example.com", 0x1234, &q).?;
    try testing.expect(qlen > 12);
    try testing.expectEqual(@as(u8, 7), q[12]);
    try testing.expectEqualStrings("example", q[13..20]);

    // Response: id, QR, one question, one A. The answer name is a pointer to
    // offset 12 (the question name).
    var p: [128]u8 = @splat(0);
    std.mem.writeInt(u16, p[0..2], 0x1234, .big);
    p[2] = 0x81;
    p[3] = 0x80;
    std.mem.writeInt(u16, p[4..6], 1, .big);
    std.mem.writeInt(u16, p[6..8], 1, .big);
    @memcpy(p[12..qlen], q[12..qlen]);
    var off = qlen;
    p[off] = 0xC0;
    p[off + 1] = 12;
    off += 2;
    std.mem.writeInt(u16, p[off..][0..2], type_a, .big);
    std.mem.writeInt(u16, p[off + 2 ..][0..2], class_in, .big);
    std.mem.writeInt(u32, p[off + 4 ..][0..4], 60, .big);
    std.mem.writeInt(u16, p[off + 8 ..][0..2], 4, .big);
    off += 10;
    p[off] = 93;
    p[off + 1] = 184;
    p[off + 2] = 216;
    p[off + 3] = 34;
    off += 4;

    const answer = (try parseAnswer(p[0..off], 0x1234)).?;
    try testing.expectEqual(@as(u8, 93), answer.ip[0]);
    try testing.expectEqual(@as(u8, 34), answer.ip[3]);
    try testing.expectEqual(@as(u32, 60), answer.ttl_s);
}

test "dns: a pointer loop is refused" {
    var p: [32]u8 = @splat(0);
    std.mem.writeInt(u16, p[0..2], 1, .big);
    p[2] = 0x81;
    std.mem.writeInt(u16, p[4..6], 1, .big);
    p[12] = 0xC0;
    p[13] = 12;
    try testing.expectError(Error.Loop, parseAnswer(p[0..14], 1));
}
