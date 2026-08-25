//! The system call boundary.
//!
//! Every call arrives through the HAL (an `svc` on AArch64, `int 0x80` on
//! x86_64), and every call that touches an object goes through a capability
//! check first — that is FR-2.1 at the one place where it can be enforced.
//!
//! User pointers are copied through `AddressSpace.translate` onto the identity
//! map. Kernel threads still pass kernel addresses and skip that check.

const std = @import("std");
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
    /// a0 = status. Never returns to the caller.
    exit = 8,
    /// a0 = new break, or 0 to query. Returns the break.
    brk = 9,
    /// Returns (height << 32) | width of the framebuffer, or 0.
    surface_info = 10,
    /// a0=pixels, a1=w, a2=h, a3=dst_x, a4=dst_y. ARGB8888. Returns bytes copied.
    surface_blit = 11,
    /// 12 was http_get, which fetched a whole web page inside the kernel.
    /// Sockets replaced it: HTTP is a text format, and text formats belong on
    /// the other side of the gate.
    /// a0=host, a1=host_len, a2=port. Returns a socket handle.
    connect = 14,
    /// a0=handle, a1=buffer, a2=length. Returns bytes accepted.
    send = 15,
    /// a0=handle, a1=buffer, a2=length. Returns bytes read; zero at the end of
    /// the stream.
    recv = 16,
    /// a0=handle.
    close = 17,
    /// a0 = buffer, a1 = length. Fills it with random bytes and returns the
    /// count. Fails with `unsupported` when the machine has no generator: a
    /// program building a key deserves to know it would have been built out of
    /// a stopwatch.
    random = 18,
    /// Seconds since the Unix epoch, or zero when the machine has no clock.
    realtime = 19,
    /// a0 = buffer, a1 = length. Copies the command line the program was
    /// started with and returns how many bytes it is.
    args = 13,
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
    /// The machine cannot do this at all — no card, no screen.
    unsupported = 5,
    /// It could have worked and did not: nothing answered, the name has no
    /// address, the disk refused. A program may sensibly try again.
    io_error = 6,
    /// A table in the kernel is full. Trying again later may work; trying
    /// again immediately will not.
    no_room = 7,
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
    return invoke6(number, a0, a1, a2, 0, 0, 0);
}

pub inline fn invoke6(number: Number, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) u64 {
    const n = @intFromEnum(number);
    if (builtin.os.tag != .freestanding and builtin.os.tag != .uefi) {
        return hal.impl.testSyscall(n, a0, a1, a2, a3, a4, a5);
    }
    return switch (builtin.cpu.arch) {
        .aarch64 => asm volatile ("svc #0"
            : [ret] "={x0}" (-> u64),
            : [number] "{x8}" (n),
              [arg0] "{x0}" (a0),
              [arg1] "{x1}" (a1),
              [arg2] "{x2}" (a2),
              [arg3] "{x3}" (a3),
              [arg4] "{x4}" (a4),
              [arg5] "{x5}" (a5),
            : .{ .memory = true }),
        .x86_64 => asm volatile ("int $0x80"
            : [ret] "={rax}" (-> u64),
            : [number] "{rax}" (n),
              [arg0] "{rdi}" (a0),
              [arg1] "{rsi}" (a1),
              [arg2] "{rdx}" (a2),
              [arg3] "{rcx}" (a3),
              [arg4] "{r8}" (a4),
              [arg5] "{r9}" (a5),
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
pub fn dispatch(number: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, from_user: bool) u64 {
    const fp = @import("fp.zig");
    if (from_user) fp.onKernelEntry(true);
    const result = dispatchInner(number, a0, a1, a2, a3, a4, a5, from_user);
    if (from_user) fp.prepareReturnToUser();
    return result;
}

fn dispatchInner(number: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, from_user: bool) u64 {
    const root = @import("root");
    // The sixth argument outlived the call that needed it: HTTP left the
    // kernel and took it with it. The register stays in the ABI because
    // changing the shape of a system call to save a register is not a trade
    // worth making twice.
    _ = a5;
    const call: Number = @enumFromInt(number);
    return switch (call) {
        .write => sysWrite(a0, a1, from_user),
        .yield => blk: {
            root.yield();
            break :blk 0;
        },
        .sleep_ms => blk: {
            root.sleepMs(a0);
            break :blk 0;
        },
        .time_ns => hal.nowNs(),
        .fs_access => sysFsAccess(a0, a1, a2, from_user),
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
        .exit => blk: {
            root.exitCurrent(a0);
            break :blk 0;
        },
        .brk => sysBrk(a0, from_user),
        .surface_info => sysSurfaceInfo(),
        .surface_blit => sysSurfaceBlit(a0, a1, a2, a3, a4, from_user),
        .connect => sysConnect(a0, a1, a2, from_user),
        .send => sysSend(a0, a1, a2, from_user),
        .recv => sysRecv(a0, a1, a2, from_user),
        .close => sysClose(a0),
        .random => sysRandom(a0, a1, from_user),
        .realtime => hal.realtimeSeconds(),
        .args => sysArgs(a0, a1, from_user),
        _ => fail(.bad_number),
    };
}

fn sysWrite(ptr: u64, len: u64, from_user: bool) u64 {
    if (len == 0) return 0;
    if (ptr == 0) return fail(.bad_argument);
    if (!from_user) {
        const bytes: [*]const u8 = @ptrFromInt(ptr);
        hal.consoleWrite(bytes[0..@intCast(len)]);
        return len;
    }
    const space = callerSpace() orelse return fail(.no_caller);
    const n: usize = @intCast(len);
    if (!space.checkAccess(ptr, n, false)) return fail(.bad_argument);
    var off: usize = 0;
    while (off < n) {
        const page_off = (ptr + off) % hal.page_size;
        const chunk = @min(n - off, hal.page_size - page_off);
        const pa = space.translate(ptr + off) orelse return fail(.bad_argument);
        const src: [*]const u8 = @ptrFromInt(pa);
        hal.consoleWrite(src[0..chunk]);
        off += chunk;
    }
    return len;
}

fn sysFsAccess(cap_id: u64, path_ptr: u64, packed_arg: u64, from_user: bool) u64 {
    const root = @import("root");
    const caller = callerPid() orelse return fail(.no_caller);
    if (path_ptr == 0) return fail(.bad_argument);
    const unpacked = unpackAccess(packed_arg);
    if (unpacked.len == 0 or unpacked.len > cap.max_path) return fail(.bad_argument);

    var path_buf: [cap.max_path]u8 = undefined;
    if (from_user) {
        const space = callerSpace() orelse return fail(.no_caller);
        if (!copyIn(space, path_buf[0..unpacked.len], path_ptr)) return fail(.bad_argument);
    } else {
        const src: [*]const u8 = @ptrFromInt(path_ptr);
        @memcpy(path_buf[0..unpacked.len], src[0..unpacked.len]);
    }
    const decision = checkFsAccess(
        &root.registry,
        caller,
        cap_id,
        path_buf[0..unpacked.len],
        unpacked.rights,
        hal.nowNs(),
    );
    return @intFromEnum(decision);
}

fn sysBrk(requested: u64, from_user: bool) u64 {
    _ = from_user;
    const root = @import("root");
    const layout = @import("mm/layout.zig");
    const p = callerProcess() orelse return fail(.no_caller);
    if (requested == 0) return p.heap_break;
    if (requested < layout.heap_base or requested > layout.heap_max) return fail(.bad_argument);
    if (requested > p.heap_break) {
        const start = std.mem.alignForward(u64, p.heap_break, hal.page_size);
        const end = std.mem.alignForward(u64, requested, hal.page_size);
        if (end > start) {
            const pages: usize = @intCast((end - start) / hal.page_size);
            p.space.mapAnonymous(&root.frames, start, pages, .{
                .read = true,
                .write = true,
                .user = true,
            }) catch return fail(.denied);
        }
    }
    p.heap_break = requested;
    return requested;
}

fn sysSurfaceInfo() u64 {
    if (comptime @hasDecl(hal.impl, "fb")) {
        const dim = hal.impl.fb.dimensions();
        if (dim.width == 0) return 0;
        return (@as(u64, dim.height) << 32) | dim.width;
    }
    return 0;
}

fn sysSurfaceBlit(ptr: u64, w: u64, h: u64, dst_x: u64, dst_y: u64, from_user: bool) u64 {
    if (comptime !@hasDecl(hal.impl, "fb")) return fail(.denied);
    if (w == 0 or h == 0 or w > 1024 or h > 768) return fail(.bad_argument);
    const bytes: usize = @intCast(w * h * 4);
    if (ptr == 0) return fail(.bad_argument);
    const space = if (from_user) callerSpace() orelse return fail(.no_caller) else null;
    if (from_user) {
        if (!space.?.checkAccess(ptr, bytes, false)) return fail(.bad_argument);
    }
    const x: u32 = @truncate(dst_x);
    const y: u32 = @truncate(dst_y);
    const width: u32 = @truncate(w);
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        var line: [1024]u32 = undefined;
        const src_va = ptr + @as(u64, row) * w * 4;
        if (from_user) {
            if (!copyIn(space.?, std.mem.sliceAsBytes(line[0..width]), src_va)) return fail(.bad_argument);
        } else {
            const src: [*]const u8 = @ptrFromInt(src_va);
            @memcpy(std.mem.sliceAsBytes(line[0..width]), src[0 .. width * 4]);
        }
        if (comptime @hasDecl(hal.impl, "fb")) {
            hal.impl.fb.blitArgb(x, y + row, width, 1, line[0..width], width);
        }
    }
    return w * h * 4;
}

/// Hand the program its command line. A short buffer gets a short answer and
/// the true length, so a caller can ask twice rather than guess once.
fn sysArgs(buf_ptr: u64, buf_len: u64, from_user: bool) u64 {
    const process = callerProcess() orelse return fail(.no_caller);
    const text = process.argsText();
    if (buf_ptr == 0 or buf_len == 0) return text.len;
    const take = @min(text.len, @as(usize, @intCast(buf_len)));
    if (from_user) {
        const space = callerSpace() orelse return fail(.no_caller);
        if (!copyOut(space, buf_ptr, text[0..take])) return fail(.bad_argument);
    } else {
        const destination: [*]u8 = @ptrFromInt(buf_ptr);
        @memcpy(destination[0..take], text[0..take]);
    }
    return text.len;
}

/// Turn a network failure into something a program can act on. "You have no
/// token for that host" and "nothing answered" call for different responses,
/// and a single error code for both would tell the program nothing.
fn netFail(e: anyerror) u64 {
    return fail(switch (e) {
        error.Denied => Error.denied,
        error.NoInterface => Error.unsupported,
        error.NoSocket => Error.bad_argument,
        error.NoRoom => Error.no_room,
        else => Error.io_error,
    });
}

fn sysConnect(host_ptr: u64, host_len: u64, port: u64, from_user: bool) u64 {
    const root = @import("root");
    if (host_len == 0 or host_len > 63) return fail(.bad_argument);
    if (port == 0 or port > 65535) return fail(.bad_argument);
    const process = callerProcess() orelse return fail(.no_caller);

    var host_buf: [64]u8 = undefined;
    const host = host_buf[0..@intCast(host_len)];
    if (from_user) {
        const space = callerSpace() orelse return fail(.no_caller);
        if (!copyIn(space, host, host_ptr)) return fail(.bad_argument);
    } else {
        const source: [*]const u8 = @ptrFromInt(host_ptr);
        @memcpy(host, source[0..host.len]);
    }

    const handle = root.socketConnect(process.pid, host, @intCast(port)) catch |e| return netFail(e);
    return handle;
}

fn sysSend(handle: u64, buf_ptr: u64, buf_len: u64, from_user: bool) u64 {
    const root = @import("root");
    if (buf_ptr == 0 or buf_len == 0 or buf_len > 4096) return fail(.bad_argument);
    const process = callerProcess() orelse return fail(.no_caller);

    var chunk: [4096]u8 = undefined;
    const bytes = chunk[0..@intCast(buf_len)];
    if (from_user) {
        const space = callerSpace() orelse return fail(.no_caller);
        if (!copyIn(space, bytes, buf_ptr)) return fail(.bad_argument);
    } else {
        const source: [*]const u8 = @ptrFromInt(buf_ptr);
        @memcpy(bytes, source[0..bytes.len]);
    }

    const sent = root.socketSend(process.pid, @intCast(handle), bytes) catch |e| return netFail(e);
    return sent;
}

fn sysRecv(handle: u64, buf_ptr: u64, buf_len: u64, from_user: bool) u64 {
    const root = @import("root");
    if (buf_ptr == 0 or buf_len == 0) return fail(.bad_argument);
    const process = callerProcess() orelse return fail(.no_caller);

    var chunk: [4096]u8 = undefined;
    const want = @min(@as(usize, @intCast(buf_len)), chunk.len);
    const got = root.socketRecv(process.pid, @intCast(handle), chunk[0..want]) catch |e|
        return netFail(e);
    if (got == 0) return 0;

    if (from_user) {
        const space = callerSpace() orelse return fail(.no_caller);
        if (!copyOut(space, buf_ptr, chunk[0..got])) return fail(.bad_argument);
    } else {
        const destination: [*]u8 = @ptrFromInt(buf_ptr);
        @memcpy(destination[0..got], chunk[0..got]);
    }
    return got;
}

fn sysRandom(buf_ptr: u64, buf_len: u64, from_user: bool) u64 {
    if (buf_ptr == 0 or buf_len == 0 or buf_len > 256) return fail(.bad_argument);
    var bytes: [256]u8 = undefined;
    const want = bytes[0..@intCast(buf_len)];
    if (!hal.entropy(want)) return fail(.unsupported);
    if (from_user) {
        const space = callerSpace() orelse return fail(.no_caller);
        if (!copyOut(space, buf_ptr, want)) return fail(.bad_argument);
    } else {
        const destination: [*]u8 = @ptrFromInt(buf_ptr);
        @memcpy(destination[0..want.len], want);
    }
    return want.len;
}

fn sysClose(handle: u64) u64 {
    const root = @import("root");
    const process = callerProcess() orelse return fail(.no_caller);
    root.socketClose(process.pid, @intCast(handle));
    return 0;
}

fn copyOut(space: anytype, user_va: u64, src: []const u8) bool {
    if (!space.checkAccess(user_va, src.len, true)) return false;
    var off: usize = 0;
    while (off < src.len) {
        const page_off = (user_va + off) % hal.page_size;
        const chunk = @min(src.len - off, hal.page_size - page_off);
        const pa = space.translate(user_va + off) orelse return false;
        const dst: [*]u8 = @ptrFromInt(pa);
        @memcpy(dst[0..chunk], src[off..][0..chunk]);
        off += chunk;
    }
    return true;
}

fn copyIn(space: anytype, dst: []u8, user_va: u64) bool {
    if (!space.checkAccess(user_va, dst.len, false)) return false;
    var off: usize = 0;
    while (off < dst.len) {
        const page_off = (user_va + off) % hal.page_size;
        const chunk = @min(dst.len - off, hal.page_size - page_off);
        const pa = space.translate(user_va + off) orelse return false;
        const src: [*]const u8 = @ptrFromInt(pa);
        @memcpy(dst[off..][0..chunk], src[0..chunk]);
        off += chunk;
    }
    return true;
}

fn callerSpace() ?*@import("mm/vmm.zig").AddressSpace {
    const p = callerProcess() orelse return null;
    return &p.space;
}

fn callerProcess() ?*@import("proc/process.zig").Process {
    const root = @import("root");
    const pid = callerPid() orelse return null;
    return root.processes.get(pid);
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
