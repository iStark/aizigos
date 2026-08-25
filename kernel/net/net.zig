//! The network stack: Ethernet, ARP, IPv4 and ICMP.
//!
//! No I/O happens here. The stack is handed a received frame and answers with
//! the frame it wants sent, which is what makes it testable on the host
//! without a card, an emulator or a network. The driver behind the HAL does
//! the actual moving of bytes.

const std = @import("std");
pub const tcp_mod = @import("tcp.zig");
const dns_mod = @import("dns.zig");

pub const Tcp = tcp_mod.Tcp;
pub const Dns = dns_mod.Dns;

pub const Mac = [6]u8;
pub const Ip4 = [4]u8;

pub const broadcast_mac: Mac = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
pub const zero_mac: Mac = .{ 0, 0, 0, 0, 0, 0 };

pub const ether_type_ip4: u16 = 0x0800;
pub const ether_type_arp: u16 = 0x0806;

pub const max_frame = 1518;

pub fn eqlMac(a: Mac, b: Mac) bool {
    return std.mem.eql(u8, &a, &b);
}

pub fn eqlIp(a: Ip4, b: Ip4) bool {
    return std.mem.eql(u8, &a, &b);
}

/// Parses "10.0.2.2" without allocating.
pub fn parseIp(text: []const u8) ?Ip4 {
    var out: Ip4 = .{ 0, 0, 0, 0 };
    var part: usize = 0;
    var value: u32 = 0;
    var digits: usize = 0;
    for (text) |c| {
        if (c == '.') {
            if (digits == 0 or part == 3) return null;
            out[part] = @intCast(value);
            part += 1;
            value = 0;
            digits = 0;
            continue;
        }
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
        if (value > 255) return null;
        digits += 1;
    }
    if (digits == 0 or part != 3) return null;
    out[3] = @intCast(value);
    return out;
}

// --- checksums -------------------------------------------------------------

/// The one's complement sum every IP protocol uses.
pub fn checksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += (@as(u32, data[i]) << 8) | data[i + 1];
    }
    if (i < data.len) sum += @as(u32, data[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return @truncate(~sum);
}

// --- Ethernet --------------------------------------------------------------

pub const eth_header_len = 14;

pub fn writeEthernet(out: []u8, dst: Mac, src: Mac, ether_type: u16) void {
    @memcpy(out[0..6], &dst);
    @memcpy(out[6..12], &src);
    std.mem.writeInt(u16, out[12..14], ether_type, .big);
}

pub const EthernetView = struct {
    dst: Mac,
    src: Mac,
    ether_type: u16,
    payload: []const u8,
};

pub fn parseEthernet(frame: []const u8) ?EthernetView {
    if (frame.len < eth_header_len) return null;
    var view: EthernetView = undefined;
    @memcpy(&view.dst, frame[0..6]);
    @memcpy(&view.src, frame[6..12]);
    view.ether_type = std.mem.readInt(u16, frame[12..14], .big);
    view.payload = frame[eth_header_len..];
    return view;
}

// --- ARP -------------------------------------------------------------------

pub const arp_len = 28;
pub const arp_request: u16 = 1;
pub const arp_reply: u16 = 2;

pub const ArpView = struct {
    operation: u16,
    sender_mac: Mac,
    sender_ip: Ip4,
    target_ip: Ip4,
};

pub fn parseArp(payload: []const u8) ?ArpView {
    if (payload.len < arp_len) return null;
    if (std.mem.readInt(u16, payload[0..2], .big) != 1) return null; // Ethernet
    if (std.mem.readInt(u16, payload[2..4], .big) != ether_type_ip4) return null;
    if (payload[4] != 6 or payload[5] != 4) return null;
    var view: ArpView = undefined;
    view.operation = std.mem.readInt(u16, payload[6..8], .big);
    @memcpy(&view.sender_mac, payload[8..14]);
    @memcpy(&view.sender_ip, payload[14..18]);
    @memcpy(&view.target_ip, payload[24..28]);
    return view;
}

fn writeArp(
    out: []u8,
    operation: u16,
    sender_mac: Mac,
    sender_ip: Ip4,
    target_mac: Mac,
    target_ip: Ip4,
) void {
    std.mem.writeInt(u16, out[0..2], 1, .big);
    std.mem.writeInt(u16, out[2..4], ether_type_ip4, .big);
    out[4] = 6;
    out[5] = 4;
    std.mem.writeInt(u16, out[6..8], operation, .big);
    @memcpy(out[8..14], &sender_mac);
    @memcpy(out[14..18], &sender_ip);
    @memcpy(out[18..24], &target_mac);
    @memcpy(out[24..28], &target_ip);
}

// --- IPv4 ------------------------------------------------------------------

pub const ip_header_len = 20;
pub const proto_icmp: u8 = 1;
pub const proto_udp: u8 = 17;
pub const proto_tcp: u8 = 6;

pub const Ip4View = struct {
    protocol: u8,
    source: Ip4,
    destination: Ip4,
    payload: []const u8,
};

pub fn parseIp4(payload: []const u8) ?Ip4View {
    if (payload.len < ip_header_len) return null;
    if (payload[0] >> 4 != 4) return null;
    const header_len = @as(usize, payload[0] & 0x0F) * 4;
    if (header_len < ip_header_len or payload.len < header_len) return null;
    const total = std.mem.readInt(u16, payload[2..4], .big);
    if (total < header_len or total > payload.len) return null;

    var view: Ip4View = undefined;
    view.protocol = payload[9];
    @memcpy(&view.source, payload[12..16]);
    @memcpy(&view.destination, payload[16..20]);
    view.payload = payload[header_len..total];
    return view;
}

pub fn writeIp4(out: []u8, protocol: u8, source: Ip4, destination: Ip4, payload_len: usize, id: u16) void {
    @memset(out[0..ip_header_len], 0);
    out[0] = 0x45; // version 4, 5 words of header
    std.mem.writeInt(u16, out[2..4], @intCast(ip_header_len + payload_len), .big);
    std.mem.writeInt(u16, out[4..6], id, .big);
    out[6] = 0x40; // do not fragment
    out[8] = 64; // time to live
    out[9] = protocol;
    @memcpy(out[12..16], &source);
    @memcpy(out[16..20], &destination);
    const sum = checksum(out[0..ip_header_len]);
    std.mem.writeInt(u16, out[10..12], sum, .big);
}

/// Ones-complement sum of a transport segment plus the IPv4 pseudo-header.
pub fn transportChecksum(source: Ip4, destination: Ip4, protocol: u8, segment: []const u8) u16 {
    var sum: u32 = 0;
    sum += (@as(u32, source[0]) << 8) | source[1];
    sum += (@as(u32, source[2]) << 8) | source[3];
    sum += (@as(u32, destination[0]) << 8) | destination[1];
    sum += (@as(u32, destination[2]) << 8) | destination[3];
    sum += protocol;
    sum += @as(u32, @intCast(segment.len));
    var i: usize = 0;
    while (i + 1 < segment.len) : (i += 2) {
        sum += (@as(u32, segment[i]) << 8) | segment[i + 1];
    }
    if (i < segment.len) sum += @as(u32, segment[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    const folded: u16 = @truncate(sum);
    return if (folded == 0xFFFF) 0xFFFF else ~folded;
}

pub const udp_header_len = 8;
pub const max_udp_payload = 512;

pub const UdpView = struct {
    src_port: u16,
    dst_port: u16,
    payload: []const u8,
};

pub fn parseUdp(segment: []const u8) ?UdpView {
    if (segment.len < udp_header_len) return null;
    const declared = std.mem.readInt(u16, segment[4..6], .big);
    if (declared < udp_header_len or declared > segment.len) return null;
    return .{
        .src_port = std.mem.readInt(u16, segment[0..2], .big),
        .dst_port = std.mem.readInt(u16, segment[2..4], .big),
        .payload = segment[udp_header_len..declared],
    };
}

pub fn writeUdp(out: []u8, src_port: u16, dst_port: u16, payload: []const u8, source: Ip4, destination: Ip4) usize {
    const total = udp_header_len + payload.len;
    std.mem.writeInt(u16, out[0..2], src_port, .big);
    std.mem.writeInt(u16, out[2..4], dst_port, .big);
    std.mem.writeInt(u16, out[4..6], @intCast(total), .big);
    std.mem.writeInt(u16, out[6..8], 0, .big);
    @memcpy(out[udp_header_len..][0..payload.len], payload);
    const sum = transportChecksum(source, destination, proto_udp, out[0..total]);
    std.mem.writeInt(u16, out[6..8], if (sum == 0) 0xFFFF else sum, .big);
    return total;
}

const udp_slots = 4;

const UdpSlot = struct {
    port: u16 = 0,
    used: bool = false,
    from_ip: Ip4 = .{ 0, 0, 0, 0 },
    from_port: u16 = 0,
    rx_len: u16 = 0,
    rx: [max_udp_payload]u8 = @splat(0),
};

// --- ICMP ------------------------------------------------------------------

pub const icmp_echo_request: u8 = 8;
pub const icmp_echo_reply: u8 = 0;

pub const IcmpView = struct {
    kind: u8,
    identifier: u16,
    sequence: u16,
    payload: []const u8,
};

pub fn parseIcmp(payload: []const u8) ?IcmpView {
    if (payload.len < 8) return null;
    return .{
        .kind = payload[0],
        .identifier = std.mem.readInt(u16, payload[4..6], .big),
        .sequence = std.mem.readInt(u16, payload[6..8], .big),
        .payload = payload[8..],
    };
}

// --- the stack ------------------------------------------------------------

pub const arp_entries = 8;

const ArpEntry = struct {
    ip: Ip4 = .{ 0, 0, 0, 0 },
    mac: Mac = zero_mac,
    live: bool = false,
};

pub const Stats = struct {
    received: u64,
    sent: u64,
    dropped: u64,
    arp_replies: u64,
    pings_sent: u64,
    pongs: u64,
};

pub const Config = struct {
    mac: Mac = zero_mac,
    ip: Ip4 = .{ 10, 0, 2, 15 },
    netmask: Ip4 = .{ 255, 255, 255, 0 },
    gateway: Ip4 = .{ 10, 0, 2, 2 },
};

pub const Stack = struct {
    config: Config = .{},
    table: [arp_entries]ArpEntry = @splat(.{}),
    next_id: u16 = 1,
    next_ephemeral: u16 = 49152,
    udp: [udp_slots]UdpSlot = @splat(.{}),
    tcp: Tcp = .{},
    dns: Dns = .{},
    dns_server: Ip4 = .{ 10, 0, 2, 3 },
    /// The echo we are waiting for, if any.
    ping_target: ?Ip4 = null,
    ping_sequence: u16 = 0,
    ping_sent_ns: u64 = 0,
    ping_rtt_ns: ?u64 = null,

    received: u64 = 0,
    sent: u64 = 0,
    dropped: u64 = 0,
    arp_replies: u64 = 0,
    pings_sent: u64 = 0,
    pongs: u64 = 0,

    pub fn stats(self: *const Stack) Stats {
        return .{
            .received = self.received,
            .sent = self.sent,
            .dropped = self.dropped,
            .arp_replies = self.arp_replies,
            .pings_sent = self.pings_sent,
            .pongs = self.pongs,
        };
    }

    pub fn remember(self: *Stack, ip: Ip4, mac: Mac) void {
        for (&self.table) |*entry| {
            if (entry.live and eqlIp(entry.ip, ip)) {
                entry.mac = mac;
                return;
            }
        }
        for (&self.table) |*entry| {
            if (!entry.live) {
                entry.* = .{ .ip = ip, .mac = mac, .live = true };
                return;
            }
        }
        // The table is full; the oldest slot is as good a victim as any.
        self.table[0] = .{ .ip = ip, .mac = mac, .live = true };
    }

    pub fn lookup(self: *const Stack, ip: Ip4) ?Mac {
        for (&self.table) |*entry| {
            if (entry.live and eqlIp(entry.ip, ip)) return entry.mac;
        }
        return null;
    }

    /// Anything outside the local subnet goes through the gateway.
    pub fn nextHop(self: *const Stack, destination: Ip4) Ip4 {
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            if ((destination[i] & self.config.netmask[i]) != (self.config.ip[i] & self.config.netmask[i])) {
                return self.config.gateway;
            }
        }
        return destination;
    }

    /// Build an ARP request for an address we do not know yet.
    pub fn buildArpRequest(self: *Stack, target: Ip4, out: []u8) usize {
        writeEthernet(out, broadcast_mac, self.config.mac, ether_type_arp);
        writeArp(
            out[eth_header_len..],
            arp_request,
            self.config.mac,
            self.config.ip,
            zero_mac,
            target,
        );
        self.sent += 1;
        return eth_header_len + arp_len;
    }

    /// Build an echo request. Returns 0 when the hardware address of the next
    /// hop is not known yet: the caller should ARP for it first.
    pub fn buildPing(self: *Stack, target: Ip4, now_ns: u64, out: []u8) usize {
        const hop = self.nextHop(target);
        const mac = self.lookup(hop) orelse return 0;

        const payload = "aizigos-echo";
        const icmp_len = 8 + payload.len;
        const icmp = out[eth_header_len + ip_header_len ..][0..icmp_len];
        @memset(icmp, 0);
        icmp[0] = icmp_echo_request;
        std.mem.writeInt(u16, icmp[4..6], 0xA1A1, .big);
        self.ping_sequence +%= 1;
        std.mem.writeInt(u16, icmp[6..8], self.ping_sequence, .big);
        @memcpy(icmp[8..][0..payload.len], payload);
        const sum = checksum(icmp);
        std.mem.writeInt(u16, icmp[2..4], sum, .big);

        writeIp4(
            out[eth_header_len..],
            proto_icmp,
            self.config.ip,
            target,
            icmp_len,
            self.next_id,
        );
        self.next_id +%= 1;
        writeEthernet(out, mac, self.config.mac, ether_type_ip4);

        self.ping_target = target;
        self.ping_sent_ns = now_ns;
        self.ping_rtt_ns = null;
        self.pings_sent += 1;
        self.sent += 1;
        return eth_header_len + ip_header_len + icmp_len;
    }

    /// Feed a received frame in; if the stack wants to answer, the reply is
    /// written into `out` and its length returned.
    pub fn receive(self: *Stack, frame: []const u8, now_ns: u64, out: []u8) usize {
        self.received += 1;
        const eth = parseEthernet(frame) orelse {
            self.dropped += 1;
            return 0;
        };
        if (!eqlMac(eth.dst, self.config.mac) and !eqlMac(eth.dst, broadcast_mac)) {
            self.dropped += 1;
            return 0;
        }

        return switch (eth.ether_type) {
            ether_type_arp => self.handleArp(eth, out),
            ether_type_ip4 => self.handleIp4(eth, now_ns, out),
            else => blk: {
                self.dropped += 1;
                break :blk 0;
            },
        };
    }

    fn handleArp(self: *Stack, eth: EthernetView, out: []u8) usize {
        const arp = parseArp(eth.payload) orelse {
            self.dropped += 1;
            return 0;
        };
        self.remember(arp.sender_ip, arp.sender_mac);

        if (arp.operation == arp_reply) {
            self.arp_replies += 1;
            return 0;
        }
        if (arp.operation != arp_request) return 0;
        if (!eqlIp(arp.target_ip, self.config.ip)) return 0;

        // Somebody is asking for us, so answer.
        writeEthernet(out, arp.sender_mac, self.config.mac, ether_type_arp);
        writeArp(
            out[eth_header_len..],
            arp_reply,
            self.config.mac,
            self.config.ip,
            arp.sender_mac,
            arp.sender_ip,
        );
        self.sent += 1;
        return eth_header_len + arp_len;
    }

    fn handleIp4(self: *Stack, eth: EthernetView, now_ns: u64, out: []u8) usize {
        const ip = parseIp4(eth.payload) orelse {
            self.dropped += 1;
            return 0;
        };
        if (!eqlIp(ip.destination, self.config.ip)) {
            self.dropped += 1;
            return 0;
        }
        self.remember(ip.source, eth.src);

        if (ip.protocol == proto_udp) return self.handleUdp(ip);
        if (ip.protocol == proto_tcp) return self.tcp.handle(self, ip, now_ns, out);

        if (ip.protocol != proto_icmp) {
            self.dropped += 1;
            return 0;
        }
        const icmp = parseIcmp(ip.payload) orelse {
            self.dropped += 1;
            return 0;
        };

        if (icmp.kind == icmp_echo_reply) {
            if (self.ping_target) |target| {
                if (eqlIp(target, ip.source) and icmp.sequence == self.ping_sequence) {
                    self.ping_rtt_ns = now_ns -% self.ping_sent_ns;
                    self.ping_target = null;
                    self.pongs += 1;
                }
            }
            return 0;
        }

        if (icmp.kind != icmp_echo_request) return 0;

        // Answer the echo: same payload, same identifier, reply type.
        const reply_len = 8 + icmp.payload.len;
        const body = out[eth_header_len + ip_header_len ..][0..reply_len];
        @memset(body, 0);
        body[0] = icmp_echo_reply;
        std.mem.writeInt(u16, body[4..6], icmp.identifier, .big);
        std.mem.writeInt(u16, body[6..8], icmp.sequence, .big);
        @memcpy(body[8..reply_len], icmp.payload);
        const sum = checksum(body);
        std.mem.writeInt(u16, body[2..4], sum, .big);

        writeIp4(out[eth_header_len..], proto_icmp, self.config.ip, ip.source, reply_len, self.next_id);
        self.next_id +%= 1;
        writeEthernet(out, eth.src, self.config.mac, ether_type_ip4);
        self.sent += 1;
        return eth_header_len + ip_header_len + reply_len;
    }

    fn handleUdp(self: *Stack, ip: Ip4View) usize {
        const udp = parseUdp(ip.payload) orelse {
            self.dropped += 1;
            return 0;
        };
        for (&self.udp) |*slot| {
            if (slot.used and slot.port == udp.dst_port) {
                const n = @min(udp.payload.len, slot.rx.len);
                @memcpy(slot.rx[0..n], udp.payload[0..n]);
                slot.rx_len = @intCast(n);
                slot.from_ip = ip.source;
                slot.from_port = udp.src_port;
                return 0;
            }
        }
        self.dropped += 1;
        return 0;
    }

    pub fn bindUdp(self: *Stack, port: u16) ?u16 {
        const chosen = if (port == 0) self.allocPort() else port;
        for (&self.udp) |*slot| {
            if (slot.used and slot.port == chosen) return null;
        }
        for (&self.udp) |*slot| {
            if (slot.used) continue;
            slot.* = .{ .port = chosen, .used = true };
            return chosen;
        }
        return null;
    }

    pub fn unbindUdp(self: *Stack, port: u16) void {
        for (&self.udp) |*slot| {
            if (slot.used and slot.port == port) slot.* = .{};
        }
    }

    pub fn recvUdp(self: *Stack, port: u16, out: []u8) ?struct { ip: Ip4, port: u16, len: usize } {
        for (&self.udp) |*slot| {
            if (!slot.used or slot.port != port or slot.rx_len == 0) continue;
            const n = @min(out.len, slot.rx_len);
            @memcpy(out[0..n], slot.rx[0..n]);
            const from_ip = slot.from_ip;
            const from_port = slot.from_port;
            slot.rx_len = 0;
            return .{ .ip = from_ip, .port = from_port, .len = n };
        }
        return null;
    }

    /// Build a UDP datagram. 0 if the next hop is not in the ARP table.
    pub fn buildUdp(self: *Stack, src_port: u16, dst: Ip4, dst_port: u16, payload: []const u8, out: []u8) usize {
        const hop = self.nextHop(dst);
        const mac = self.lookup(hop) orelse return 0;
        const udp_len = writeUdp(
            out[eth_header_len + ip_header_len ..],
            src_port,
            dst_port,
            payload,
            self.config.ip,
            dst,
        );
        writeIp4(out[eth_header_len..], proto_udp, self.config.ip, dst, udp_len, self.next_id);
        self.next_id +%= 1;
        writeEthernet(out, mac, self.config.mac, ether_type_ip4);
        self.sent += 1;
        return eth_header_len + ip_header_len + udp_len;
    }

    pub fn allocPort(self: *Stack) u16 {
        var i: u16 = 0;
        while (i < 1024) : (i += 1) {
            const port = self.next_ephemeral;
            self.next_ephemeral = if (self.next_ephemeral == 65535) 49152 else self.next_ephemeral + 1;
            var taken = false;
            for (self.udp) |slot| {
                if (slot.used and slot.port == port) taken = true;
            }
            if (self.tcp.portTaken(port)) taken = true;
            if (!taken) return port;
        }
        return 49152;
    }

    /// Retransmit whatever TCP is due. Same "frame in, frame out" contract.
    pub fn tick(self: *Stack, now_ns: u64, out: []u8) usize {
        return self.tcp.tick(self, now_ns, out);
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

const test_mac: Mac = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
const peer_mac: Mac = .{ 0x52, 0x55, 0x0A, 0x00, 0x02, 0x02 };

fn testStack() Stack {
    return .{ .config = .{ .mac = test_mac } };
}

test "net: addresses parse and reject junk" {
    try testing.expectEqual(@as(?Ip4, .{ 10, 0, 2, 2 }), parseIp("10.0.2.2"));
    try testing.expectEqual(@as(?Ip4, .{ 255, 255, 255, 255 }), parseIp("255.255.255.255"));
    try testing.expectEqual(@as(?Ip4, null), parseIp("10.0.2"));
    try testing.expectEqual(@as(?Ip4, null), parseIp("10.0.2.256"));
    try testing.expectEqual(@as(?Ip4, null), parseIp("10.0.2.x"));
    try testing.expectEqual(@as(?Ip4, null), parseIp(""));
}

test "net: the checksum of a header that already carries one is zero" {
    var header: [20]u8 = undefined;
    writeIp4(&header, proto_icmp, .{ 10, 0, 2, 15 }, .{ 10, 0, 2, 2 }, 8, 1);
    try testing.expectEqual(@as(u16, 0), checksum(&header));
}

test "net: an ARP request for us is answered" {
    var stack = testStack();
    var frame: [max_frame]u8 = undefined;
    var reply: [max_frame]u8 = undefined;

    writeEthernet(&frame, broadcast_mac, peer_mac, ether_type_arp);
    writeArp(frame[eth_header_len..], arp_request, peer_mac, .{ 10, 0, 2, 2 }, zero_mac, .{ 10, 0, 2, 15 });

    const len = stack.receive(frame[0 .. eth_header_len + arp_len], 0, &reply);
    try testing.expectEqual(@as(usize, eth_header_len + arp_len), len);

    const eth = parseEthernet(reply[0..len]).?;
    try testing.expect(eqlMac(eth.dst, peer_mac));
    try testing.expect(eqlMac(eth.src, test_mac));
    const arp = parseArp(eth.payload).?;
    try testing.expectEqual(arp_reply, arp.operation);
    try testing.expect(eqlIp(arp.sender_ip, .{ 10, 0, 2, 15 }));
    // Asking for us also taught us where the asker is.
    try testing.expect(eqlMac(stack.lookup(.{ 10, 0, 2, 2 }).?, peer_mac));
}

test "net: an ARP request for somebody else is ignored" {
    var stack = testStack();
    var frame: [max_frame]u8 = undefined;
    var reply: [max_frame]u8 = undefined;
    writeEthernet(&frame, broadcast_mac, peer_mac, ether_type_arp);
    writeArp(frame[eth_header_len..], arp_request, peer_mac, .{ 10, 0, 2, 2 }, zero_mac, .{ 10, 0, 2, 99 });
    try testing.expectEqual(@as(usize, 0), stack.receive(frame[0 .. eth_header_len + arp_len], 0, &reply));
}

test "net: an echo request is answered with the same payload" {
    var stack = testStack();
    stack.remember(.{ 10, 0, 2, 2 }, peer_mac);

    var frame: [max_frame]u8 = undefined;
    var reply: [max_frame]u8 = undefined;

    const payload = "hello";
    const icmp = frame[eth_header_len + ip_header_len ..][0 .. 8 + payload.len];
    @memset(icmp, 0);
    icmp[0] = icmp_echo_request;
    std.mem.writeInt(u16, icmp[4..6], 0x1234, .big);
    std.mem.writeInt(u16, icmp[6..8], 7, .big);
    @memcpy(icmp[8..], payload);
    std.mem.writeInt(u16, icmp[2..4], checksum(icmp), .big);
    writeIp4(frame[eth_header_len..], proto_icmp, .{ 10, 0, 2, 2 }, .{ 10, 0, 2, 15 }, icmp.len, 1);
    writeEthernet(&frame, test_mac, peer_mac, ether_type_ip4);

    const total = eth_header_len + ip_header_len + icmp.len;
    const len = stack.receive(frame[0..total], 0, &reply);
    try testing.expectEqual(total, len);

    const eth = parseEthernet(reply[0..len]).?;
    const ip = parseIp4(eth.payload).?;
    try testing.expect(eqlIp(ip.destination, .{ 10, 0, 2, 2 }));
    const echo = parseIcmp(ip.payload).?;
    try testing.expectEqual(icmp_echo_reply, echo.kind);
    try testing.expectEqual(@as(u16, 7), echo.sequence);
    try testing.expectEqualStrings(payload, echo.payload);
    try testing.expectEqual(@as(u16, 0), checksum(ip.payload));
}

test "net: a ping needs a hardware address first, then matches its reply" {
    var stack = testStack();
    var out: [max_frame]u8 = undefined;

    // Nothing known yet, so no frame can be built.
    try testing.expectEqual(@as(usize, 0), stack.buildPing(.{ 10, 0, 2, 2 }, 0, &out));

    stack.remember(.{ 10, 0, 2, 2 }, peer_mac);
    const len = stack.buildPing(.{ 10, 0, 2, 2 }, 1000, &out);
    try testing.expect(len > 0);
    try testing.expect(stack.ping_target != null);

    // The gateway answers.
    const sent = parseEthernet(out[0..len]).?;
    const sent_ip = parseIp4(sent.payload).?;
    const sent_icmp = parseIcmp(sent_ip.payload).?;

    var reply: [max_frame]u8 = undefined;
    const body = reply[eth_header_len + ip_header_len ..][0 .. 8 + sent_icmp.payload.len];
    @memset(body, 0);
    body[0] = icmp_echo_reply;
    std.mem.writeInt(u16, body[4..6], sent_icmp.identifier, .big);
    std.mem.writeInt(u16, body[6..8], sent_icmp.sequence, .big);
    @memcpy(body[8..], sent_icmp.payload);
    std.mem.writeInt(u16, body[2..4], checksum(body), .big);
    writeIp4(reply[eth_header_len..], proto_icmp, .{ 10, 0, 2, 2 }, .{ 10, 0, 2, 15 }, body.len, 9);
    writeEthernet(&reply, test_mac, peer_mac, ether_type_ip4);

    var scratch: [max_frame]u8 = undefined;
    const answer = stack.receive(reply[0 .. eth_header_len + ip_header_len + body.len], 3000, &scratch);
    try testing.expectEqual(@as(usize, 0), answer);
    try testing.expectEqual(@as(?u64, 2000), stack.ping_rtt_ns);
    try testing.expectEqual(@as(u64, 1), stack.stats().pongs);
}

test "net: traffic for another address is dropped" {
    var stack = testStack();
    var frame: [max_frame]u8 = undefined;
    var reply: [max_frame]u8 = undefined;
    writeEthernet(&frame, peer_mac, peer_mac, ether_type_ip4);
    writeIp4(frame[eth_header_len..], proto_icmp, .{ 10, 0, 2, 2 }, .{ 10, 0, 2, 9 }, 8, 1);
    try testing.expectEqual(@as(usize, 0), stack.receive(frame[0 .. eth_header_len + ip_header_len + 8], 0, &reply));
    try testing.expect(stack.stats().dropped > 0);
}

test "net: a bound UDP port receives a datagram and can reply" {
    var stack = testStack();
    stack.remember(.{ 10, 0, 2, 2 }, peer_mac);
    const port = stack.bindUdp(12345).?;

    var frame: [max_frame]u8 = undefined;
    const payload = "ping-udp";
    const ulen = writeUdp(frame[eth_header_len + ip_header_len ..], 53, 12345, payload, .{ 10, 0, 2, 2 }, .{ 10, 0, 2, 15 });
    writeIp4(frame[eth_header_len..], proto_udp, .{ 10, 0, 2, 2 }, .{ 10, 0, 2, 15 }, ulen, 1);
    writeEthernet(&frame, test_mac, peer_mac, ether_type_ip4);

    var reply: [max_frame]u8 = undefined;
    const total = eth_header_len + ip_header_len + ulen;
    try testing.expectEqual(@as(usize, 0), stack.receive(frame[0..total], 0, &reply));

    var buf: [32]u8 = undefined;
    const got = stack.recvUdp(port, &buf).?;
    try testing.expectEqual(@as(u16, 53), got.port);
    try testing.expectEqualStrings(payload, buf[0..got.len]);

    const slen = stack.buildUdp(port, .{ 10, 0, 2, 2 }, 53, "pong", &reply);
    try testing.expect(slen > 0);
}

test "net: anything off the subnet goes through the gateway" {
    var stack = testStack();
    try testing.expect(eqlIp(stack.nextHop(.{ 10, 0, 2, 7 }), .{ 10, 0, 2, 7 }));
    try testing.expect(eqlIp(stack.nextHop(.{ 93, 184, 216, 34 }), .{ 10, 0, 2, 2 }));
}
