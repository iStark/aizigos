//! The first user-mode programs.
//!
//! Baked-in assembler blobs, used until `exec` loads a real ELF64 off the
//! volume. They still prove the privilege drop: mapped user-accessible, entered
//! unprivileged, and able to reach the kernel only through the system call gate.
//!
//! `hello` writes a line, asks the kernel to report its privilege level (which
//! is how it proves it is unprivileged) and then yields forever. `faulting`
//! reaches for kernel memory on purpose, to show what happens when a program
//! misbehaves: it dies, and nothing else does.

const builtin = @import("builtin");
const hal = @import("hal/hal.zig");
const klog = @import("klog.zig");
const pmm = @import("mm/pmm.zig");
const vmm = @import("mm/vmm.zig");
const layout = @import("mm/layout.zig");

/// Well above anything the kernel identity-maps, so user mappings cannot
/// collide with the huge pages the kernel uses for itself.
pub const code_va: u64 = layout.code_va;
pub const stack_va: u64 = layout.stack_va;
pub const stack_pages: usize = layout.stack_pages;

pub const Program = enum { hello, faulting };

const x86_blob =
    \\.text
    \\.balign 16
    \\.global aizigos_user_blob_start
    \\aizigos_user_blob_start:
    \\  xorq %rax, %rax
    \\  leaq aizigos_user_msg(%rip), %rdi
    \\  movq $(aizigos_user_blob_end - aizigos_user_msg), %rsi
    \\  int $0x80
    \\  movq $7, %rax
    \\  xorq %rdi, %rdi
    \\  movw %cs, %di
    \\  int $0x80
    \\aizigos_user_loop:
    \\  movq $1, %rax
    \\  int $0x80
    \\  jmp aizigos_user_loop
    \\aizigos_user_msg:
    \\  .ascii "  a user program is running\n"
    \\.global aizigos_user_blob_end
    \\aizigos_user_blob_end:
    \\
    \\.balign 16
    \\.global aizigos_user_bad_start
    \\aizigos_user_bad_start:
    \\  xorq %rax, %rax
    \\  leaq aizigos_user_bad_msg(%rip), %rdi
    \\  movq $(aizigos_user_bad_end - aizigos_user_bad_msg), %rsi
    \\  int $0x80
    \\  movq $0x1000, %rax
    \\  movq $1, (%rax)
    \\aizigos_user_bad_loop:
    \\  jmp aizigos_user_bad_loop
    \\aizigos_user_bad_msg:
    \\  .ascii "  reaching for kernel memory now\n"
    \\.global aizigos_user_bad_end
    \\aizigos_user_bad_end:
;

const aarch64_blob =
    \\.section .text.userblob,"ax",@progbits
    \\.balign 16
    \\.global aizigos_user_blob_start
    \\aizigos_user_blob_start:
    \\  mov x8, #0
    \\  adr x0, aizigos_user_msg
    \\  mov x1, #(aizigos_user_blob_end - aizigos_user_msg)
    \\  svc #0
    \\  mov x8, #7
    \\  mov x0, #0
    \\  svc #0
    \\aizigos_user_loop:
    \\  mov x8, #1
    \\  svc #0
    \\  b aizigos_user_loop
    \\aizigos_user_msg:
    \\  .ascii "  a user program is running\n"
    \\.global aizigos_user_blob_end
    \\aizigos_user_blob_end:
    \\
    \\.balign 16
    \\.global aizigos_user_bad_start
    \\aizigos_user_bad_start:
    \\  mov x8, #0
    \\  adr x0, aizigos_user_bad_msg
    \\  mov x1, #(aizigos_user_bad_end - aizigos_user_bad_msg)
    \\  svc #0
    \\  mov x0, #0x1000
    \\  mov x1, #1
    \\  str x1, [x0]
    \\aizigos_user_bad_loop:
    \\  b aizigos_user_bad_loop
    \\aizigos_user_bad_msg:
    \\  .ascii "  reaching for kernel memory now\n"
    \\.global aizigos_user_bad_end
    \\aizigos_user_bad_end:
;

pub const supported = (builtin.os.tag == .freestanding or builtin.os.tag == .uefi) and
    (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64);

comptime {
    if (supported) {
        switch (builtin.cpu.arch) {
            .x86_64 => asm (x86_blob),
            .aarch64 => asm (aarch64_blob),
            else => {},
        }
    }
}

extern const aizigos_user_blob_start: anyopaque;
extern const aizigos_user_blob_end: anyopaque;
extern const aizigos_user_bad_start: anyopaque;
extern const aizigos_user_bad_end: anyopaque;

pub fn image(program: Program) []const u8 {
    const start = switch (program) {
        .hello => @intFromPtr(&aizigos_user_blob_start),
        .faulting => @intFromPtr(&aizigos_user_bad_start),
    };
    const end = switch (program) {
        .hello => @intFromPtr(&aizigos_user_blob_end),
        .faulting => @intFromPtr(&aizigos_user_bad_end),
    };
    return @as([*]const u8, @ptrFromInt(start))[0 .. end - start];
}

pub const Error = error{
    OutOfMemory,
    MapFailed,
    TooLarge,
    Unsupported,
};

/// Map the program and a stack into `space` with user permissions, copy the
/// code in, and drop privilege. Each run gets its own frames, so two programs
/// can live at the same virtual address in different spaces.
pub fn run(frames: *pmm.Pmm, kernel_stack_top: u64, program: Program, space: *vmm.AddressSpace) Error!noreturn {
    if (!supported) return Error.Unsupported;

    const code = image(program);
    if (code.len > hal.page_size) return Error.TooLarge;

    const code_pa = frames.alloc() catch return Error.OutOfMemory;

    const dst: [*]u8 = @ptrFromInt(code_pa);
    @memset(dst[0..hal.page_size], 0);
    @memcpy(dst[0..code.len], code);

    space.mapOwned(code_va, code_pa, 1, .{
        .read = true,
        .exec = true,
        .user = true,
    }) catch {
        frames.free(code_pa) catch {};
        return Error.MapFailed;
    };

    space.mapAnonymous(frames, stack_va, stack_pages, .{
        .read = true,
        .write = true,
        .user = true,
    }) catch return Error.MapFailed;

    klog.info("entering user mode: {s} at 0x{x}", .{ @tagName(program), code_va });
    space.activate();
    hal.setKernelStack(kernel_stack_top);
    @import("fp.zig").prepareReturnToUser();
    hal.enterUserMode(code_va, stack_va + stack_pages * hal.page_size);
}
