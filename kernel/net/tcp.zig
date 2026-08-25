//! TCP: connection table, in-order data, retransmission. No I/O of its own.
//!
//! Incoming segments arrive through `handle`; outgoing frames are written
//! into the caller's buffer. `tick` retransmits. Out-of-order data is dropped
//! and ACKed at RCV.NXT — enough for HTTP/1.1 on a LAN or QEMU user-net.

const std = @import("std");
const net = @import("net.zig");

pub const max_tcbs = 4;
/// A kilobyte each was enough to fetch a page of text. A TLS handshake sends
/// a certificate chain several kilobytes long, and a receiver that can hold
/// one kilobyte spends the handshake advertising a closed window. Four
/// connections at this size is 48 KiB of static memory, which is a fair price
/// for the difference between working and stalling.
pub const rx_cap = 8192;
/// Sending stays small: a request is a few hundred bytes, and the receive
/// side is where a handshake actually needs room.
pub const tx_cap = 2048;
pub const header_len = 20;
pub const mss = 1460;

const flag_fin: u8 = 0x01;
const flag_syn: u8 = 0x02;
const flag_rst: u8 = 0x04;
const flag_psh: u8 = 0x08;
const flag_ack: u8 = 0x10;

pub const State = enum(u8) {
    closed,
    syn_sent,
    established,
    fin_wait1,
    fin_wait2,
    time_wait,
    close_wait,
    last_ack,
};

pub const Error = error{
    TableFull,
    NoSuch,
    NotConnected,
    WouldBlock,
};

pub const Tcb = struct {
    used: bool = false,
    state: State = .closed,
    local_port: u16 = 0,
    remote_port: u16 = 0,
    remote_ip: net.Ip4 = .{ 0, 0, 0, 0 },
    iss: u32 = 0,
    snd_una: u32 = 0,
    snd_nxt: u32 = 0,
    snd_wnd: u16 = mss,
    irs: u32 = 0,
    rcv_nxt: u32 = 0,
    rx_len: u16 = 0,
    tx_len: u16 = 0,
    tx_off: u16 = 0,
    last_send_ns: u64 = 0,
    rto_ns: u64 = 1_000_000_000,
    retries: u8 = 0,
    timewait_ns: u64 = 0,
    rx: [rx_cap]u8 = @splat(0),
    tx: [tx_cap]u8 = @splat(0),
};

pub const Tcp = struct {
    tcbs: [max_tcbs]Tcb = @splat(.{}),

    pub fn portTaken(self: *const Tcp, port: u16) bool {
        for (self.tcbs) |t| {
            if (t.used and t.local_port == port) return true;
        }
        return false;
    }

    fn get(self: *Tcp, id: usize) Error!*Tcb {
        if (id >= max_tcbs or !self.tcbs[id].used) return Error.NoSuch;
        return &self.tcbs[id];
    }

    pub fn connect(self: *Tcp, stack: anytype, remote_ip: net.Ip4, remote_port: u16, now_ns: u64, out: []u8) Error!struct { id: usize, len: usize } {
        var free_slot: ?usize = null;
        for (&self.tcbs, 0..) |*t, i| {
            if (!t.used) {
                free_slot = i;
                break;
            }
        }
        const id = free_slot orelse return Error.TableFull;
        const local = stack.allocPort();
        const iss: u32 = @truncate(now_ns ^ (@as(u64, local) << 16));
        const t = &self.tcbs[id];
        t.* = .{
            .used = true,
            .state = .syn_sent,
            .local_port = local,
            .remote_port = remote_port,
            .remote_ip = remote_ip,
            .iss = iss,
            .snd_una = iss,
            .snd_nxt = iss +% 1,
            .last_send_ns = now_ns,
            .rto_ns = 1_000_000_000,
        };
        const len = emit(stack, t, t.iss, 0, flag_syn, &.{}, out);
        return .{ .id = id, .len = len };
    }

    pub fn send(self: *Tcp, stack: anytype, id: usize, data: []const u8, now_ns: u64, out: []u8) Error!struct { copied: usize, len: usize } {
        const t = try self.get(id);
        if (t.state != .established) return Error.NotConnected;
        const space = tx_cap - t.tx_len;
        const n = @min(space, data.len);
        if (n == 0) return .{ .copied = 0, .len = 0 };
        @memcpy(t.tx[t.tx_len..][0..n], data[0..n]);
        t.tx_len += @intCast(n);
        const len = flushTx(stack, t, now_ns, out);
        return .{ .copied = n, .len = len };
    }

    /// Tell the other end how much room there is now. Draining the receive
    /// buffer is invisible to the sender until something says so, and a sender
    /// that believes the window is shut waits for a probe that may be seconds
    /// away.
    pub fn windowUpdate(self: *Tcp, stack: anytype, id: usize, now_ns: u64, out: []u8) Error!usize {
        const t = try self.get(id);
        if (t.state != .established) return 0;
        _ = now_ns;
        return emit(stack, t, t.snd_nxt, t.rcv_nxt, flag_ack, &.{}, out);
    }

    pub fn recv(self: *Tcp, id: usize, out: []u8) Error!usize {
        const t = try self.get(id);
        const n = @min(out.len, t.rx_len);
        if (n == 0) return 0;
        @memcpy(out[0..n], t.rx[0..n]);
        const rest = t.rx_len - n;
        if (rest > 0) std.mem.copyForwards(u8, t.rx[0..rest], t.rx[n..][0..rest]);
        t.rx_len = @intCast(rest);
        return n;
    }

    pub fn close(self: *Tcp, stack: anytype, id: usize, now_ns: u64, out: []u8) Error!usize {
        const t = try self.get(id);
        switch (t.state) {
            .established => {
                t.state = .fin_wait1;
                t.last_send_ns = now_ns;
                const seq = t.snd_nxt;
                t.snd_nxt +%= 1;
                return emit(stack, t, seq, t.rcv_nxt, flag_fin | flag_ack, &.{}, out);
            },
            .close_wait => {
                t.state = .last_ack;
                t.last_send_ns = now_ns;
                const seq = t.snd_nxt;
                t.snd_nxt +%= 1;
                return emit(stack, t, seq, t.rcv_nxt, flag_fin | flag_ack, &.{}, out);
            },
            else => {
                t.used = false;
                t.state = .closed;
                return 0;
            },
        }
    }

    /// Give the connection block back. The owner of a socket does this when it
    /// is finished with it: a block left in time_wait is a block the next
    /// caller cannot have, and there are only four.
    pub fn release(self: *Tcp, id: usize) void {
        if (id >= self.tcbs.len) return;
        self.tcbs[id] = .{};
    }

    pub fn stateOf(self: *const Tcp, id: usize) ?State {
        if (id >= max_tcbs or !self.tcbs[id].used) return null;
        return self.tcbs[id].state;
    }

    pub fn handle(self: *Tcp, stack: anytype, ip: net.Ip4View, now_ns: u64, out: []u8) usize {
        if (ip.payload.len < header_len) {
            stack.dropped += 1;
            return 0;
        }
        const src_port = std.mem.readInt(u16, ip.payload[0..2], .big);
        const dst_port = std.mem.readInt(u16, ip.payload[2..4], .big);
        const seq = std.mem.readInt(u32, ip.payload[4..8], .big);
        const ack = std.mem.readInt(u32, ip.payload[8..12], .big);
        const offset_words: usize = ip.payload[12] >> 4;
        const hdr = offset_words * 4;
        if (hdr < header_len or ip.payload.len < hdr) {
            stack.dropped += 1;
            return 0;
        }
        const flags = ip.payload[13];
        const window = std.mem.readInt(u16, ip.payload[14..16], .big);
        const data = ip.payload[hdr..];

        var tcb: ?*Tcb = null;
        for (&self.tcbs) |*t| {
            if (t.used and t.local_port == dst_port and t.remote_port == src_port and net.eqlIp(t.remote_ip, ip.source)) {
                tcb = t;
                break;
            }
        }
        const t = tcb orelse {
            if (flags & flag_rst != 0) return 0;
            // RST the unknown segment so a half-open peer does not retry forever.
            return emitRst(stack, ip.source, src_port, dst_port, seq, ack, flags, out);
        };

        if (flags & flag_rst != 0) {
            t.used = false;
            t.state = .closed;
            return 0;
        }
        t.snd_wnd = if (window == 0) 1 else window;

        switch (t.state) {
            .syn_sent => {
                if (flags & flag_syn == 0 or flags & flag_ack == 0) return 0;
                if (ack != t.iss +% 1) return 0;
                t.irs = seq;
                t.rcv_nxt = seq +% 1;
                t.snd_una = ack;
                t.state = .established;
                t.retries = 0;
                return emit(stack, t, t.snd_nxt, t.rcv_nxt, flag_ack, &.{}, out);
            },
            .established, .fin_wait1, .fin_wait2, .close_wait, .last_ack => {
                if (flags & flag_ack != 0) {
                    if (ack_ge(ack, t.snd_una) and ack_le(ack, t.snd_nxt)) {
                        const newly = ack -% t.snd_una;
                        if (newly > 0 and t.tx_off > 0) {
                            const consume = @min(newly, t.tx_off);
                            const rest = t.tx_len - consume;
                            if (rest > 0) std.mem.copyForwards(u8, t.tx[0..rest], t.tx[consume..][0..rest]);
                            t.tx_len -= @intCast(consume);
                            t.tx_off -= @intCast(consume);
                        }
                        t.snd_una = ack;
                        t.retries = 0;
                    }
                }
                if (t.state == .fin_wait1 and flags & flag_ack != 0 and ack == t.snd_nxt) {
                    t.state = if (flags & flag_fin != 0) .time_wait else .fin_wait2;
                    if (t.state == .time_wait) t.timewait_ns = now_ns;
                }
                if (t.state == .last_ack and flags & flag_ack != 0 and ack == t.snd_nxt) {
                    t.used = false;
                    t.state = .closed;
                    return 0;
                }

                var reply_flags: u8 = flag_ack;
                var produced: usize = 0;
                if (data.len > 0 and seq == t.rcv_nxt) {
                    const space = rx_cap - t.rx_len;
                    const n = @min(space, data.len);
                    if (n > 0) {
                        @memcpy(t.rx[t.rx_len..][0..n], data[0..n]);
                        t.rx_len += @intCast(n);
                        t.rcv_nxt +%= @as(u32, @intCast(n));
                    }
                    produced = 1;
                }
                if (flags & flag_fin != 0 and seq == t.rcv_nxt or (flags & flag_fin != 0 and seq == t.rcv_nxt -% @as(u32, @intCast(data.len)))) {
                    // FIN consumes one sequence number past the data.
                    if (seq == t.rcv_nxt or seq == t.rcv_nxt) {}
                    const fin_seq = seq +% @as(u32, @intCast(data.len));
                    if (fin_seq == t.rcv_nxt) {
                        t.rcv_nxt +%= 1;
                        produced = 1;
                        if (t.state == .established) t.state = .close_wait;
                        if (t.state == .fin_wait1) {
                            t.state = .time_wait;
                            t.timewait_ns = now_ns;
                        }
                        if (t.state == .fin_wait2) {
                            t.state = .time_wait;
                            t.timewait_ns = now_ns;
                        }
                    }
                }
                if (produced == 0 and t.tx_len == t.tx_off) return 0;
                const payload = t.tx[t.tx_off..t.tx_len];
                const send_n = @min(payload.len, @min(@as(usize, t.snd_wnd), mss));
                if (send_n > 0) {
                    reply_flags |= flag_psh;
                    const frame = emit(stack, t, t.snd_una +% t.tx_off, t.rcv_nxt, reply_flags, payload[0..send_n], out);
                    t.tx_off += @intCast(send_n);
                    t.snd_nxt = t.snd_una +% t.tx_off;
                    t.last_send_ns = now_ns;
                    return frame;
                }
                return emit(stack, t, t.snd_nxt, t.rcv_nxt, reply_flags, &.{}, out);
            },
            .time_wait, .closed => return 0,
        }
    }

    pub fn tick(self: *Tcp, stack: anytype, now_ns: u64, out: []u8) usize {
        for (&self.tcbs) |*t| {
            if (!t.used) continue;
            if (t.state == .time_wait) {
                if (now_ns -% t.timewait_ns > 2_000_000_000) {
                    t.used = false;
                    t.state = .closed;
                }
                continue;
            }
            if (now_ns -% t.last_send_ns < t.rto_ns) continue;
            if (t.retries >= 6) {
                t.used = false;
                t.state = .closed;
                continue;
            }
            t.retries += 1;
            t.rto_ns = @min(t.rto_ns * 2, 16_000_000_000);
            t.last_send_ns = now_ns;
            switch (t.state) {
                .syn_sent => return emit(stack, t, t.iss, 0, flag_syn, &.{}, out),
                .established, .fin_wait1, .close_wait, .last_ack => {
                    const payload = t.tx[0..t.tx_len];
                    const send_n = @min(payload.len, mss);
                    const flags: u8 = if (send_n > 0) flag_ack | flag_psh else flag_ack;
                    const extra: u8 = if (t.state == .fin_wait1 or t.state == .last_ack) flag_fin else 0;
                    t.tx_off = @intCast(send_n);
                    return emit(stack, t, t.snd_una, t.rcv_nxt, flags | extra, payload[0..send_n], out);
                },
                else => {},
            }
        }
        return 0;
    }
};

fn ack_ge(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) >= 0;
}

fn ack_le(a: u32, b: u32) bool {
    return @as(i32, @bitCast(b -% a)) >= 0;
}

fn emit(stack: anytype, t: *Tcb, seq: u32, ack: u32, flags: u8, payload: []const u8, out: []u8) usize {
    const hop = stack.nextHop(t.remote_ip);
    const mac = stack.lookup(hop) orelse return 0;
    const tcp_len = header_len + payload.len;
    const seg = out[net.eth_header_len + net.ip_header_len ..][0..tcp_len];
    writeHeader(seg, t.local_port, t.remote_port, seq, ack, flags, rx_cap - t.rx_len);
    if (payload.len > 0) @memcpy(seg[header_len..], payload);
    const sum = net.transportChecksum(stack.config.ip, t.remote_ip, net.proto_tcp, seg);
    std.mem.writeInt(u16, seg[16..18], if (sum == 0) 0xFFFF else sum, .big);
    net.writeIp4(out[net.eth_header_len..], net.proto_tcp, stack.config.ip, t.remote_ip, tcp_len, stack.next_id);
    stack.next_id +%= 1;
    net.writeEthernet(out, mac, stack.config.mac, net.ether_type_ip4);
    stack.sent += 1;
    return net.eth_header_len + net.ip_header_len + tcp_len;
}

fn emitRst(stack: anytype, dst: net.Ip4, dst_port: u16, src_port: u16, seq: u32, ack: u32, flags: u8, out: []u8) usize {
    const hop = stack.nextHop(dst);
    const mac = stack.lookup(hop) orelse return 0;
    const seg = out[net.eth_header_len + net.ip_header_len ..][0..header_len];
    const rst_ack: u32 = if (flags & flag_ack != 0) seq else 0;
    const rst_seq: u32 = if (flags & flag_ack != 0) ack else seq +% 1;
    const rst_flags: u8 = if (flags & flag_ack != 0) flag_rst else flag_rst | flag_ack;
    writeHeader(seg, src_port, dst_port, rst_seq, rst_ack, rst_flags, 0);
    const sum = net.transportChecksum(stack.config.ip, dst, net.proto_tcp, seg);
    std.mem.writeInt(u16, seg[16..18], if (sum == 0) 0xFFFF else sum, .big);
    net.writeIp4(out[net.eth_header_len..], net.proto_tcp, stack.config.ip, dst, header_len, stack.next_id);
    stack.next_id +%= 1;
    net.writeEthernet(out, mac, stack.config.mac, net.ether_type_ip4);
    stack.sent += 1;
    return net.eth_header_len + net.ip_header_len + header_len;
}

fn writeHeader(out: []u8, src: u16, dst: u16, seq: u32, ack: u32, flags: u8, window: usize) void {
    @memset(out[0..header_len], 0);
    std.mem.writeInt(u16, out[0..2], src, .big);
    std.mem.writeInt(u16, out[2..4], dst, .big);
    std.mem.writeInt(u32, out[4..8], seq, .big);
    std.mem.writeInt(u32, out[8..12], ack, .big);
    out[12] = 0x50;
    out[13] = flags;
    std.mem.writeInt(u16, out[14..16], @intCast(@min(window, 65535)), .big);
}

fn flushTx(stack: anytype, t: *Tcb, now_ns: u64, out: []u8) usize {
    if (t.tx_len == t.tx_off) return 0;
    const payload = t.tx[t.tx_off..t.tx_len];
    const n = @min(payload.len, @min(@as(usize, t.snd_wnd), mss));
    if (n == 0) return 0;
    const frame = emit(stack, t, t.snd_una +% t.tx_off, t.rcv_nxt, flag_ack | flag_psh, payload[0..n], out);
    t.tx_off += @intCast(n);
    t.snd_nxt = t.snd_una +% t.tx_off;
    t.last_send_ns = now_ns;
    return frame;
}

const testing = std.testing;

fn testStack() net.Stack {
    var s = net.Stack{ .config = .{ .mac = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 } } };
    s.remember(.{ 10, 0, 2, 2 }, .{ 0x52, 0x55, 0x0A, 0x00, 0x02, 0x02 });
    return s;
}

fn peerSegment(src_port: u16, dst_port: u16, seq: u32, ack: u32, flags: u8, payload: []const u8, out: []u8) usize {
    const tcp_len = header_len + payload.len;
    writeHeader(out[net.eth_header_len + net.ip_header_len ..], src_port, dst_port, seq, ack, flags, 8192);
    if (payload.len > 0) {
        @memcpy(out[net.eth_header_len + net.ip_header_len + header_len ..][0..payload.len], payload);
    }
    net.writeIp4(out[net.eth_header_len..], net.proto_tcp, .{ 10, 0, 2, 2 }, .{ 10, 0, 2, 15 }, tcp_len, 9);
    net.writeEthernet(out, .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 }, .{ 0x52, 0x55, 0x0A, 0x00, 0x02, 0x02 }, net.ether_type_ip4);
    return net.eth_header_len + net.ip_header_len + tcp_len;
}

test "tcp: a synthetic handshake reaches established and carries a byte" {
    var stack = testStack();
    var out: [net.max_frame]u8 = undefined;
    const opened = try stack.tcp.connect(&stack, .{ 10, 0, 2, 2 }, 80, 1000, &out);
    try testing.expect(opened.len > 0);
    try testing.expectEqual(State.syn_sent, stack.tcp.stateOf(opened.id).?);

    const syn = out[net.eth_header_len + net.ip_header_len ..];
    const iss = std.mem.readInt(u32, syn[4..8], .big);
    const local = std.mem.readInt(u16, syn[0..2], .big);

    var reply: [net.max_frame]u8 = undefined;
    const rlen = peerSegment(80, local, 50, iss +% 1, flag_syn | flag_ack, &.{}, &reply);
    var scratch: [net.max_frame]u8 = undefined;
    const ack_len = stack.receive(reply[0..rlen], 2000, &scratch);
    try testing.expect(ack_len > 0);
    try testing.expectEqual(State.established, stack.tcp.stateOf(opened.id).?);

    const sent = try stack.tcp.send(&stack, opened.id, "A", 3000, &out);
    try testing.expectEqual(@as(usize, 1), sent.copied);
    try testing.expect(sent.len > 0);

    const data_len = peerSegment(80, local, 51, iss +% 2, flag_ack | flag_psh, "B", &reply);
    _ = stack.receive(reply[0..data_len], 4000, &scratch);
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), try stack.tcp.recv(opened.id, &buf));
    try testing.expectEqual(@as(u8, 'B'), buf[0]);
}
