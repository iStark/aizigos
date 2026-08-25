//! The first user-mode programs.
//!
//! They are blobs of position-independent machine code assembled into the
//! kernel image, because there is no filesystem to load a program from yet.
//! What matters is not where the code comes from but where it runs: mapped
//! into pages marked user-accessible, entered through the privilege drop, and
//! able to reach the kernel only through the system call gate.
//!
//! `hello` writes a line, asks the kernel to report its privilege level (which
//! is how it proves it is unprivileged) and then yields forever. `faulting`
//! reaches for kernel memory on purpose, to show what happens when a program
//! misbehaves: it dies, and nothing else does.

const builtin = @import("builtin");
const hal = @import("hal/hal.zig");
const klog = @import("klog.zig");
const pmm = @import("mm/pmm.zig");

/// Well above anything the kernel identity-maps, so user mappings cannot
/// collide with the huge pages the kernel uses for itself.
pub const code_va: u64 = 0x0000_0100_0000_0000;
pub const stack_va: u64 = 0x0000_0100_0010_0000;
pub const stack_pages: usize = 4;

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

/// The frames behind the user mapping, kept so a second program can reuse them
/// instead of failing on an address that is already mapped.
var code_frame: ?u64 = null;
var stack_frame: ?u64 = null;

/// Map the program and a stack with user permissions, copy the code in, and
/// drop privilege. Never returns: the calling thread continues as a user
/// thread and comes back only through the system call gate or a fault.
pub fn run(frames: *pmm.Pmm, kernel_stack_top: u64, program: Program) Error!noreturn {
    if (!supported) return Error.Unsupported;

    const code = image(program);
    if (code.len > hal.page_size) return Error.TooLarge;

    const first_time = code_frame == null;
    if (first_time) {
        code_frame = frames.allocContiguous(1) catch return Error.OutOfMemory;
        stack_frame = frames.allocContiguous(stack_pages) catch return Error.OutOfMemory;
    }

    // Physical memory is identity-mapped for the kernel, so the frame can be
    // written through its physical address before the user ever sees it.
    const dst: [*]u8 = @ptrFromInt(code_frame.?);
    @memset(dst[0..hal.page_size], 0);
    @memcpy(dst[0..code.len], code);

    if (first_time) {
        const space = hal.currentSpace();
        hal.asMap(space, code_va, code_frame.?, .{
            .read = true,
            .exec = true,
            .user = true,
        }) catch return Error.MapFailed;

        var i: usize = 0;
        while (i < stack_pages) : (i += 1) {
            hal.asMap(space, stack_va + i * hal.page_size, stack_frame.? + i * hal.page_size, .{
                .read = true,
                .write = true,
                .user = true,
            }) catch return Error.MapFailed;
        }
    }

    klog.info("entering user mode: {s} at 0x{x}", .{ @tagName(program), code_va });
    hal.setKernelStack(kernel_stack_top);
    hal.enterUserMode(code_va, stack_va + stack_pages * hal.page_size);
}
