//! IDT plus exception and IRQ handlers.

const builtin = @import("builtin");
const std = @import("std");
const serial = @import("serial.zig");
const pit = @import("pit.zig");
const types = @import("../types.zig");

pub var on_trap: ?types.TrapHandler = null;

/// Installed by the kernel; arguments are dug out of the trap frame below.
pub var on_syscall: ?types.SyscallHandler = null;

/// int 0x80 is the system call gate. Its descriptor is DPL=3 so that user code
/// will be able to reach it once there is user code.
pub const syscall_vector = 0x80;

/// The interrupt stubs that exist: the CPU exceptions, the 16 PIC lines and
/// the syscall gate.
const stub_vectors = blk: {
    var v: [49]u16 = undefined;
    for (0..48) |i| v[i] = @intCast(i);
    v[48] = syscall_vector;
    break :blk v;
};

const idt_entries = 256;

/// The saved register frame as the common stub lays it out.
const Frame = [*]u64;
const frame_rdx = 6;
const frame_rsi = 5;
const frame_rdi = 4;
const frame_rax = 8;
const frame_cs = 12;

const Entry = packed struct(u128) {
    offset_low: u16 = 0,
    selector: u16 = 0,
    ist: u8 = 0,
    type_attr: u8 = 0,
    offset_mid: u16 = 0,
    offset_high: u32 = 0,
    reserved: u32 = 0,
};

const Descriptor = extern struct {
    limit: u16 align(1),
    base: u64 align(1),
};

var idt: [idt_entries]Entry align(16) = @splat(.{});
var code_selector: u16 = 0x08;

/// The asm below is written for the SysV register order, and COFF (UEFI)
/// does not accept the ELF section syntax, so both are picked at comptime.
pub const sysv = std.builtin.CallingConvention{ .x86_64_sysv = .{} };
const text_section = if (builtin.object_format == .elf)
    ".section .text.isr,\"ax\",@progbits"
else
    ".text";
const rodata_section = if (builtin.object_format == .elf)
    ".section .rodata,\"a\",@progbits"
else
    ".section .rdata,\"dr\"";

comptime {
    asm (text_section ++
            \\
            \\.macro ISR_NOERR n
            \\  .balign 16
            \\  aizigos_isr\n:
            \\    pushq $0
            \\    pushq $\n
            \\    jmp aizigos_isr_common
            \\.endm
            \\.macro ISR_ERR n
            \\  .balign 16
            \\  aizigos_isr\n:
            \\    pushq $\n
            \\    jmp aizigos_isr_common
            \\.endm
            \\
            \\.irp v, 0,1,2,3,4,5,6,7,9,15,16,18,19,20,22,23,24,25,26,27,28,31
            \\  ISR_NOERR \v
            \\.endr
            \\.irp v, 8,10,11,12,13,14,17,21,29,30
            \\  ISR_ERR \v
            \\.endr
            \\.irp v, 32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,128
            \\  ISR_NOERR \v
            \\.endr
            \\
            \\aizigos_isr_common:
            \\  pushq %rax
            \\  pushq %rcx
            \\  pushq %rdx
            \\  pushq %rsi
            \\  pushq %rdi
            \\  pushq %r8
            \\  pushq %r9
            \\  pushq %r10
            \\  pushq %r11
            \\  movq 72(%rsp), %rdi
            \\  movq 80(%rsp), %rsi
            \\  movq %cr2, %rdx
            \\  movq %rsp, %rcx
            \\  callq aizigos_trap_x86
            \\  popq %r11
            \\  popq %r10
            \\  popq %r9
            \\  popq %r8
            \\  popq %rdi
            \\  popq %rsi
            \\  popq %rdx
            \\  popq %rcx
            \\  popq %rax
            \\  addq $16, %rsp
            \\  iretq
            \\
        ++ rodata_section ++
            \\
            \\.balign 8
            \\.global aizigos_isr_table
            \\aizigos_isr_table:
            \\.irp v, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,128
            \\  .quad aizigos_isr\v
            \\.endr
    );
}

extern const aizigos_isr_table: [stub_vectors.len]usize;

/// The code selector is whatever the current GDT uses: a multiboot kernel sets
/// up 0x08 itself, but UEFI firmware hands over its own GDT with a different
/// layout. Guessing here costs a #GP on the first interrupt and a triple fault.
fn codeSelector() u16 {
    return asm volatile ("movw %%cs, %[out]"
        : [out] "=r" (-> u16),
    );
}

pub fn init() void {
    code_selector = codeSelector();
    for (stub_vectors, 0..) |v, i| setGate(v, aizigos_isr_table[i]);
    const desc = Descriptor{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt) };
    asm volatile ("lidt (%[d])"
        :
        : [d] "r" (&desc),
        : .{ .memory = true });
}

fn setGate(vector: usize, handler: usize) void {
    idt[vector] = .{
        .offset_low = @truncate(handler),
        .selector = code_selector,
        .ist = 0,
        // present, interrupt gate; the syscall gate is reachable from ring 3.
        .type_attr = if (vector == syscall_vector) 0xEE else 0x8E,
        .offset_mid = @truncate(handler >> 16),
        .offset_high = @truncate(handler >> 32),
    };
}

const frame_rip = 11;
const frame_rsp = 14;

fn reportFault(vector: u64, err: u64, cr2: u64, frame: Frame) void {
    serial.write("[fault] vector=");
    hex(vector);
    serial.write(" err=");
    hex(err);
    serial.write(" cr2=");
    hex(cr2);
    serial.write(" rip=");
    hex(frame[frame_rip]);
    serial.write(" rsp=");
    hex(frame[frame_rsp]);
    serial.write("\n");
}

fn hex(value: u64) void {
    const digits = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var i: usize = 16;
    var v = value;
    while (i > 0) {
        i -= 1;
        buf[i] = digits[@intCast(v & 0xF)];
        v >>= 4;
    }
    serial.write("0x");
    serial.write(&buf);
}

export fn aizigos_trap_x86(vector: u64, err: u64, cr2: u64, frame: Frame) callconv(sysv) void {
    if (vector == syscall_vector) {
        if (on_syscall) |call| {
            // rax holds the number, rdi/rsi/rdx the arguments, rax the result.
            frame[frame_rax] = call(
                frame[frame_rax],
                frame[frame_rdi],
                frame[frame_rsi],
                frame[frame_rdx],
                frame[frame_cs] & 3 != 0,
            );
        }
        return;
    }
    const from_user = frame[frame_cs] & 3 != 0;
    if (vector >= 32) {
        const irq: u8 = @intCast(vector - 32);
        // End the interrupt first: the handler is allowed to switch tasks and
        // may not come back here for a long time.
        pit.eoi(irq);
        if (on_trap) |cb| cb(if (irq == 0) .timer else .irq, err, irq, from_user);
        return;
    }
    const kind: types.TrapKind = switch (vector) {
        6 => .undefined_instruction,
        14 => .page_fault,
        else => .fault_other,
    };
    // Where it happened matters more than what happened: without the
    // instruction pointer and the stack pointer a fault report is a guess.
    reportFault(vector, err, cr2, frame);
    if (on_trap) |cb| {
        cb(kind, err, cr2, from_user);
        return;
    }
    serial.write("\n[trap] unhandled x86 exception: ");
    serial.write(@tagName(kind));
    serial.write("\n");
    while (true) asm volatile ("hlt");
}
