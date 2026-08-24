//! Формальный контракт HAL, проверяемый на этапе компиляции.
//!
//! FR-1.4: чтобы добавить новую архитектуру, достаточно создать модуль,
//! удовлетворяющий этому контракту, и зарегистрировать его в `hal.zig`.
//! Ни один модуль выше HAL при этом не меняется — а если реализация
//! отклонилась от контракта, сборка падает с внятным сообщением здесь,
//! а не где-то в глубине ядра.

const std = @import("std");
const types = @import("types.zig");

pub fn verify(comptime T: type) void {
    comptime {
        // --- статические свойства платформы ---
        requireConst(T, "target_name", []const u8);
        requireConst(T, "page_size", usize);
        requireConst(T, "max_cpus", usize);

        // --- жизненный цикл и консоль ---
        requireFn(T, "init", fn () void);
        requireFn(T, "consoleWrite", fn ([]const u8) void);
        requireFn(T, "memoryMap", fn () []const types.MemRegion);

        // --- время и таймер ---
        requireFn(T, "nowNs", fn () u64);
        requireFn(T, "armTimer", fn (u64) void);

        // --- прерывания ---
        requireFn(T, "setTrapHandler", fn (?*const fn (types.TrapKind, u64, u64) void) void);
        requireFn(T, "interruptsEnable", fn () void);
        requireFn(T, "interruptsDisable", fn () void);
        requireFn(T, "interruptsEnabled", fn () bool);

        // --- CPU и энергетика ---
        requireFn(T, "cpuId", fn () u32);
        requireFn(T, "idle", fn () void);
        requireFn(T, "deepIdle", fn (u64) void);
        requireFn(T, "setPerfLevel", fn (types.PerfLevel) void);
        requireFn(T, "halt", fn () noreturn);

        // --- адресные пространства (FR-1.2) ---
        requireType(T, "AddressSpace");
        const AS = @field(T, "AddressSpace");
        requireMethod(T, "asInit", 1, *AS);
        requireMethod(T, "asDeinit", 1, *AS);
        requireMethod(T, "asMap", 4, *AS);
        requireMethod(T, "asUnmap", 3, *AS);
        requireMethod(T, "asTranslate", 2, *AS);
        requireMethod(T, "asActivate", 1, *AS);

        // --- контекст исполнения ---
        requireType(T, "Context");
        const Ctx = @field(T, "Context");
        requireMethod(T, "ctxInit", 4, *Ctx);
        requireMethod(T, "ctxSwitch", 2, *Ctx);
    }
}

fn requireConst(comptime T: type, comptime name: []const u8, comptime Expect: type) void {
    if (!@hasDecl(T, name)) @compileError(missing(T, name));
    const Actual = @TypeOf(@field(T, name));
    if (Actual != Expect and !coercible(Actual, Expect)) {
        @compileError(std.fmt.comptimePrint(
            "HAL `{s}`: константа `{s}` имеет тип {s}, ожидался {s}",
            .{ @typeName(T), name, @typeName(Actual), @typeName(Expect) },
        ));
    }
}

fn coercible(comptime Actual: type, comptime Expect: type) bool {
    // comptime_int/comptime-известные литералы приводятся к целевому типу.
    return switch (@typeInfo(Actual)) {
        .comptime_int => @typeInfo(Expect) == .int,
        .pointer => |p| p.size == .slice and Expect == []const u8 and p.child == u8,
        else => false,
    };
}

fn requireFn(comptime T: type, comptime name: []const u8, comptime Sig: type) void {
    if (!@hasDecl(T, name)) @compileError(missing(T, name));
    const Actual = @TypeOf(@field(T, name));
    if (Actual != Sig) {
        @compileError(std.fmt.comptimePrint(
            "HAL `{s}`: функция `{s}` имеет сигнатуру {s}, ожидалась {s}",
            .{ @typeName(T), name, @typeName(Actual), @typeName(Sig) },
        ));
    }
}

fn requireType(comptime T: type, comptime name: []const u8) void {
    if (!@hasDecl(T, name)) @compileError(missing(T, name));
    if (@TypeOf(@field(T, name)) != type) {
        @compileError(std.fmt.comptimePrint("HAL `{s}`: `{s}` должен быть типом", .{ @typeName(T), name }));
    }
}

/// Функции, работающие с арх-зависимыми типами (AddressSpace/Context),
/// проверяются структурно: арность + тип первого параметра.
fn requireMethod(comptime T: type, comptime name: []const u8, comptime arity: usize, comptime Self: type) void {
    if (!@hasDecl(T, name)) @compileError(missing(T, name));
    const info = @typeInfo(@TypeOf(@field(T, name)));
    if (info != .@"fn") @compileError(std.fmt.comptimePrint("HAL `{s}`: `{s}` должен быть функцией", .{ @typeName(T), name }));
    const f = info.@"fn";
    if (f.params.len != arity) {
        @compileError(std.fmt.comptimePrint(
            "HAL `{s}`: `{s}` принимает {d} аргумент(ов), ожидалось {d}",
            .{ @typeName(T), name, f.params.len, arity },
        ));
    }
    if (f.params.len == 0 or f.params[0].type != Self) {
        @compileError(std.fmt.comptimePrint(
            "HAL `{s}`: первый аргумент `{s}` должен быть {s}",
            .{ @typeName(T), name, @typeName(Self) },
        ));
    }
}

fn missing(comptime T: type, comptime name: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "HAL `{s}` не реализует обязательный элемент контракта `{s}` (см. kernel/hal/contract.zig)",
        .{ @typeName(T), name },
    );
}
