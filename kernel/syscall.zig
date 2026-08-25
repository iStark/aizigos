//! The system call boundary.
//!
//! Every call arrives through the HAL (an `svc` on AArch64, `int 0x80` on
//! x86_64), and every call that touches an object goes through a capability
//! check first — that is FR-2.1 at the one place where it can be enforced.
//!
//! There is no user mode yet, so today the callers are kernel threads. The
//! shape is the one user processes will use, which is the point: when ring 3
//! arrives, the checks are already here rather than bolted on afterwards.

const builtin = @import("builtin");
const hal = @import("hal/hal.zig");
const cap = @import("cap/cap.zig");
const klog = @import("klog.zig");

pub const Number = enum(u64) {
    /// a0 = pointer, a1 = length. Returns bytes written.
    write = 0,
    /// Give up the rest of the time slice.
    yield = 1,
    /// a0 = milliseconds.
    sleep_ms = 2,
    /// Returns the monotonic clock in nanoseconds.
    time_ns = 3,
    /// a0 = capability id, a1 = path pointer, a2 = (length << 8) | rights bits.
    /// Returns a `cap.Decision` as an integer.
    fs_access = 4,
    /// Returns how many records the audit log holds.
    audit_len = 5,
    /// Returns the id of the calling thread.
    task_id = 6,
    /// a0 = a value the caller wants noted. Reports it, and whether the call
    /// came from user mode, which is how a user program proves it is one.
    report = 7,
    _,
};

/// Errors come back with the top bit set, so a plain result can use the whole
/// lower range without a sign convention.
pub const err_bit: u64 = 1 << 63;

pub const Error = enum(u64) {
    bad_number = 1,
    bad_argument = 2,
    denied = 3,
    no_caller = 4,
};

pub fn fail(e: Error) u64 {
    return err_bit | @intFromEnum(e);
}

pub fn failed(result: u64) bool {
    return result & err_bit != 0;
}

/// Issue a system call. On a real target this traps; on the host it calls the
/// handler directly, so the same code path is exercised by the tests.
pub inline fn invoke(number: Number, a0: u64, a1: u64, a2: u64) u64 {
    const n = @intFromEnum(number);
    if (builtin.os.tag != .freestanding and builtin.os.tag != .uefi) {
        return hal.impl.testSyscall(n, a0, a1, a2);
    }
    return switch (builtin.cpu.arch) {
        .aarch64 => asm volatile ("svc #0"
            : [ret] "={x0}" (-> u64),
            : [number] "{x8}" (n),
              [arg0] "{x0}" (a0),
              [arg1] "{x1}" (a1),
              [arg2] "{x2}" (a2),
            : .{ .memory = true }),
        .x86_64 => asm volatile ("int $0x80"
            : [ret] "={rax}" (-> u64),
            : [number] "{rax}" (n),
              [arg0] "{rdi}" (a0),
              [arg1] "{rsi}" (a1),
              [arg2] "{rdx}" (a2),
            : .{ .memory = true }),
        else => fail(.bad_number),
    };
}

// --- the part that can be tested without a kernel around it ---------------

/// Decode the packed third argument of `fs_access`.
pub fn unpackAccess(a2: u64) struct { len: usize, rights: cap.Rights } {
    return .{
        .len = @intCast(a2 >> 8),
        .rights = cap.Rights.from(@truncate(a2 & 0xFF)),
    };
}

pub fn packAccess(len: usize, rights: cap.Rights) u64 {
    return (@as(u64, len) << 8) | (rights.bits() & 0xFF);
}

/// The capability check behind `fs_access`, with the registry passed in so it
/// can be exercised on its own.
pub fn checkFsAccess(
    registry: anytype,
    pid: cap.ProcId,
    cap_id: cap.CapId,
    path: []const u8,
    rights: cap.Rights,
    now_ns: u64,
) cap.Decision {
    return registry.use(cap_id, pid, .{
        .object = .{ .kind = .directory },
        .rights = rights,
        .path = path,
    }, now_ns);
}

// --- the dispatcher -------------------------------------------------------

/// Installed into the HAL by the kernel at boot.
pub fn dispatch(number: u64, a0: u64, a1: u64, a2: u64, from_user: bool) u64 {
    const root = @import("root");
    const call: Number = @enumFromInt(number);
    return switch (call) {
        .write => blk: {
            if (a1 == 0) break :blk 0;
            if (a0 == 0) break :blk fail(.bad_argument);
            const bytes: [*]const u8 = @ptrFromInt(a0);
            // When callers live in their own address space this is where the
            // buffer gets validated with AddressSpace.checkAccess.
            hal.consoleWrite(bytes[0..@intCast(a1)]);
            break :blk a1;
        },
        .yield => blk: {
            root.yield();
            break :blk 0;
        },
        .sleep_ms => blk: {
            root.sleepMs(a0);
            break :blk 0;
        },
        .time_ns => hal.nowNs(),
        .fs_access => blk: {
            const caller = callerPid() orelse break :blk fail(.no_caller);
            if (a1 == 0) break :blk fail(.bad_argument);
            const unpacked = unpackAccess(a2);
            if (unpacked.len == 0 or unpacked.len > cap.max_path) break :blk fail(.bad_argument);
            const path_ptr: [*]const u8 = @ptrFromInt(a1);
            const decision = checkFsAccess(
                &root.registry,
                caller,
                a0,
                path_ptr[0..unpacked.len],
                unpacked.rights,
                hal.nowNs(),
            );
            break :blk @intFromEnum(decision);
        },
        .report => blk: {
            klog.info("thread {d} reports 0x{x}, privileged: {b}", .{
                root.scheduler.current orelse 0,
                a0,
                !from_user,
            });
            break :blk 0;
        },
        .audit_len => root.registry.log.count(),
        .task_id => if (root.scheduler.current) |tid| tid else fail(.no_caller),
        _ => fail(.bad_number),
    };
}

/// Which process the calling thread belongs to. Without this a capability
/// check has no subject, and "any access goes through a token" means nothing.
fn callerPid() ?cap.ProcId {
    const root = @import("root");
    const tid = root.scheduler.current orelse return null;
    return root.processes.ownerOf(tid);
}

// --- tests ---------------------------------------------------------------

const testing = @import("std").testing;

test "syscall: the access argument packs and unpacks" {
    const rights = cap.Rights{ .read = true, .list = true };
    const packed_arg = packAccess(20, rights);
    const back = unpackAccess(packed_arg);
    try testing.expectEqual(@as(usize, 20), back.len);
    try testing.expectEqual(rights.bits(), back.rights.bits());
}

test "syscall: errors are distinguishable from results" {
    try testing.expect(failed(fail(.denied)));
    try testing.expect(!failed(0));
    try testing.expect(!failed(1_000_000));
}

test "syscall: fs_access answers with the capability decision" {
    const Registry = cap.Registry(8, 16);
    var registry = Registry.init();

    const documents = cap.Object{ .kind = .directory };
    const token = try registry.issueRoot(7, documents, .{ .read = true, .list = true }, .{
        .fs = cap.Path.from("/home/user/Documents"),
    }, .{ .purpose = "test" }, 0);

    try testing.expectEqual(cap.Decision.allow, checkFsAccess(&registry, 7, token, "/home/user/Documents/a.md", .{ .read = true }, 0));
    try testing.expectEqual(cap.Decision.out_of_scope, checkFsAccess(&registry, 7, token, "/etc/shadow", .{ .read = true }, 0));
    try testing.expectEqual(cap.Decision.missing_rights, checkFsAccess(&registry, 7, token, "/home/user/Documents/a.md", .{ .write = true }, 0));
    try testing.expectEqual(cap.Decision.wrong_holder, checkFsAccess(&registry, 9, token, "/home/user/Documents/a.md", .{ .read = true }, 0));
    // Every one of those, allowed or not, is now in the audit log.
    try testing.expectEqual(@as(usize, 5), registry.log.count());
}
