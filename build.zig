const std = @import("std");

/// Поддерживаемые платы. Новый таргет добавляется здесь + каталогом в kernel/hal/,
/// код выше HAL при этом не меняется (FR-1.4).
pub const Board = enum {
    virt_aarch64,
    pc_x86_64,

    fn query(self: Board) std.Target.Query {
        return switch (self) {
            .virt_aarch64 => .{
                .cpu_arch = .aarch64,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.cortex_a72 },
                // В ядре не используем FP/SIMD: не нужно сохранять их в контексте.
                .cpu_features_sub = std.Target.aarch64.featureSet(&.{ .fp_armv8, .neon, .crypto }),
            },
            .pc_x86_64 => .{
                .cpu_arch = .x86_64,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_features_add = std.Target.x86.featureSet(&.{.soft_float}),
                .cpu_features_sub = std.Target.x86.featureSet(&.{ .x87, .mmx, .sse, .sse2, .avx, .avx2 }),
            },
        };
    }

    fn linkerScript(self: Board) []const u8 {
        return switch (self) {
            .virt_aarch64 => "kernel/hal/aarch64/link.ld",
            .pc_x86_64 => "kernel/hal/x86_64/link.ld",
        };
    }
};

pub fn build(b: *std.Build) void {
    const board = b.option(Board, "board", "целевая плата (virt_aarch64 | pc_x86_64)") orelse .virt_aarch64;
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    // FR-1.5: бюджет размера ядра. Значение фиксируется перед аудитом безопасности.
    const budget = b.option(usize, "kernel-budget", "бюджет размера ядра в байтах (FR-1.5)") orelse 256 * 1024;

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("kernel/main.zig"),
        .target = b.resolveTargetQuery(board.query()),
        .optimize = optimize,
        .code_model = .small,
        .pic = false,
        .strip = false,
        .single_threaded = true,
        .stack_protector = false,
        .stack_check = false,
        .red_zone = false,
        .omit_frame_pointer = false,
    });

    const kernel = b.addExecutable(.{
        .name = "aizigos-kernel",
        .root_module = kernel_mod,
    });
    kernel.setLinkerScript(b.path(board.linkerScript()));
    kernel.entry = .{ .symbol_name = "_start" };
    kernel.link_gc_sections = true;
    b.installArtifact(kernel);

    // ---- аудит размера ядра (FR-1.5) -------------------------------------
    const audit_tool = b.addExecutable(.{
        .name = "size-audit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/size_audit.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_audit = b.addRunArtifact(audit_tool);
    run_audit.addFileArg(kernel.getEmittedBin());
    run_audit.addArg(b.fmt("{d}", .{budget}));
    const audit_step = b.step("size-audit", "Проверить бюджет размера ядра (FR-1.5)");
    audit_step.dependOn(&run_audit.step);

    // ---- хостовые тесты ядра ---------------------------------------------
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/tests.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Прогнать модульные тесты ядра на хосте");
    test_step.dependOn(&run_tests.step);

    // ---- запуск в QEMU ----------------------------------------------------
    const qemu = switch (board) {
        .virt_aarch64 => b.addSystemCommand(&.{
            "qemu-system-aarch64", "-M",   "virt",       "-cpu",    "cortex-a72",
            "-m",                  "512M", "-nographic", "-serial", "mon:stdio",
            "-kernel",
        }),
        .pc_x86_64 => b.addSystemCommand(&.{
            "qemu-system-x86_64", "-m", "512M", "-nographic", "-serial", "mon:stdio", "-kernel",
        }),
    };
    qemu.addFileArg(kernel.getEmittedBin());
    const run_step = b.step("run", "Запустить ядро в QEMU");
    run_step.dependOn(&qemu.step);
}
