//! Kernel thread context switch (AAPCS64 callee-saved registers).

pub const Context = extern struct {
    x19: u64 = 0,
    x20: u64 = 0,
    x21: u64 = 0,
    x22: u64 = 0,
    x23: u64 = 0,
    x24: u64 = 0,
    x25: u64 = 0,
    x26: u64 = 0,
    x27: u64 = 0,
    x28: u64 = 0,
    fp: u64 = 0,
    lr: u64 = 0,
    sp: u64 = 0,
};

comptime {
    asm (
        \\.section .text.ctx,"ax",@progbits
        \\.balign 16
        \\.global aizigos_ctx_switch
        \\aizigos_ctx_switch:
        \\  stp x19, x20, [x0, #0]
        \\  stp x21, x22, [x0, #16]
        \\  stp x23, x24, [x0, #32]
        \\  stp x25, x26, [x0, #48]
        \\  stp x27, x28, [x0, #64]
        \\  stp x29, x30, [x0, #80]
        \\  mov x9, sp
        \\  str x9, [x0, #96]
        \\  ldp x19, x20, [x1, #0]
        \\  ldp x21, x22, [x1, #16]
        \\  ldp x23, x24, [x1, #32]
        \\  ldp x25, x26, [x1, #48]
        \\  ldp x27, x28, [x1, #64]
        \\  ldp x29, x30, [x1, #80]
        \\  ldr x9, [x1, #96]
        \\  mov sp, x9
        \\  ret
        \\
        \\.global aizigos_thread_trampoline
        \\aizigos_thread_trampoline:
        \\  msr daifclr, #2
        \\  mov x0, x20
        \\  blr x19
        \\  bl aizigos_thread_returned
        \\  b .
    );
}

extern fn aizigos_ctx_switch(from: *Context, to: *Context) callconv(.c) void;
extern const aizigos_thread_trampoline: anyopaque;

/// A thread that returned from its entry point without calling exit().
export fn aizigos_thread_returned() callconv(.c) void {
    @import("uart.zig").write("[hal] thread returned from entry without exit()\n");
    while (true) @import("regs.zig").wfi();
}

pub fn ctxInit(ctx: *Context, entry: usize, stack_top: usize, arg: usize) void {
    ctx.* = .{
        .x19 = entry,
        .x20 = arg,
        .lr = @intFromPtr(&aizigos_thread_trampoline),
        .sp = stack_top & ~@as(usize, 15),
        .fp = 0,
    };
}

pub fn ctxSwitch(from: *Context, to: *Context) void {
    aizigos_ctx_switch(from, to);
}
