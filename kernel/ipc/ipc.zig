//! IPC: синхронные вызовы и асинхронные уведомления (FR-1.3).
//!
//! Главное правило: на КАЖДУЮ операцию — проверка capability.
//! Нет токена на эндпоинт — нет ни отправки, ни приёма, ни ответа.
//! Передача токенов внутри сообщения выполняется как делегирование
//! (derive), поэтому получатель не может получить прав больше отправителя,
//! а факт передачи попадает в аудит.

const std = @import("std");
const cap = @import("../cap/cap.zig");

pub const EndpointId = u32;
pub const max_inline = 64;
pub const max_caps = 4;

pub const Error = error{
    NoEndpoint,
    Denied,
    QueueFull,
    TableFull,
    TooManyCaps,
    NoWaiter,
    TransferFailed,
    NotOwner,
};

pub const Message = struct {
    tag: u32 = 0,
    len: u16 = 0,
    data: [max_inline]u8 = @splat(0),
    caps: [max_caps]cap.CapId = @splat(0),
    cap_count: u8 = 0,
    sender_pid: cap.ProcId = 0,
    sender_tid: u32 = 0,
    /// Ненулевое значение = синхронный вызов, ждущий ответа.
    reply_to: u32 = 0,

    pub fn payload(self: *const Message) []const u8 {
        return self.data[0..self.len];
    }

    pub fn withBytes(tag: u32, bytes: []const u8) Message {
        var m = Message{ .tag = tag };
        const n = @min(bytes.len, max_inline);
        @memcpy(m.data[0..n], bytes[0..n]);
        m.len = @intCast(n);
        return m;
    }
};

pub const SendMode = enum { asynchronous, synchronous };

pub fn Ipc(comptime max_endpoints: usize, comptime queue_depth: usize, comptime max_waiters: usize) type {
    return struct {
        const Self = @This();

        const Endpoint = struct {
            id: EndpointId = 0,
            owner: cap.ProcId = 0,
            used: bool = false,
            queue: [queue_depth]Message = @splat(.{}),
            head: usize = 0,
            len: usize = 0,
            /// Поток-получатель, заблокированный в ожидании сообщения.
            blocked_receiver: ?u32 = null,
        };

        const ReplyBox = struct {
            tid: u32 = 0,
            used: bool = false,
            filled: bool = false,
            msg: Message = .{},
        };

        endpoints: [max_endpoints]Endpoint = @splat(.{}),
        replies: [max_waiters]ReplyBox = @splat(.{}),
        next_id: EndpointId = 1,

        pub fn init() Self {
            return .{};
        }

        pub fn create(self: *Self, owner: cap.ProcId) Error!EndpointId {
            for (&self.endpoints) |*e| {
                if (e.used) continue;
                e.* = .{ .id = self.next_id, .owner = owner, .used = true };
                self.next_id += 1;
                return e.id;
            }
            return Error.TableFull;
        }

        pub fn destroy(self: *Self, id: EndpointId, owner: cap.ProcId) Error!void {
            const e = self.find(id) orelse return Error.NoEndpoint;
            if (e.owner != owner) return Error.NotOwner;
            e.* = .{};
        }

        fn find(self: *Self, id: EndpointId) ?*Endpoint {
            for (&self.endpoints) |*e| {
                if (e.used and e.id == id) return e;
            }
            return null;
        }

        pub fn queueLen(self: *Self, id: EndpointId) usize {
            const e = self.find(id) orelse return 0;
            return e.len;
        }

        fn push(e: *Endpoint, msg: Message) Error!void {
            if (e.len == queue_depth) return Error.QueueFull;
            e.queue[(e.head + e.len) % queue_depth] = msg;
            e.len += 1;
        }

        fn pop(e: *Endpoint) ?Message {
            if (e.len == 0) return null;
            const m = e.queue[e.head];
            e.head = (e.head + 1) % queue_depth;
            e.len -= 1;
            return m;
        }

        fn replySlot(self: *Self, tid: u32) ?*ReplyBox {
            for (&self.replies) |*r| {
                if (r.used and r.tid == tid) return r;
            }
            return null;
        }

        fn allocReplySlot(self: *Self, tid: u32) ?*ReplyBox {
            if (self.replySlot(tid)) |existing| return existing;
            for (&self.replies) |*r| {
                if (!r.used) {
                    r.* = .{ .tid = tid, .used = true };
                    return r;
                }
            }
            return null;
        }

        /// Делегирование токенов, приложенных к сообщению.
        /// Каждый токен пересоздаётся для получателя как производный.
        fn transferCaps(
            registry: anytype,
            msg: *Message,
            from_pid: cap.ProcId,
            to_pid: cap.ProcId,
            now_ns: u64,
        ) Error!void {
            var i: usize = 0;
            while (i < msg.cap_count) : (i += 1) {
                const src_id = msg.caps[i];
                const src = registry.get(src_id) orelse return Error.TransferFailed;
                if (src.holder != from_pid) return Error.Denied;
                const new_id = registry.derive(
                    src_id,
                    from_pid,
                    to_pid,
                    src.rights,
                    src.scope,
                    .{ .purpose = "передан через IPC" },
                    now_ns,
                ) catch return Error.TransferFailed;
                msg.caps[i] = new_id;
            }
        }

        /// Отправка сообщения на эндпоинт. Требует права send на объект-эндпоинт.
        /// В синхронном режиме поток-отправитель блокируется до ответа.
        pub fn send(
            self: *Self,
            registry: anytype,
            scheduler: anytype,
            sender_pid: cap.ProcId,
            sender_tid: u32,
            cap_id: cap.CapId,
            endpoint_id: EndpointId,
            message: Message,
            mode: SendMode,
            now_ns: u64,
        ) Error!void {
            const e = self.find(endpoint_id) orelse return Error.NoEndpoint;
            if (message.cap_count > max_caps) return Error.TooManyCaps;

            const decision = registry.use(cap_id, sender_pid, .{
                .object = .{ .kind = .endpoint, .id = endpoint_id },
                .rights = .{ .send = true },
            }, now_ns);
            if (!decision.ok()) return Error.Denied;

            var msg = message;
            msg.sender_pid = sender_pid;
            msg.sender_tid = sender_tid;
            msg.reply_to = if (mode == .synchronous) sender_tid else 0;
            try transferCaps(registry, &msg, sender_pid, e.owner, now_ns);
            try push(e, msg);

            if (e.blocked_receiver) |rtid| {
                e.blocked_receiver = null;
                scheduler.wake(rtid, now_ns) catch {};
            }

            if (mode == .synchronous) {
                const slot = self.allocReplySlot(sender_tid) orelse return Error.TableFull;
                slot.filled = false;
                // Запоминаем запрос: из него берётся pid вызвавшего при ответе.
                slot.msg = msg;
                scheduler.block(sender_tid) catch {};
            }
        }

        /// Приём. Требует права recv. Если очередь пуста — поток блокируется
        /// и вернётся сюда после пробуждения (получив null в этот раз).
        pub fn recv(
            self: *Self,
            registry: anytype,
            scheduler: anytype,
            receiver_pid: cap.ProcId,
            receiver_tid: u32,
            cap_id: cap.CapId,
            endpoint_id: EndpointId,
            now_ns: u64,
        ) Error!?Message {
            const e = self.find(endpoint_id) orelse return Error.NoEndpoint;

            const decision = registry.use(cap_id, receiver_pid, .{
                .object = .{ .kind = .endpoint, .id = endpoint_id },
                .rights = .{ .recv = true },
            }, now_ns);
            if (!decision.ok()) return Error.Denied;

            if (pop(e)) |msg| return msg;

            e.blocked_receiver = receiver_tid;
            scheduler.block(receiver_tid) catch {};
            return null;
        }

        /// Ответ на синхронный вызов: разблокирует вызвавший поток.
        pub fn reply(
            self: *Self,
            registry: anytype,
            scheduler: anytype,
            server_pid: cap.ProcId,
            cap_id: cap.CapId,
            endpoint_id: EndpointId,
            caller_tid: u32,
            message: Message,
            now_ns: u64,
        ) Error!void {
            const decision = registry.use(cap_id, server_pid, .{
                .object = .{ .kind = .endpoint, .id = endpoint_id },
                .rights = .{ .recv = true },
            }, now_ns);
            if (!decision.ok()) return Error.Denied;

            const slot = self.replySlot(caller_tid) orelse return Error.NoWaiter;
            var msg = message;
            msg.sender_pid = server_pid;
            // Токены в ответе тоже делегируются, а не копируются.
            const caller_pid = slot.msg.sender_pid;
            try transferCaps(registry, &msg, server_pid, if (caller_pid != 0) caller_pid else server_pid, now_ns);
            slot.msg = msg;
            slot.filled = true;
            scheduler.wake(caller_tid, now_ns) catch {};
        }

        /// Забрать пришедший ответ (вызывается разбуженным потоком).
        pub fn takeReply(self: *Self, caller_tid: u32) ?Message {
            const slot = self.replySlot(caller_tid) orelse return null;
            if (!slot.filled) return null;
            const m = slot.msg;
            slot.* = .{};
            return m;
        }
    };
}

// --- тесты ---------------------------------------------------------------

const testing = std.testing;
const sched_mod = @import("../sched/sched.zig");

const TestRegistry = cap.Registry(32, 128);
const TestSched = sched_mod.Scheduler(8);
const TestIpc = Ipc(4, 4, 4);

const Fixture = struct {
    reg: TestRegistry = .{},
    sched: TestSched = undefined,
    ipc: TestIpc = .{},
    ep: EndpointId = 0,
    server_cap: cap.CapId = 0,
    client_cap: cap.CapId = 0,
    server_tid: u32 = 0,
    client_tid: u32 = 0,

    const server_pid: cap.ProcId = 1;
    const client_pid: cap.ProcId = 2;

    fn setup(self: *Fixture) !void {
        self.sched = TestSched.init();
        self.ep = try self.ipc.create(server_pid);
        const obj = cap.Object{ .kind = .endpoint, .id = self.ep };
        self.server_cap = try self.reg.issueRoot(server_pid, obj, .{
            .recv = true,
            .send = true,
            .grant = true,
        }, .any, .{ .purpose = "владелец эндпоинта" }, 0);
        self.client_cap = try self.reg.derive(self.server_cap, server_pid, client_pid, .{ .send = true }, .any, .{ .purpose = "клиент сервиса" }, 0);
        self.server_tid = try self.sched.spawn(.{ .name = "server", .class = .normal });
        self.client_tid = try self.sched.spawn(.{ .name = "client", .class = .interactive });
    }
};

test "ipc: асинхронная отправка и приём" {
    var f = Fixture{};
    try f.setup();

    try f.ipc.send(&f.reg, &f.sched, Fixture.client_pid, f.client_tid, f.client_cap, f.ep, Message.withBytes(7, "привет"), .asynchronous, 0);
    try testing.expectEqual(@as(usize, 1), f.ipc.queueLen(f.ep));

    const got = (try f.ipc.recv(&f.reg, &f.sched, Fixture.server_pid, f.server_tid, f.server_cap, f.ep, 0)).?;
    try testing.expectEqual(@as(u32, 7), got.tag);
    try testing.expectEqualStrings("привет", got.payload());
    try testing.expectEqual(Fixture.client_pid, got.sender_pid);
}

test "ipc: без capability отправка запрещена (FR-1.3, FR-2.1)" {
    var f = Fixture{};
    try f.setup();

    // Чужой процесс с чужим токеном.
    try testing.expectError(Error.Denied, f.ipc.send(&f.reg, &f.sched, 99, 5, f.client_cap, f.ep, .{}, .asynchronous, 0));
    // Клиентский токен не даёт права приёма.
    try testing.expectError(Error.Denied, f.ipc.recv(&f.reg, &f.sched, Fixture.client_pid, f.client_tid, f.client_cap, f.ep, 0));
    // Отказы зафиксированы в аудите.
    try testing.expect(f.reg.log.count() >= 2);
}

test "ipc: истёкший токен перестаёт работать" {
    var f = Fixture{};
    f.ep = try f.ipc.create(Fixture.server_pid);
    const obj = cap.Object{ .kind = .endpoint, .id = f.ep };
    const root = try f.reg.issueRoot(Fixture.server_pid, obj, .{ .send = true, .recv = true, .grant = true }, .any, .{}, 0);
    const short = try f.reg.derive(root, Fixture.server_pid, Fixture.client_pid, .{ .send = true }, .any, .{ .lifetime_ns = 1000 }, 0);
    f.client_tid = try f.sched.spawn(.{ .name = "client", .class = .normal });

    try f.ipc.send(&f.reg, &f.sched, Fixture.client_pid, f.client_tid, short, f.ep, .{}, .asynchronous, 500);
    try testing.expectError(Error.Denied, f.ipc.send(&f.reg, &f.sched, Fixture.client_pid, f.client_tid, short, f.ep, .{}, .asynchronous, 1500));
}

test "ipc: синхронный вызов блокирует клиента до ответа" {
    var f = Fixture{};
    try f.setup();

    try f.ipc.send(&f.reg, &f.sched, Fixture.client_pid, f.client_tid, f.client_cap, f.ep, Message.withBytes(1, "ping"), .synchronous, 0);
    try testing.expectEqual(sched_mod.State.blocked, f.sched.task(f.client_tid).?.state);

    const req = (try f.ipc.recv(&f.reg, &f.sched, Fixture.server_pid, f.server_tid, f.server_cap, f.ep, 0)).?;
    try testing.expectEqual(f.client_tid, req.reply_to);

    try f.ipc.reply(&f.reg, &f.sched, Fixture.server_pid, f.server_cap, f.ep, req.reply_to, Message.withBytes(2, "pong"), ms);
    try testing.expectEqual(sched_mod.State.ready, f.sched.task(f.client_tid).?.state);

    const answer = f.ipc.takeReply(f.client_tid).?;
    try testing.expectEqualStrings("pong", answer.payload());
    try testing.expectEqual(@as(?Message, null), f.ipc.takeReply(f.client_tid));
}

test "ipc: пустая очередь блокирует получателя, отправка будит" {
    var f = Fixture{};
    try f.setup();

    const nothing = try f.ipc.recv(&f.reg, &f.sched, Fixture.server_pid, f.server_tid, f.server_cap, f.ep, 0);
    try testing.expectEqual(@as(?Message, null), nothing);
    try testing.expectEqual(sched_mod.State.blocked, f.sched.task(f.server_tid).?.state);

    try f.ipc.send(&f.reg, &f.sched, Fixture.client_pid, f.client_tid, f.client_cap, f.ep, .{}, .asynchronous, ms);
    try testing.expectEqual(sched_mod.State.ready, f.sched.task(f.server_tid).?.state);
}

test "ipc: переполнение очереди даёт обратное давление" {
    var f = Fixture{};
    try f.setup();
    for (0..4) |_| {
        try f.ipc.send(&f.reg, &f.sched, Fixture.client_pid, f.client_tid, f.client_cap, f.ep, .{}, .asynchronous, 0);
    }
    try testing.expectError(Error.QueueFull, f.ipc.send(&f.reg, &f.sched, Fixture.client_pid, f.client_tid, f.client_cap, f.ep, .{}, .asynchronous, 0));
}

test "ipc: передача токена в сообщении делегирует, а не копирует" {
    var f = Fixture{};
    try f.setup();

    // У сервера есть токен на файл, который он отдаёт клиенту через IPC.
    const file = cap.Object{ .kind = .file, .id = 77 };
    const file_cap = try f.reg.issueRoot(Fixture.client_pid, file, .{ .read = true, .grant = true }, .{ .fs = cap.Path.from("/home/user/Documents") }, .{}, 0);

    var msg = Message.withBytes(3, "вот файл");
    msg.caps[0] = file_cap;
    msg.cap_count = 1;

    try f.ipc.send(&f.reg, &f.sched, Fixture.client_pid, f.client_tid, f.client_cap, f.ep, msg, .asynchronous, 0);
    const got = (try f.ipc.recv(&f.reg, &f.sched, Fixture.server_pid, f.server_tid, f.server_cap, f.ep, 0)).?;

    const delivered = got.caps[0];
    try testing.expect(delivered != file_cap);
    const child = f.reg.get(delivered).?;
    try testing.expectEqual(Fixture.server_pid, child.holder);
    try testing.expectEqual(@as(?cap.CapId, file_cap), child.parent);

    // Отзыв исходного токена гасит и переданный.
    _ = f.reg.revoke(file_cap, 0);
    try testing.expectEqual(cap.Decision.revoked, f.reg.use(delivered, Fixture.server_pid, .{
        .object = file,
        .rights = .{ .read = true },
        .path = "/home/user/Documents/a",
    }, 0));
}

test "ipc: без права grant токен переслать нельзя" {
    var f = Fixture{};
    try f.setup();

    const file = cap.Object{ .kind = .file, .id = 78 };
    const no_grant = try f.reg.issueRoot(Fixture.client_pid, file, .{ .read = true }, .any, .{}, 0);
    var msg = Message{};
    msg.caps[0] = no_grant;
    msg.cap_count = 1;

    try testing.expectError(Error.TransferFailed, f.ipc.send(&f.reg, &f.sched, Fixture.client_pid, f.client_tid, f.client_cap, f.ep, msg, .asynchronous, 0));
}

const ms = 1_000_000;
