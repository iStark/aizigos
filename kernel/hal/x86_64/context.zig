//! Kernel thread context switch (System V AMD64 callee-saved registers).

const serial = @import("serial.zig");

pub const Context = extern struct {
    rbx: u64 = 0,
    rbp: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
    rsp: u64 = 0,
};

comptime {
    asm (
        \\.section .text.ctx,"ax",@progbits
        \\.balign 16
        \\.global aizigos_ctx_switch
        \\aizigos_ctx_switch:
        \\  movq %rbx,  0(%rdi)
        \\  movq %rbp,  8(%rdi)
        \\  movq %r12, 16(%rdi)
        \\  movq %r13, 24(%rdi)
        \\  movq %r14, 32(%rdi)
        \\  movq %r15, 40(%rdi)
        \\  movq %rsp, 48(%rdi)
        \\  movq  0(%rsi), %rbx
        \\  movq  8(%rsi), %rbp
        \\  movq 16(%rsi), %r12
        \\  movq 24(%rsi), %r13
        \\  movq 32(%rsi), %r14
        \\  movq 40(%rsi), %r15
        \\  movq 48(%rsi), %rsp
        \\  retq
        \\
        \\.global aizigos_thread_trampoline
        \\aizigos_thread_trampoline:
        \\  movq %r13, %rdi
        \\  callq *%r12
        \\  callq aizigos_thread_returned
        \\5:
        \\  hlt
        \\  jmp 5b
    );
}

extern fn aizigos_ctx_switch(from: *Context, to: *Context) callconv(.c) void;
extern const aizigos_thread_trampoline: anyopaque;

export fn aizigos_thread_returned() callconv(.c) void {
    serial.write("[hal] thread returned from entry without exit()\n");
    while (true) asm volatile ("hlt");
}

pub fn ctxInit(ctx: *Context, entry: usize, stack_top: usize, arg: usize) void {
    const aligned = (stack_top & ~@as(usize, 15)) - 8;
    const slot: *usize = @ptrFromInt(aligned);
    slot.* = @intFromPtr(&aizigos_thread_trampoline);
    ctx.* = .{ .r12 = entry, .r13 = arg, .rsp = aligned };
}

pub fn ctxSwitch(from: *Context, to: *Context) void {
    aizigos_ctx_switch(from, to);
}
