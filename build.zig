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

    /// User programs are ELF64 even when the kernel is a UEFI PE image.
    fn userQuery(self: Board) std.Target.Query {
        return switch (self) {
            .virt_aarch64 => .{
                .cpu_arch = .aarch64,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.cortex_a72 },
                .cpu_features_sub = std.Target.aarch64.featureSet(&.{.crypto}),
            },
            .pc_x86_64, .uefi_x86_64 => .{
                .cpu_arch = .x86_64,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_features_add = std.Target.x86.featureSet(&.{ .sse, .sse2 }),
                .cpu_features_sub = std.Target.x86.featureSet(&.{ .avx, .avx2 }),
            },
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
    // 384 KiB was enough before TCP. The stack is in the kernel until stage 4
    // (drivers in user mode); 512 KiB is the budget while it lives here.
    const budget = b.option(usize, "kernel-budget", "kernel size budget in bytes (FR-1.5)") orelse 512 * 1024;
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

    // The C library lives in the kernel image for now, because there is no
    // loader to put it anywhere else. It is compiled for the same target with
    // the same flags: freestanding, no system headers, no builtins that would
    // call back into the functions being defined.
    kernel_mod.addIncludePath(b.path("lib/libc/include"));
    kernel_mod.addCSourceFiles(.{
        .root = b.path("lib/libc/src"),
        .files = &.{
            "string.c",
            "ctype.c",
            "stdlib.c",
            "stdio.c",
            "errno.c",
            "assert.c",
            "selftest.c",
        },
        .flags = &.{
            "-std=c11",
            "-ffreestanding",
            "-nostdlibinc",
            "-fno-builtin",
            "-fno-stack-protector",
            "-Wall",
            "-Wextra",
        },
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
    // The image layout is a library so that the kernel's FAT32 reader can be
    // tested against images written by exactly the code that writes the real
    // one. A reader and a writer that never meet agree only by luck.
    const cflags = [_][]const u8{
        "-std=c11",
        "-ffreestanding",
        "-nostdlibinc",
        "-fno-builtin",
        "-fno-stack-protector",
        "-fPIC",
        "-Wall",
        "-Wno-unused-command-line-argument",
    };

    const user_mod = b.createModule(.{
        .root_source_file = b.path("user/root.zig"),
        .target = b.resolveTargetQuery(board.userQuery()),
        .optimize = .ReleaseSmall,
        .pic = true,
        .strip = true,
        .single_threaded = true,
        .stack_protector = false,
        .stack_check = false,
        .red_zone = false,
        .omit_frame_pointer = false,
        .code_model = .small,
    });
    user_mod.addIncludePath(b.path("lib/libc/include"));
    user_mod.addCSourceFiles(.{
        .root = b.path("lib/libc/src"),
        .files = &.{
            "string.c",
            "ctype.c",
            "stdlib.c",
            "stdio.c",
            "errno.c",
            "assert.c",
        },
        .flags = &cflags,
    });
    user_mod.addCSourceFiles(.{
        .root = b.path("user"),
        .files = &.{
            "crt0.c",
            "sys.c",
            "hello.c",
        },
        .flags = &cflags,
    });
    const hello = b.addExecutable(.{
        .name = "hello.elf",
        .root_module = user_mod,
    });
    hello.setLinkerScript(b.path("user/link.ld"));
    hello.entry = .{ .symbol_name = "_start" };
    hello.link_gc_sections = true;
    b.installArtifact(hello);

    const view_mod = b.createModule(.{
        .root_source_file = b.path("user/root.zig"),
        .target = b.resolveTargetQuery(board.userQuery()),
        .optimize = .ReleaseSmall,
        .pic = true,
        .strip = true,
        .single_threaded = true,
        .stack_protector = false,
        .stack_check = false,
        .red_zone = false,
        .omit_frame_pointer = false,
        .code_model = .small,
    });
    view_mod.addIncludePath(b.path("lib/libc/include"));
    view_mod.addIncludePath(b.path("user"));
    view_mod.addCSourceFiles(.{
        .root = b.path("lib/libc/src"),
        .files = &.{
            "string.c",
            "ctype.c",
            "stdlib.c",
            "stdio.c",
            "errno.c",
            "assert.c",
            "math.c",
        },
        .flags = &cflags,
    });
    view_mod.addCSourceFiles(.{
        .root = b.path("user"),
        .files = &.{
            "crt0.c",
            "sys.c",
            "http.c",
            "view.c",
        },
        .flags = &cflags,
    });
    const view = b.addExecutable(.{
        .name = "view.elf",
        .root_module = view_mod,
    });
    view.setLinkerScript(b.path("user/link.ld"));
    view.entry = .{ .symbol_name = "_start" };
    view.link_gc_sections = true;
    b.installArtifact(view);

    const fatimage_mod = b.createModule(.{
        .root_source_file = b.path("lib/fatimage.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const mkimage_mod = b.createModule(.{
        .root_source_file = b.path("tools/mkimage.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    mkimage_mod.addImport("fatimage", fatimage_mod);
    const mkimage = b.addExecutable(.{ .name = "mkimage", .root_module = mkimage_mod });
    const run_mkimage = b.addRunArtifact(mkimage);
    run_mkimage.addFileArg(kernel.getEmittedBin());
    const image_path = run_mkimage.addOutputFileArg("aizigos.img");
    run_mkimage.addArg(b.fmt("{d}", .{image_mib}));
    // A file the running kernel can read back off its own boot disk.
    run_mkimage.addFileArg(b.path("image/README.TXT"));
    run_mkimage.addFileArg(hello.getEmittedBin());
    run_mkimage.addFileArg(view.getEmittedBin());
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
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("kernel/tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    tests_mod.addImport("fatimage", b.createModule(.{
        .root_source_file = b.path("lib/fatimage.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }));
    const tests = b.addTest(.{ .root_module = tests_mod });
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
                // The default qemu64 processor has no RDRAND, and this system
                // refuses to build keys out of a stopwatch: without a real
                // generator, TLS declines to run at all. Ask for one.
                "-cpu",
                "qemu64,+rdrand",
            });
            if (headless) {
                qemu.addArgs(&.{ "-display", "none", "-serial", "stdio" });
            } else {
                // The framebuffer console is the interface: show the window,
                // and keep a copy of everything on the serial line as well.
                qemu.addArgs(&.{ "-serial", "stdio" });
            }
            // User-mode networking: the guest gets 10.0.2.15 behind a NAT with
            // the gateway at 10.0.2.2, which needs no privileges on the host.
            qemu.addArgs(&.{ "-netdev", "user,id=n0", "-device", "e1000,netdev=n0" });
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
