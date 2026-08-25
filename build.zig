const std = @import("std");

/// Supported boards. A new target is added here plus a directory in kernel/hal/;
/// no code above the HAL changes (FR-1.4).
pub const Board = enum {
    virt_aarch64,
    pc_x86_64,
    uefi_x86_64,

    fn query(self: Board) std.Target.Query {
        return switch (self) {
            .virt_aarch64 => .{
                .cpu_arch = .aarch64,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.cortex_a72 },
                // The kernel uses no FP/SIMD, so contexts need not save them.
                .cpu_features_sub = std.Target.aarch64.featureSet(&.{ .fp_armv8, .neon, .crypto }),
            },
            .pc_x86_64 => .{
                .cpu_arch = .x86_64,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_features_add = std.Target.x86.featureSet(&.{.soft_float}),
                .cpu_features_sub = std.Target.x86.featureSet(&.{ .x87, .mmx, .sse, .sse2, .avx, .avx2 }),
            },
            // UEFI hands us a machine that already has long mode, paging and
            // SSE enabled, so the default feature set is what the firmware
            // expects when we call back into it.
            .uefi_x86_64 => .{
                .cpu_arch = .x86_64,
                .os_tag = .uefi,
                .abi = .msvc,
            },
        };
    }

    fn linkerScript(self: Board) ?[]const u8 {
        return switch (self) {
            .virt_aarch64 => "kernel/hal/aarch64/link.ld",
            .pc_x86_64 => "kernel/hal/x86_64/link.ld",
            // The firmware loads a PE image; the layout is not ours to choose.
            .uefi_x86_64 => null,
        };
    }
};

/// QEMU is usually on PATH, but a fresh Windows install puts it somewhere the
/// current shell has not heard about yet. Fall back to the standard location
/// before giving up, and let `-Dqemu=<path>` override both.
fn qemuBinary(b: *std.Build, name: []const u8, override: ?[]const u8) []const u8 {
    if (override) |path| return path;
    return b.findProgram(&.{name}, &.{"C:/Program Files/qemu"}) catch name;
}

pub fn build(b: *std.Build) void {
    const board = b.option(Board, "board", "target board (virt_aarch64 | pc_x86_64 | uefi_x86_64)") orelse .uefi_x86_64;
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    // FR-1.5: the kernel size budget. It was 256 KiB while the kernel was only
    // a kernel; the shell and the desktop live inside the image today and take
    // most of the difference. Both belong in user space once there is a program
    // loader, and the number should come back down when they move.
    const budget = b.option(usize, "kernel-budget", "kernel size budget in bytes (FR-1.5)") orelse 384 * 1024;
    const image_mib = b.option(u64, "image-size", "boot image size in MiB") orelse 64;
    const ovmf_code = b.option([]const u8, "ovmf", "UEFI firmware code for `zig build run`") orelse
        "C:/Program Files/qemu/share/edk2-x86_64-code.fd";
    // OVMF wants a writable variable store next to the read-only code, so the
    // build keeps its own copy instead of scribbling on the QEMU installation.
    const ovmf_vars_src = b.option([]const u8, "ovmf-vars", "UEFI variable store template") orelse
        "C:/Program Files/qemu/share/edk2-i386-vars.fd";
    const headless = b.option(bool, "headless", "run QEMU without a window, console on stdio") orelse false;
    const qemu_override = b.option([]const u8, "qemu", "path to the QEMU binary");

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("kernel/main.zig"),
        .target = b.resolveTargetQuery(board.query()),
        .optimize = optimize,
        .code_model = if (board == .uefi_x86_64) .default else .small,
        .pic = if (board == .uefi_x86_64) null else false,
        .strip = false,
        .single_threaded = true,
        .stack_protector = false,
        .stack_check = false,
        .red_zone = false,
        .omit_frame_pointer = false,
    });

    const kernel = b.addExecutable(.{
        .name = if (board == .uefi_x86_64) "BOOTX64" else "aizigos-kernel",
        .root_module = kernel_mod,
    });
    if (board.linkerScript()) |script| {
        kernel.setLinkerScript(b.path(script));
        kernel.entry = .{ .symbol_name = "_start" };
    } else {
        kernel.subsystem = .EfiApplication;
    }
    kernel.link_gc_sections = true;
    b.installArtifact(kernel);

    // ---- bootable image (UEFI only) --------------------------------------
    const mkimage = b.addExecutable(.{
        .name = "mkimage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkimage.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run_mkimage = b.addRunArtifact(mkimage);
    run_mkimage.addFileArg(kernel.getEmittedBin());
    const image_path = run_mkimage.addOutputFileArg("aizigos.img");
    run_mkimage.addArg(b.fmt("{d}", .{image_mib}));
    const install_image = b.addInstallBinFile(image_path, "aizigos.img");
    const image_step = b.step("image", "Build a bootable UEFI disk image (GPT + FAT32 ESP)");
    image_step.dependOn(&install_image.step);

    // ---- kernel size audit (FR-1.5) --------------------------------------
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
    const audit_step = b.step("size-audit", "Check the kernel size budget (FR-1.5)");
    audit_step.dependOn(&run_audit.step);

    // ---- host-side kernel tests ------------------------------------------
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/tests.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the kernel unit tests on the host");
    test_step.dependOn(&run_tests.step);

    // ---- run under QEMU ---------------------------------------------------
    const run_step = b.step("run", "Boot the kernel under QEMU");
    switch (board) {
        .virt_aarch64 => {
            const qemu = b.addSystemCommand(&.{
                qemuBinary(b, "qemu-system-aarch64", qemu_override),
                "-M",
                "virt",
                "-cpu",
                "cortex-a72",
                "-m",
                "512M",
                "-nographic",
                "-no-reboot",
                "-kernel",
            });
            qemu.addFileArg(kernel.getEmittedBin());
            run_step.dependOn(&qemu.step);
        },
        .pc_x86_64 => {
            const qemu = b.addSystemCommand(&.{
                qemuBinary(b, "qemu-system-x86_64", qemu_override),
                "-m",
                "512M",
                "-nographic",
                "-no-reboot",
                "-kernel",
            });
            qemu.addFileArg(kernel.getEmittedBin());
            run_step.dependOn(&qemu.step);
        },
        .uefi_x86_64 => {
            const vars_copy = b.addInstallFileWithDir(
                .{ .cwd_relative = ovmf_vars_src },
                .prefix,
                "ovmf-vars.fd",
            );
            const qemu = b.addSystemCommand(&.{
                qemuBinary(b, "qemu-system-x86_64", qemu_override),
                "-m",
                "512M",
                "-no-reboot",
            });
            if (headless) {
                qemu.addArgs(&.{ "-display", "none", "-serial", "stdio" });
            } else {
                // The framebuffer console is the interface: show the window,
                // and keep a copy of everything on the serial line as well.
                qemu.addArgs(&.{ "-serial", "stdio" });
            }
            qemu.addArgs(&.{ "-drive", b.fmt("if=pflash,format=raw,unit=0,readonly=on,file={s}", .{ovmf_code}) });
            qemu.addArgs(&.{ "-drive", b.fmt("if=pflash,format=raw,unit=1,file={s}", .{
                b.getInstallPath(.prefix, "ovmf-vars.fd"),
            }) });
            qemu.addArg("-drive");
            qemu.addPrefixedFileArg("format=raw,file=", image_path);
            qemu.step.dependOn(&vars_copy.step);
            run_step.dependOn(&qemu.step);
        },
    }
}
