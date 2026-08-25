//! The formal HAL contract, verified at compile time.
//!
//! FR-1.4: to add an architecture it is enough to write a module that
//! satisfies this contract and register it in `hal.zig`.
//! No module above the HAL changes; and if an implementation drifts from
//! the contract, the build fails with a clear message right here instead
//! of somewhere deep inside the kernel.

const std = @import("std");
const types = @import("types.zig");

pub fn verify(comptime T: type) void {
    comptime {
        // --- static platform properties ---
        requireConst(T, "target_name", []const u8);
        requireConst(T, "page_size", usize);
        requireConst(T, "max_cpus", usize);

        // --- lifecycle and console ---
        requireFn(T, "init", fn () void);
        requireFn(T, "consoleWrite", fn ([]const u8) void);
        requireFn(T, "readKey", fn () ?u8);
        requireFn(T, "readPointer", fn () ?types.PointerEvent);
        requireFn(T, "memoryMap", fn () []const types.MemRegion);

        // --- time and timer ---
        requireFn(T, "nowNs", fn () u64);
        requireFn(T, "armTimer", fn (u64) void);

        // --- interrupts ---
        requireFn(T, "setTrapHandler", fn (?types.TrapHandler) void);
        requireFn(T, "setSyscallHandler", fn (?types.SyscallHandler) void);
        requireFn(T, "interruptsEnable", fn () void);
        requireFn(T, "interruptsDisable", fn () void);
        requireFn(T, "interruptsEnabled", fn () bool);

        // --- CPU and power ---
        requireFn(T, "cpuId", fn () u32);
        requireFn(T, "idle", fn () void);
        requireFn(T, "deepIdle", fn (u64) void);
        requireFn(T, "setPerfLevel", fn (types.PerfLevel) void);
        requireFn(T, "halt", fn () noreturn);

        // --- address spaces (FR-1.2) ---
        requireType(T, "AddressSpace");
        const AS = @field(T, "AddressSpace");
        requireMethod(T, "asInit", 1, *AS);
        requireMethod(T, "asDeinit", 1, *AS);
        requireMethod(T, "asMap", 4, *AS);
        requireMethod(T, "asUnmap", 3, *AS);
        requireMethod(T, "asTranslate", 2, *AS);
        requireMethod(T, "asActivate", 1, *AS);
        // The space the CPU is running on, so the kernel can add mappings to it
        // without knowing how the platform built it.
        requireFn(T, "currentSpace", fn () *AS);

        // --- privilege ---
        requireFn(T, "enterUserMode", fn (usize, usize) noreturn);
        requireFn(T, "setKernelStack", fn (usize) void);

        // --- execution context ---
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
            "HAL `{s}`: constant `{s}` has type {s}, expected {s}",
            .{ @typeName(T), name, @typeName(Actual), @typeName(Expect) },
        ));
    }
}

fn coercible(comptime Actual: type, comptime Expect: type) bool {
    // comptime_int and comptime-known literals coerce to the target type.
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
            "HAL `{s}`: function `{s}` has signature {s}, expected {s}",
            .{ @typeName(T), name, @typeName(Actual), @typeName(Sig) },
        ));
    }
}

fn requireType(comptime T: type, comptime name: []const u8) void {
    if (!@hasDecl(T, name)) @compileError(missing(T, name));
    if (@TypeOf(@field(T, name)) != type) {
        @compileError(std.fmt.comptimePrint("HAL `{s}`: `{s}` must be a type", .{ @typeName(T), name }));
    }
}

/// Functions taking arch-specific types (AddressSpace/Context) are verified
/// structurally: arity plus the type of the first parameter.
fn requireMethod(comptime T: type, comptime name: []const u8, comptime arity: usize, comptime Self: type) void {
    if (!@hasDecl(T, name)) @compileError(missing(T, name));
    const info = @typeInfo(@TypeOf(@field(T, name)));
    if (info != .@"fn") @compileError(std.fmt.comptimePrint("HAL `{s}`: `{s}` must be a function", .{ @typeName(T), name }));
    const f = info.@"fn";
    if (f.params.len != arity) {
        @compileError(std.fmt.comptimePrint(
            "HAL `{s}`: `{s}` takes {d} argument(s), expected {d}",
            .{ @typeName(T), name, f.params.len, arity },
        ));
    }
    if (f.params.len == 0 or f.params[0].type != Self) {
        @compileError(std.fmt.comptimePrint(
            "HAL `{s}`: the first argument of `{s}` must be {s}",
            .{ @typeName(T), name, @typeName(Self) },
        ));
    }
}

fn missing(comptime T: type, comptime name: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "HAL `{s}` does not implement required contract item `{s}` (see kernel/hal/contract.zig)",
        .{ @typeName(T), name },
    );
}
