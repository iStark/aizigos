//! IDT + обработчики исключений и IRQ.

const serial = @import("serial.zig");
const pit = @import("pit.zig");
const types = @import("../types.zig");

pub var on_trap: ?*const fn (kind: types.TrapKind, esr: u64, addr: u64) void = null;

const vector_count = 48;

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

var idt: [vector_count]Entry align(16) = @splat(.{});

comptime {
    asm (
        \\.section .text.isr,"ax",@progbits
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
        \\.irp v, 32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47
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
        \\  movq 80(%rsp), %rdi
        \\  movq 88(%rsp), %rsi
        \\  movq %cr2, %rdx
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
        \\.section .rodata,"a",@progbits
        \\.balign 8
        \\.global aizigos_isr_table
        \\aizigos_isr_table:
        \\.irp v, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47
        \\  .quad aizigos_isr\v
        \\.endr
    );
}

extern const aizigos_isr_table: [vector_count]usize;

pub fn init() void {
    for (0..vector_count) |v| setGate(v, aizigos_isr_table[v]);
    const desc = Descriptor{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt) };
    asm volatile ("lidt (%[d])"
        :
        : [d] "r" (&desc),
        : .{ .memory = true });
}

fn setGate(vector: usize, handler: usize) void {
    idt[vector] = .{
        .offset_low = @truncate(handler),
        .selector = 0x08,
        .ist = 0,
        .type_attr = 0x8E, // present, DPL=0, interrupt gate
        .offset_mid = @truncate(handler >> 16),
        .offset_high = @truncate(handler >> 32),
    };
}

export fn aizigos_trap_x86(vector: u64, err: u64, cr2: u64) callconv(.c) void {
    if (vector >= 32) {
        const irq: u8 = @intCast(vector - 32);
        if (on_trap) |cb| cb(if (irq == 0) .timer else .irq, err, irq);
        pit.eoi(irq);
        return;
    }
    const kind: types.TrapKind = switch (vector) {
        6 => .undefined_instruction,
        14 => .page_fault,
        else => .fault_other,
    };
    if (on_trap) |cb| {
        cb(kind, err, cr2);
        return;
    }
    serial.write("\n[trap] необработанное исключение x86: ");
    serial.write(@tagName(kind));
    serial.write("\n");
    while (true) asm volatile ("hlt");
}
