//! Capability-based security (spec section 4.2).
//!
//! FR-2.1: every access to a file, socket or device goes through a token.
//! FR-2.2: a token can be limited by lifetime, use count and scope.
//! FR-2.3: every grant, use and denial lands in the audit log.
//!
//! Key property: a derived token can NEVER be wider than its parent
//! (rights, scope and lifetime attenuate). Enforced in `derive`, covered by tests.

const std = @import("std");
const audit = @import("audit.zig");

pub const CapId = u64;
pub const ProcId = u32;
pub const Decision = audit.Decision;

pub const Error = error{
    NoSuchCapability,
    NotHolder,
    NotGrantable,
    RightsEscalation,
    ScopeEscalation,
    LifetimeEscalation,
    Revoked,
    Expired,
    TableFull,
};

// --- rights ---------------------------------------------------------------

pub const Rights = packed struct(u16) {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    create: bool = false,
    delete: bool = false,
    list: bool = false,
    map: bool = false,
    send: bool = false,
    recv: bool = false,
    /// Right to delegate (create derived tokens).
    grant: bool = false,
    /// Right to revoke derived tokens.
    revoke: bool = false,
    /// Administrative operations on the object (ownership, attributes).
    admin: bool = false,
    _pad: u4 = 0,

    pub fn bits(self: Rights) u16 {
        return @bitCast(self);
    }

    pub fn from(value: u16) Rights {
        return @bitCast(value);
    }

    pub fn isEmpty(self: Rights) bool {
        return self.bits() == 0;
    }

    /// Whether self is a subset of other.
    pub fn subsetOf(self: Rights, other: Rights) bool {
        return self.bits() & ~other.bits() == 0;
    }

    pub fn intersect(self: Rights, other: Rights) Rights {
        return from(self.bits() & other.bits());
    }

    pub fn contains(self: Rights, needed: Rights) bool {
        return needed.subsetOf(self);
    }

    pub const none = Rights{};
    pub const ro = Rights{ .read = true, .list = true };
    pub const rw = Rights{ .read = true, .write = true, .list = true, .create = true };
};

// --- objects --------------------------------------------------------------

pub const ObjectKind = enum(u8) {
    file,
    directory,
    device,
    socket,
    endpoint,
    memory,
    process,
    clock,
};

pub const Object = struct {
    kind: ObjectKind,
    /// 0 = "any object of this kind within the scope" (e.g. a filesystem subtree).
    id: u64 = 0,

    pub fn matches(self: Object, target: Object) bool {
        if (self.kind != target.kind) return false;
        return self.id == 0 or self.id == target.id;
    }
};

// --- scopes ---------------------------------------------------------------

pub const max_path = 96;

pub const Path = struct {
    buf: [max_path]u8 = @splat(0),
    len: u8 = 0,

    pub fn from(source: []const u8) Path {
        var p = Path{};
        var trimmed = source;
        while (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
        const n = @min(trimmed.len, max_path);
        @memcpy(p.buf[0..n], trimmed[0..n]);
        p.len = @intCast(n);
        return p;
    }

    pub fn text(self: *const Path) []const u8 {
        return self.buf[0..self.len];
    }

    /// Whether this prefix covers path `other` (on component boundaries).
    pub fn covers(self: *const Path, other: []const u8) bool {
        const prefix = self.text();
        if (prefix.len == 0) return true;
        if (other.len < prefix.len) return false;
        if (!std.mem.eql(u8, prefix, other[0..prefix.len])) return false;
        if (other.len == prefix.len) return true;
        // "/a" covers "/a/b" but not "/ab"
        if (prefix[prefix.len - 1] == '/') return true;
        return other[prefix.len] == '/';
    }

    pub fn coversPath(self: *const Path, other: *const Path) bool {
        return self.covers(other.text());
    }
};

pub const DeviceClass = enum(u8) {
    any,
    block,
    net,
    input,
    display,
    audio,
    sensor,
    gpu,
};

pub const NetScope = struct {
    host: Path = .{},
    port_lo: u16 = 0,
    port_hi: u16 = 65535,

    pub fn covers(self: NetScope, other: NetScope) bool {
        if (other.port_lo < self.port_lo or other.port_hi > self.port_hi) return false;
        return self.host.coversPath(&other.host);
    }

    pub fn allows(self: NetScope, host: []const u8, port: u16) bool {
        if (port < self.port_lo or port > self.port_hi) return false;
        return self.host.covers(host);
    }
};

pub const Scope = union(enum) {
    /// Unrestricted (kernel root tokens only).
    any,
    /// A filesystem subtree.
    fs: Path,
    /// Network access.
    net: NetScope,
    /// A device class.
    device: DeviceClass,

    /// Whether `other` is a subset of self (the attenuation condition).
    pub fn covers(self: Scope, other: Scope) bool {
        return switch (self) {
            .any => true,
            .fs => |p| switch (other) {
                .fs => |q| p.coversPath(&q),
                else => false,
            },
            .net => |n| switch (other) {
                .net => |m| n.covers(m),
                else => false,
            },
            .device => |c| switch (other) {
                .device => |d| c == .any or c == d,
                else => false,
            },
        };
    }

    /// Whether the scope permits a concrete access.
    pub fn allows(self: Scope, access: Access) bool {
        return switch (self) {
            .any => true,
            .fs => |p| p.covers(access.path),
            .net => |n| n.allows(access.path, access.port),
            .device => |c| c == .any or c == access.device_class,
        };
    }
};

/// A concrete access to be checked against a token.
pub const Access = struct {
    object: Object,
    rights: Rights,
    path: []const u8 = "",
    port: u16 = 0,
    device_class: DeviceClass = .any,
};

// --- the token itself -----------------------------------------------------

pub const State = enum(u8) { active, revoked, expired };

pub const Capability = struct {
    id: CapId,
    parent: ?CapId = null,
    holder: ProcId,
    issuer: ProcId,
    object: Object,
    rights: Rights,
    scope: Scope,
    issued_at_ns: u64 = 0,
    /// null = never expires.
    expires_at_ns: ?u64 = null,
    /// null = unlimited number of uses.
    uses_left: ?u32 = null,
    use_count: u32 = 0,
    state: State = .active,
    purpose: [48]u8 = @splat(0),
    purpose_len: u8 = 0,

    pub fn purposeText(self: *const Capability) []const u8 {
        return self.purpose[0..self.purpose_len];
    }

    pub fn isLive(self: *const Capability, now_ns: u64) bool {
        if (self.state != .active) return false;
        if (self.expires_at_ns) |t| if (now_ns >= t) return false;
        if (self.uses_left) |n| if (n == 0) return false;
        return true;
    }

    /// Nanoseconds left to live (for the user panel).
    pub fn remainingNs(self: *const Capability, now_ns: u64) ?u64 {
        const t = self.expires_at_ns orelse return null;
        return if (now_ns >= t) 0 else t - now_ns;
    }
};

pub const GrantOptions = struct {
    /// Lifetime from the moment of grant. null = never expires (root tokens).
    lifetime_ns: ?u64 = null,
    /// Maximum number of uses.
    max_uses: ?u32 = null,
    /// Why it was granted; shown in the audit log and in the user panel.
    purpose: []const u8 = "",
};

// --- registry -------------------------------------------------------------

pub fn Registry(comptime capacity: usize, comptime audit_capacity: usize) type {
    return struct {
        const Self = @This();
        pub const AuditLog = audit.Log(audit_capacity);

        slots: [capacity]?Capability = @splat(null),
        next_id: CapId = 1,
        log: AuditLog = .{},

        pub fn init() Self {
            return .{};
        }

        fn slotOf(self: *Self, id: CapId) ?*Capability {
            for (&self.slots) |*slot| {
                if (slot.*) |*cap| {
                    if (cap.id == id) return cap;
                }
            }
            return null;
        }

        pub fn get(self: *Self, id: CapId) ?*Capability {
            return self.slotOf(id);
        }

        pub fn count(self: *const Self) usize {
            var n: usize = 0;
            for (self.slots) |slot| {
                if (slot != null) n += 1;
            }
            return n;
        }

        fn insert(self: *Self, cap: Capability) Error!*Capability {
            for (&self.slots) |*slot| {
                if (slot.* == null) {
                    slot.* = cap;
                    return &slot.*.?;
                }
            }
            return Error.TableFull;
        }

        fn logEntry(self: *Self, kind: audit.EventKind, decision: Decision, cap: *const Capability, now_ns: u64) void {
            _ = self.log.record(.{
                .ts_ns = now_ns,
                .kind = kind,
                .decision = decision,
                .cap = cap.id,
                .parent = cap.parent orelse 0,
                .holder = cap.holder,
                .object_kind = @intFromEnum(cap.object.kind),
                .object_id = cap.object.id,
                .rights = cap.rights.bits(),
                .purpose = cap.purpose,
                .purpose_len = cap.purpose_len,
            });
        }

        /// Root token. Issued only by the kernel at boot (or by a trusted
        /// service that already holds an admin token on this object).
        pub fn issueRoot(
            self: *Self,
            holder: ProcId,
            object: Object,
            rights: Rights,
            scope: Scope,
            opts: GrantOptions,
            now_ns: u64,
        ) Error!CapId {
            const p = audit.makePurpose(opts.purpose);
            var cap = Capability{
                .id = self.next_id,
                .parent = null,
                .holder = holder,
                .issuer = 0,
                .object = object,
                .rights = rights,
                .scope = scope,
                .issued_at_ns = now_ns,
                .expires_at_ns = if (opts.lifetime_ns) |l| now_ns + l else null,
                .uses_left = opts.max_uses,
                .purpose = p.buf,
                .purpose_len = p.len,
            };
            const stored = try self.insert(cap);
            self.next_id += 1;
            cap = stored.*;
            self.logEntry(.issued, .allow, stored, now_ns);
            return stored.id;
        }

        /// Derived token. Strictly no wider than its parent (FR-2.2).
        pub fn derive(
            self: *Self,
            parent_id: CapId,
            from_holder: ProcId,
            to_holder: ProcId,
            rights: Rights,
            scope: Scope,
            opts: GrantOptions,
            now_ns: u64,
        ) Error!CapId {
            const parent = self.slotOf(parent_id) orelse return Error.NoSuchCapability;
            if (parent.holder != from_holder) return Error.NotHolder;
            if (parent.state == .revoked) return Error.Revoked;
            if (!parent.isLive(now_ns)) {
                parent.state = .expired;
                self.logEntry(.expired, .expired, parent, now_ns);
                return Error.Expired;
            }
            if (!parent.rights.grant) return Error.NotGrantable;
            if (!rights.subsetOf(parent.rights)) return Error.RightsEscalation;
            if (!parent.scope.covers(scope)) return Error.ScopeEscalation;

            // Lifetime: never later than the parent's.
            var expires: ?u64 = if (opts.lifetime_ns) |l| now_ns + l else null;
            if (parent.expires_at_ns) |pt| {
                if (expires) |t| {
                    if (t > pt) return Error.LifetimeEscalation;
                } else {
                    // A never-expiring child of an expiring parent is not
                    // allowed: clamp it to the parent's deadline.
                    expires = pt;
                }
            }

            // Uses: never more than the parent has left.
            var uses = opts.max_uses;
            if (parent.uses_left) |left| {
                uses = if (uses) |u| @min(u, left) else left;
            }

            const p = audit.makePurpose(opts.purpose);
            const child = Capability{
                .id = self.next_id,
                .parent = parent_id,
                .holder = to_holder,
                .issuer = from_holder,
                .object = parent.object,
                .rights = rights,
                .scope = scope,
                .issued_at_ns = now_ns,
                .expires_at_ns = expires,
                .uses_left = uses,
                .purpose = p.buf,
                .purpose_len = p.len,
            };
            const stored = try self.insert(child);
            self.next_id += 1;
            self.logEntry(.derived, .allow, stored, now_ns);
            return stored.id;
        }

        /// Side-effect-free check (apart from marking expired tokens).
        pub fn evaluate(self: *Self, id: CapId, holder: ProcId, access: Access, now_ns: u64) Decision {
            const cap = self.slotOf(id) orelse return .no_cap;
            if (cap.holder != holder) return .wrong_holder;
            if (cap.state == .revoked) return .revoked;
            if (cap.expires_at_ns) |t| {
                if (now_ns >= t) return .expired;
            }
            if (cap.uses_left) |n| {
                if (n == 0) return .exhausted;
            }
            if (!cap.object.matches(access.object)) return .wrong_object;
            if (!cap.rights.contains(access.rights)) return .missing_rights;
            if (!cap.scope.allows(access)) return .out_of_scope;
            return .allow;
        }

        /// Check + use accounting + audit record.
        /// This is what runs on every access to an object (FR-2.1).
        pub fn use(self: *Self, id: CapId, holder: ProcId, access: Access, now_ns: u64) Decision {
            const decision = self.evaluate(id, holder, access, now_ns);
            if (self.slotOf(id)) |cap| {
                switch (decision) {
                    .allow => {
                        cap.use_count += 1;
                        if (cap.uses_left) |n| cap.uses_left = n - 1;
                        self.logEntry(.used, .allow, cap, now_ns);
                    },
                    .expired => {
                        cap.state = .expired;
                        self.logEntry(.expired, .expired, cap, now_ns);
                    },
                    .exhausted => {
                        cap.state = .expired;
                        self.logEntry(.expired, .exhausted, cap, now_ns);
                    },
                    else => self.logEntry(.denied, decision, cap, now_ns),
                }
            } else {
                _ = self.log.record(.{
                    .ts_ns = now_ns,
                    .kind = .denied,
                    .decision = .no_cap,
                    .cap = id,
                    .holder = holder,
                    .object_kind = @intFromEnum(access.object.kind),
                    .object_id = access.object.id,
                    .rights = access.rights.bits(),
                });
            }
            return decision;
        }

        /// Revoke a token together with its whole derived subtree (FR-2.3).
        pub fn revoke(self: *Self, id: CapId, now_ns: u64) usize {
            var revoked: usize = 0;
            const target = self.slotOf(id) orelse return 0;
            if (target.state != .revoked) {
                target.state = .revoked;
                self.logEntry(.revoked, .revoked, target, now_ns);
                revoked += 1;
            }
            // Children may have been issued after the parent, so iterate until
            // the set stabilises: the tree is small and shallow.
            var changed = true;
            while (changed) {
                changed = false;
                for (&self.slots) |*slot| {
                    if (slot.*) |*cap| {
                        if (cap.state == .revoked) continue;
                        const parent_id = cap.parent orelse continue;
                        const parent = self.slotOf(parent_id) orelse continue;
                        if (parent.state == .revoked) {
                            cap.state = .revoked;
                            self.logEntry(.revoked, .revoked, cap, now_ns);
                            revoked += 1;
                            changed = true;
                        }
                    }
                }
            }
            return revoked;
        }

        /// Revoke everything a process holds (e.g. when it terminates).
        pub fn revokeAllOf(self: *Self, holder: ProcId, now_ns: u64) usize {
            var n: usize = 0;
            for (&self.slots) |*slot| {
                if (slot.*) |*cap| {
                    if (cap.holder == holder and cap.state != .revoked) {
                        n += self.revoke(cap.id, now_ns);
                    }
                }
            }
            return n;
        }

        /// Mark expired tokens (periodic sweep).
        pub fn sweepExpired(self: *Self, now_ns: u64) usize {
            var n: usize = 0;
            for (&self.slots) |*slot| {
                if (slot.*) |*cap| {
                    if (cap.state == .active and !cap.isLive(now_ns)) {
                        cap.state = .expired;
                        self.logEntry(.expired, .expired, cap, now_ns);
                        n += 1;
                    }
                }
            }
            return n;
        }

        /// Free the slots of revoked and expired tokens.
        pub fn compact(self: *Self) usize {
            var freed: usize = 0;
            for (&self.slots) |*slot| {
                if (slot.*) |cap| {
                    if (cap.state != .active) {
                        // Keep it while live children exist: they point at parent.
                        if (!self.hasLiveChildren(cap.id)) {
                            slot.* = null;
                            freed += 1;
                        }
                    }
                }
            }
            return freed;
        }

        fn hasLiveChildren(self: *Self, id: CapId) bool {
            for (self.slots) |slot| {
                if (slot) |cap| {
                    if (cap.parent == id and cap.state == .active) return true;
                }
            }
            return false;
        }

        /// A process's tokens: what the user sees in the panel.
        pub fn forHolder(self: *Self, holder: ProcId, out: []CapId) usize {
            var n: usize = 0;
            for (self.slots) |slot| {
                if (slot) |cap| {
                    if (cap.holder == holder and n < out.len) {
                        out[n] = cap.id;
                        n += 1;
                    }
                }
            }
            return n;
        }
    };
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;
const TestRegistry = Registry(32, 64);

const ms = 1_000_000;
const minute = 60 * 1_000 * ms;

const documents = Object{ .kind = .directory, .id = 0 };

fn rootFsCap(reg: *TestRegistry, holder: ProcId, now: u64) !CapId {
    return reg.issueRoot(holder, documents, .{
        .read = true,
        .write = true,
        .list = true,
        .create = true,
        .delete = true,
        .grant = true,
        .revoke = true,
    }, .{ .fs = Path.from("/home/user") }, .{ .purpose = "user home root access" }, now);
}

test "cap: no token means no access (FR-2.1)" {
    var reg = TestRegistry.init();
    const d = reg.use(999, 1, .{
        .object = documents,
        .rights = .{ .read = true },
        .path = "/home/user/Documents/a.txt",
    }, 0);
    try testing.expectEqual(Decision.no_cap, d);
    try testing.expectEqual(@as(usize, 1), reg.log.count());
    try testing.expectEqual(Decision.no_cap, reg.log.last().?.decision);
}

test "cap: a root token allows access inside its scope" {
    var reg = TestRegistry.init();
    const root = try rootFsCap(&reg, 1, 0);
    try testing.expectEqual(Decision.allow, reg.use(root, 1, .{
        .object = documents,
        .rights = .{ .read = true },
        .path = "/home/user/Documents/a.txt",
    }, 0));
    try testing.expectEqual(Decision.out_of_scope, reg.use(root, 1, .{
        .object = documents,
        .rights = .{ .read = true },
        .path = "/etc/shadow",
    }, 0));
}

test "cap: another process cannot use someone else's token" {
    var reg = TestRegistry.init();
    const root = try rootFsCap(&reg, 1, 0);
    try testing.expectEqual(Decision.wrong_holder, reg.use(root, 2, .{
        .object = documents,
        .rights = .{ .read = true },
        .path = "/home/user/a.txt",
    }, 0));
}

test "cap: a derived token cannot widen rights, scope or lifetime" {
    var reg = TestRegistry.init();
    const root = try reg.issueRoot(1, documents, .{ .read = true, .list = true, .grant = true }, .{ .fs = Path.from("/home/user") }, .{ .lifetime_ns = 10 * minute }, 0);

    // Rights wider than the parent's.
    try testing.expectError(Error.RightsEscalation, reg.derive(root, 1, 2, .{ .read = true, .write = true }, .{ .fs = Path.from("/home/user") }, .{}, 0));

    // Scope wider than the parent's.
    try testing.expectError(Error.ScopeEscalation, reg.derive(root, 1, 2, .{ .read = true }, .{ .fs = Path.from("/home") }, .{}, 0));

    // Lifetime longer than the parent's.
    try testing.expectError(Error.LifetimeEscalation, reg.derive(root, 1, 2, .{ .read = true }, .{ .fs = Path.from("/home/user") }, .{ .lifetime_ns = 20 * minute }, 0));

    // Only the holder may delegate.
    try testing.expectError(Error.NotHolder, reg.derive(root, 7, 2, .{ .read = true }, .{ .fs = Path.from("/home/user") }, .{}, 0));
}

test "cap: 10-minute AI agent token for /home/user/Documents (FR-2.2)" {
    var reg = TestRegistry.init();
    const now: u64 = 1_000 * ms;
    const root = try rootFsCap(&reg, 1, now);

    const agent: ProcId = 42;
    const agent_cap = try reg.derive(root, 1, agent, .{ .read = true, .list = true }, .{ .fs = Path.from("/home/user/Documents") }, .{
        .lifetime_ns = 10 * minute,
        .purpose = "index Documents for task X",
    }, now);

    const read_doc = Access{
        .object = documents,
        .rights = .{ .read = true },
        .path = "/home/user/Documents/report.md",
    };

    // Inside the lifetime and the scope: allowed.
    try testing.expectEqual(Decision.allow, reg.use(agent_cap, agent, read_doc, now + minute));

    // Outside the scope: denied, even within the lifetime.
    try testing.expectEqual(Decision.out_of_scope, reg.use(agent_cap, agent, .{
        .object = documents,
        .rights = .{ .read = true },
        .path = "/home/user/.ssh/id_ed25519",
    }, now + minute));

    // Write was never granted.
    try testing.expectEqual(Decision.missing_rights, reg.use(agent_cap, agent, .{
        .object = documents,
        .rights = .{ .write = true },
        .path = "/home/user/Documents/report.md",
    }, now + minute));

    // After 10 minutes the token is dead.
    try testing.expectEqual(Decision.expired, reg.use(agent_cap, agent, read_doc, now + 10 * minute));
    try testing.expectEqual(State.expired, reg.get(agent_cap).?.state);

    // The parent token keeps working.
    try testing.expectEqual(Decision.allow, reg.use(root, 1, read_doc, now + 11 * minute));

    // The audit log holds the grant, the use, both denials and the expiry.
    try testing.expect(reg.log.countForCap(agent_cap) >= 5);
}

test "cap: use-count limit" {
    var reg = TestRegistry.init();
    const root = try rootFsCap(&reg, 1, 0);
    const once = try reg.derive(root, 1, 5, .{ .read = true }, .{ .fs = Path.from("/home/user/Documents") }, .{ .max_uses = 2 }, 0);
    const access = Access{ .object = documents, .rights = .{ .read = true }, .path = "/home/user/Documents/x" };
    try testing.expectEqual(Decision.allow, reg.use(once, 5, access, 0));
    try testing.expectEqual(Decision.allow, reg.use(once, 5, access, 0));
    try testing.expectEqual(Decision.exhausted, reg.use(once, 5, access, 0));
}

test "cap: revocation cascades over the whole subtree (FR-2.3)" {
    var reg = TestRegistry.init();
    const root = try rootFsCap(&reg, 1, 0);
    const shell = try reg.derive(root, 1, 2, .{ .read = true, .list = true, .grant = true }, .{ .fs = Path.from("/home/user/Documents") }, .{}, 0);
    const agent = try reg.derive(shell, 2, 3, .{ .read = true }, .{ .fs = Path.from("/home/user/Documents/notes") }, .{}, 0);

    const access = Access{ .object = documents, .rights = .{ .read = true }, .path = "/home/user/Documents/notes/a.md" };
    try testing.expectEqual(Decision.allow, reg.use(agent, 3, access, 0));

    const n = reg.revoke(shell, 0);
    try testing.expectEqual(@as(usize, 2), n); // shell + agent
    try testing.expectEqual(Decision.revoked, reg.use(agent, 3, access, 0));
    try testing.expectEqual(Decision.allow, reg.use(root, 1, access, 0)); // parent still alive
}

test "cap: a child of an expiring parent cannot be eternal" {
    var reg = TestRegistry.init();
    const root = try reg.issueRoot(1, documents, .{ .read = true, .grant = true }, .{ .fs = Path.from("/home/user") }, .{ .lifetime_ns = 5 * minute }, 0);
    const child = try reg.derive(root, 1, 2, .{ .read = true }, .{ .fs = Path.from("/home/user") }, .{}, 0);
    try testing.expectEqual(@as(?u64, 5 * minute), reg.get(child).?.expires_at_ns);
}

test "cap: delegation is refused without the grant right" {
    var reg = TestRegistry.init();
    const root = try reg.issueRoot(1, documents, .{ .read = true }, .{ .fs = Path.from("/home/user") }, .{}, 0);
    try testing.expectError(Error.NotGrantable, reg.derive(root, 1, 2, .{ .read = true }, .{ .fs = Path.from("/home/user") }, .{}, 0));
}

test "cap: a path prefix does not match a lookalike name" {
    const p = Path.from("/home/user/Documents");
    try testing.expect(p.covers("/home/user/Documents"));
    try testing.expect(p.covers("/home/user/Documents/a/b.txt"));
    try testing.expect(!p.covers("/home/user/Documents2/secret"));
    try testing.expect(!p.covers("/home/user"));
}

test "cap: a network scope limits host and ports" {
    var reg = TestRegistry.init();
    const sock = Object{ .kind = .socket, .id = 0 };
    const root = try reg.issueRoot(1, sock, .{ .send = true, .recv = true, .grant = true }, .{ .net = .{ .host = Path.from("api.example.com"), .port_lo = 443, .port_hi = 443 } }, .{}, 0);
    try testing.expectEqual(Decision.allow, reg.use(root, 1, .{ .object = sock, .rights = .{ .send = true }, .path = "api.example.com", .port = 443 }, 0));
    try testing.expectEqual(Decision.out_of_scope, reg.use(root, 1, .{ .object = sock, .rights = .{ .send = true }, .path = "api.example.com", .port = 8080 }, 0));
    try testing.expectEqual(Decision.out_of_scope, reg.use(root, 1, .{ .object = sock, .rights = .{ .send = true }, .path = "evil.example.com", .port = 443 }, 0));
}

test "cap: the user panel sees a process's tokens" {
    var reg = TestRegistry.init();
    const root = try rootFsCap(&reg, 1, 0);
    _ = try reg.derive(root, 1, 42, .{ .read = true }, .{ .fs = Path.from("/home/user/Documents") }, .{ .purpose = "task X" }, 0);
    _ = try reg.derive(root, 1, 42, .{ .list = true }, .{ .fs = Path.from("/home/user/Music") }, .{ .purpose = "task Y" }, 0);

    var ids: [8]CapId = undefined;
    const n = reg.forHolder(42, &ids);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("task X", reg.get(ids[0]).?.purposeText());
}
