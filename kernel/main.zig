//! Точка сборки ядра AIZigOS: инициализация подсистем и запуск init-процесса.
//!
//! Ядро не выделяет динамическую память: все таблицы статические,
//! их размеры — часть бюджета из FR-1.5 (`zig build size-audit`).

const std = @import("std");
const builtin = @import("builtin");

const hal = @import("hal/hal.zig");
const klog = @import("klog.zig");
const pmm = @import("mm/pmm.zig");
const vmm = @import("mm/vmm.zig");
const cap = @import("cap/cap.zig");
const sched = @import("sched/sched.zig");
const power = @import("sched/power.zig");
const ipc_mod = @import("ipc/ipc.zig");
const proc = @import("proc/process.zig");

pub const version = "0.1.0-stage1";

// --- размеры статических таблиц (бюджет ядра) -----------------------------

const max_ram = 1 << 30; // 1 ГиБ адресуемой физической памяти
const bitmap_bytes = max_ram / hal.page_size / 8;

const max_processes = 32;
const max_tasks = 64;
const max_capabilities = 256;
const audit_entries = 256;
const max_endpoints = 32;
const ipc_queue_depth = 8;
const max_ipc_waiters = 32;

pub const Registry = cap.Registry(max_capabilities, audit_entries);
pub const Scheduler = sched.Scheduler(max_tasks);
pub const Ipc = ipc_mod.Ipc(max_endpoints, ipc_queue_depth, max_ipc_waiters);
pub const ProcTable = proc.Table(max_processes);

var frame_bitmap: [bitmap_bytes]u8 = undefined;

pub var frames: pmm.Pmm = undefined;
pub var registry: Registry = undefined;
pub var scheduler: Scheduler = undefined;
pub var ipc: Ipc = undefined;
pub var processes: ProcTable = undefined;

// --- обработчик ловушек ---------------------------------------------------

fn onTrap(kind: hal.types.TrapKind, esr: u64, addr: u64) void {
    switch (kind) {
        .timer => {
            const now = hal.nowNs();
            scheduler.tick(now);
            hal.armTimer(scheduler.tune.quantum_ns);
        },
        .syscall => {
            // Этап 2: разбор номера вызова и проверка capability вызывающего.
            klog.debug("syscall (esr=0x{x})", .{esr});
        },
        .page_fault => {
            klog.err("page fault по адресу 0x{x} (esr=0x{x})", .{ addr, esr });
            hal.halt();
        },
        else => klog.warn("ловушка {s}: esr=0x{x} addr=0x{x}", .{ @tagName(kind), esr, addr }),
    }
}

// --- инициализация --------------------------------------------------------

fn banner() void {
    klog.raw("\n");
    klog.info("AIZigOS {s} — микроядро на Zig {s}", .{ version, builtin.zig_version_string });
    klog.info("таргет HAL: {s}, страница {d} байт", .{ hal.target_name, hal.page_size });
}

fn initMemory() void {
    const map = hal.memoryMap();
    frames = pmm.Pmm.init(&frame_bitmap, hal.page_size, map) catch |e| {
        klog.err("не удалось поднять PMM: {s}", .{@errorName(e)});
        hal.halt();
    };
    const st = frames.stats();
    klog.info("физическая память: {d} КиБ свободно из {d} КиБ", .{
        st.free_frames * st.page_size / 1024,
        st.total_frames * st.page_size / 1024,
    });
}

/// Начальная раздача прав: init получает корневые токены,
/// из которых потом выводится всё остальное (FR-2.1).
fn initCapabilities(init_pid: proc.Pid) !void {
    const now = hal.nowNs();
    _ = try registry.issueRoot(init_pid, .{ .kind = .directory }, .{
        .read = true,
        .write = true,
        .list = true,
        .create = true,
        .delete = true,
        .grant = true,
        .revoke = true,
    }, .{ .fs = cap.Path.from("/") }, .{ .purpose = "корень ФС для init" }, now);

    _ = try registry.issueRoot(init_pid, .{ .kind = .device }, .{
        .read = true,
        .write = true,
        .grant = true,
        .revoke = true,
    }, .{ .device = .any }, .{ .purpose = "устройства для init" }, now);

    klog.info("выдано корневых capability: {d}", .{registry.count()});
}

fn initScheduling() void {
    scheduler = Scheduler.init();
    // На старте считаем, что питание от сети: профиль выберется по датчикам,
    // как только появится драйвер батареи (этап 2).
    _ = scheduler.updatePower(.{ .on_ac = true, .battery_present = false });
    klog.info("энергопрофиль: {s}, квант {d} мкс", .{
        scheduler.governor.current.label(),
        scheduler.tune.quantum_ns / 1000,
    });
}

export fn kmain() callconv(.c) void {
    hal.init();
    hal.setTrapHandler(onTrap);
    banner();

    initMemory();
    registry = Registry.init();
    ipc = Ipc.init();
    processes = ProcTable.init();
    initScheduling();

    const init_pid = processes.create(.{ .name = "init", .class = .interactive }) catch |e| {
        klog.err("не удалось создать init: {s}", .{@errorName(e)});
        hal.halt();
    };
    initCapabilities(init_pid) catch |e| {
        klog.err("раздача capability не удалась: {s}", .{@errorName(e)});
        hal.halt();
    };
    _ = processes.addThread(&scheduler, init_pid, "init.main") catch |e| {
        klog.err("не удалось создать поток init: {s}", .{@errorName(e)});
        hal.halt();
    };

    klog.info("процессов: {d}, задач в очереди: {d}", .{ processes.count(), scheduler.runnableCount() });
    klog.info("ядро готово, отдаём управление планировщику", .{});

    hal.armTimer(scheduler.tune.quantum_ns);
    hal.interruptsEnable();
    idleLoop();
}

/// Пока планировщик не имеет реальных пользовательских потоков, ядро крутит
/// холостой цикл: тик таймера будит планировщик, простой уходит в сон
/// по правилам текущего энергопрофиля.
fn idleLoop() noreturn {
    while (true) {
        const now = hal.nowNs();
        if (scheduler.need_resched) {
            if (scheduler.schedule(now)) |tid| {
                klog.debug("на CPU: {s}", .{scheduler.task(tid).?.nameText()});
            }
        }
        if (scheduler.shouldDeepIdle()) {
            hal.deepIdle(scheduler.tune.quantum_ns);
        } else {
            hal.idle();
        }
    }
}

// --- паника ---------------------------------------------------------------

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    klog.raw("\n[panic] ");
    klog.raw(msg);
    klog.raw("\n");
    if (first_trace_addr) |addr| klog.err("адрес: 0x{x}", .{addr});
    hal.halt();
}

pub const panic = std.debug.FullPanic(panicHandler);
