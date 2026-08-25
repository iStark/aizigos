//! Root of the kernel unit tests: `zig build test`.
//!
//! They run against the host HAL implementation, so scheduler, memory,
//! capability and IPC logic is checked with no hardware and no QEMU.

const std = @import("std");

comptime {
    _ = @import("hal/hal.zig");
    _ = @import("hal/contract.zig");
    _ = @import("klog.zig");
    _ = @import("mm/pmm.zig");
    _ = @import("mm/vmm.zig");
    _ = @import("mm/heap.zig");
    _ = @import("cap/audit.zig");
    _ = @import("cap/cap.zig");
    _ = @import("sched/power.zig");
    _ = @import("sched/sched.zig");
    _ = @import("ipc/ipc.zig");
    _ = @import("proc/process.zig");
    _ = @import("shell.zig");
    _ = @import("syscall.zig");
    _ = @import("user.zig");
    _ = @import("gui.zig");
    _ = @import("net/net.zig");
    _ = @import("fs/fat32.zig");
    _ = @import("fs/fat32_test.zig");
    _ = @import("agent.zig");
}

const hal = @import("hal/hal.zig");
const cap = @import("cap/cap.zig");
const sched = @import("sched/sched.zig");
const ipc_mod = @import("ipc/ipc.zig");
const proc = @import("proc/process.zig");
const pmm = @import("mm/pmm.zig");
const host = @import("hal/host/impl.zig");
const testing = std.testing;

const ms = 1_000_000;
const minute = 60_000 * ms;

test "hal: the selected implementation satisfies the contract" {
    // The fact that this compiles means contract.verify passed.
    try testing.expect(hal.page_size >= 4096);
    try testing.expect(hal.target_name.len > 0);
}

test "hal: the trap handler is installed through the contract, not an arch module" {
    const S = struct {
        var seen: u32 = 0;
        fn onTrap(kind: hal.types.TrapKind, esr: u64, addr: u64, from_user: bool) void {
            _ = esr;
            _ = addr;
            _ = from_user;
            if (kind == .timer) seen += 1;
        }
    };
    hal.setTrapHandler(S.onTrap);
    host.testFireTrap(.timer, 0, 0);
    host.testFireTrap(.timer, 0, 0);
    try testing.expectEqual(@as(u32, 2), S.seen);
    hal.setTrapHandler(null);
}

// The end-to-end scenario from the spec: the AI shell grants an agent access
// to Documents for 10 minutes for one task, the agent works over IPC, and the
// user reads the log and revokes the access early.
test "integration: a temporary AI agent grant on Documents and its revocation" {
    const Registry = cap.Registry(64, 256);
    const Scheduler = sched.Scheduler(16);
    const Ipc = ipc_mod.Ipc(8, 8, 8);
    const Table = proc.Table(8);

    var registry = Registry.init();
    var scheduler = Scheduler.init();
    var ipc = Ipc.init();
    var table = Table.init();

    var storage: [64]u8 = undefined;
    const regions = [_]hal.MemRegion{
        .{ .base = 0x0000, .len = 0x1000, .kind = .reserved },
        .{ .base = 0x1000, .len = 0x20000, .kind = .usable },
    };
    var frames = try pmm.Pmm.init(&storage, hal.page_size, &regions);

    var now: u64 = 0;

    // 1. Shell and agent are separate processes with separate address spaces.
    const shell_pid = try table.create(.{ .name = "ai-shell", .class = .interactive });
    const agent_pid = try table.create(.{ .name = "agent:task-X", .class = .background });
    const shell_tid = try table.addThread(&scheduler, shell_pid, .{ .name = "shell.main" });
    const agent_tid = try table.addThread(&scheduler, agent_pid, .{ .name = "agent.main" });

    // 2. The shell holds root access to the home directory.
    const documents = cap.Object{ .kind = .directory };
    const shell_root = try registry.issueRoot(shell_pid, documents, .{
        .read = true,
        .write = true,
        .list = true,
        .grant = true,
        .revoke = true,
    }, .{ .fs = cap.Path.from("/home/user") }, .{ .purpose = "user home directory" }, now);

    // 3. The shell grants the agent a narrow token: read Documents, 10 minutes.
    const agent_cap = try registry.derive(shell_root, shell_pid, agent_pid, .{
        .read = true,
        .list = true,
    }, .{ .fs = cap.Path.from("/home/user/Documents") }, .{
        .lifetime_ns = 10 * minute,
        .purpose = "task X: assemble the report",
    }, now);

    const read_report = cap.Access{
        .object = documents,
        .rights = .{ .read = true },
        .path = "/home/user/Documents/report.md",
    };

    // 4. The agent reads what it may and cannot step outside the scope.
    now += 30 * 1000 * ms;
    try testing.expectEqual(cap.Decision.allow, registry.use(agent_cap, agent_pid, read_report, now));
    try testing.expectEqual(cap.Decision.out_of_scope, registry.use(agent_cap, agent_pid, .{
        .object = documents,
        .rights = .{ .read = true },
        .path = "/home/user/.ssh/id_ed25519",
    }, now));

    // 5. The agent talks to the filesystem service over IPC, also by token.
    const ep = try ipc.create(shell_pid);
    const ep_obj = cap.Object{ .kind = .endpoint, .id = ep };
    const server_cap = try registry.issueRoot(shell_pid, ep_obj, .{ .send = true, .recv = true, .grant = true }, .any, .{ .purpose = "filesystem service endpoint" }, now);
    const client_cap = try registry.derive(server_cap, shell_pid, agent_pid, .{ .send = true }, .any, .{ .purpose = "agent requests to the filesystem" }, now);

    try ipc.send(&registry, &scheduler, agent_pid, agent_tid, client_cap, ep, ipc_mod.Message.withBytes(1, "list /home/user/Documents"), .synchronous, now);
    try testing.expectEqual(sched.State.blocked, scheduler.task(agent_tid).?.state);

    const req = (try ipc.recv(&registry, &scheduler, shell_pid, shell_tid, server_cap, ep, now)).?;
    try ipc.reply(&registry, &scheduler, shell_pid, server_cap, ep, req.reply_to, ipc_mod.Message.withBytes(2, "report.md"), now);
    try testing.expectEqualStrings("report.md", ipc.takeReply(agent_tid).?.payload());

    // 6. The user reads the log: who was granted what, and why.
    var ids: [8]cap.CapId = undefined;
    const held = registry.forHolder(agent_pid, &ids);
    try testing.expectEqual(@as(usize, 2), held); // Documents access + the endpoint
    try testing.expectEqualStrings("task X: assemble the report", registry.get(agent_cap).?.purposeText());
    try testing.expect(registry.log.countForHolder(agent_pid) >= 4);

    // 7. The user revokes early: the agent loses its rights immediately.
    _ = registry.revoke(agent_cap, now);
    try testing.expectEqual(cap.Decision.revoked, registry.use(agent_cap, agent_pid, read_report, now));

    // 8. Terminating the agent drops its threads, memory and remaining tokens.
    const revoked = try table.terminate(&scheduler, &registry, &frames, agent_pid, now);
    try testing.expect(revoked >= 1);
    try testing.expectEqual(@as(?*sched.Task, null), scheduler.task(agent_tid));
    try testing.expectEqual(cap.Decision.revoked, registry.use(client_cap, agent_pid, .{
        .object = ep_obj,
        .rights = .{ .send = true },
    }, now));

    // The shell keeps working with its own rights throughout.
    try testing.expectEqual(cap.Decision.allow, registry.use(shell_root, shell_pid, read_report, now));
}

test "integration: a power emergency pauses background indexing" {
    const Scheduler = sched.Scheduler(16);
    var scheduler = Scheduler.init();

    const indexer = try scheduler.spawn(.{ .name = "semantic-index", .class = .background });
    const shell = try scheduler.spawn(.{ .name = "ai-shell", .class = .interactive });

    // On AC power the indexer runs.
    try testing.expect(scheduler.updatePower(.{ .on_ac = true, .battery_present = true, .battery_pct = 90 }));
    try testing.expectEqual(sched.Class.interactive, scheduler.task(scheduler.schedule(0).?).?.class);
    try scheduler.block(shell);
    try testing.expectEqual(indexer, scheduler.schedule(ms).?);

    // The battery is nearly flat: only interactive work remains.
    try testing.expect(scheduler.updatePower(.{ .on_ac = false, .battery_present = true, .battery_pct = 4 }));
    try testing.expectEqual(@as(?sched.Tid, null), scheduler.schedule(2 * ms));
    try testing.expectEqual(@as(u8, 0), host.testPerfLevel());

    // The user plugged the charger in: background work comes back.
    try testing.expect(scheduler.updatePower(.{ .on_ac = true, .battery_present = true, .battery_pct = 20 }));
    try testing.expectEqual(indexer, scheduler.schedule(3 * ms).?);
}
