//! EL1 exception vector table and the shared handler.

const uart = @import("uart.zig");
const regs = @import("regs.zig");
const gic = @import("gic.zig");
const timer = @import("timer.zig");
const types = @import("../types.zig");

/// Kernel hook: called on every timer tick and external interrupt.
/// Installed once at init so the HAL never needs to know the scheduler.
pub var on_trap: ?*const fn (kind: types.TrapKind, esr: u64, addr: u64) void = null;

comptime {
    asm (
        \\.macro TRAP_SAVE
        \\  sub sp, sp, #272
        \\  stp x0,  x1,  [sp, #0]
        \\  stp x2,  x3,  [sp, #16]
        \\  stp x4,  x5,  [sp, #32]
        \\  stp x6,  x7,  [sp, #48]
        \\  stp x8,  x9,  [sp, #64]
        \\  stp x10, x11, [sp, #80]
        \\  stp x12, x13, [sp, #96]
        \\  stp x14, x15, [sp, #112]
        \\  stp x16, x17, [sp, #128]
        \\  stp x18, x19, [sp, #144]
        \\  stp x20, x21, [sp, #160]
        \\  stp x22, x23, [sp, #176]
        \\  stp x24, x25, [sp, #192]
        \\  stp x26, x27, [sp, #208]
        \\  stp x28, x29, [sp, #224]
        \\  str x30,      [sp, #240]
        \\  mrs x0, elr_el1
        \\  mrs x1, spsr_el1
        \\  stp x0, x1,   [sp, #256]
        \\.endm
        \\
        \\.macro TRAP_RESTORE
        \\  ldp x0, x1,   [sp, #256]
        \\  msr elr_el1, x0
        \\  msr spsr_el1, x1
        \\  ldp x0,  x1,  [sp, #0]
        \\  ldp x2,  x3,  [sp, #16]
        \\  ldp x4,  x5,  [sp, #32]
        \\  ldp x6,  x7,  [sp, #48]
        \\  ldp x8,  x9,  [sp, #64]
        \\  ldp x10, x11, [sp, #80]
        \\  ldp x12, x13, [sp, #96]
        \\  ldp x14, x15, [sp, #112]
        \\  ldp x16, x17, [sp, #128]
        \\  ldp x18, x19, [sp, #144]
        \\  ldp x20, x21, [sp, #160]
        \\  ldp x22, x23, [sp, #176]
        \\  ldp x24, x25, [sp, #192]
        \\  ldp x26, x27, [sp, #208]
        \\  ldp x28, x29, [sp, #224]
        \\  ldr x30,      [sp, #240]
        \\  add sp, sp, #272
        \\  eret
        \\.endm
        \\
        \\.macro TRAP_ENTRY kind
        \\  TRAP_SAVE
        \\  mov x0, #\kind
        \\  mrs x1, esr_el1
        \\  mrs x2, far_el1
        \\  bl aizigos_trap
        \\  TRAP_RESTORE
        \\.endm
        \\
        \\.section .text.vectors,"ax",@progbits
        \\.balign 2048
        \\.global aizigos_vectors
        \\aizigos_vectors:
        \\  .balign 128
        \\  TRAP_ENTRY 0
        \\  .balign 128
        \\  TRAP_ENTRY 1
        \\  .balign 128
        \\  TRAP_ENTRY 2
        \\  .balign 128
        \\  TRAP_ENTRY 3
        \\  .balign 128
        \\  TRAP_ENTRY 0
        \\  .balign 128
        \\  TRAP_ENTRY 1
        \\  .balign 128
        \\  TRAP_ENTRY 2
        \\  .balign 128
        \\  TRAP_ENTRY 3
        \\  .balign 128
        \\  TRAP_ENTRY 4
        \\  .balign 128
        \\  TRAP_ENTRY 5
        \\  .balign 128
        \\  TRAP_ENTRY 6
        \\  .balign 128
        \\  TRAP_ENTRY 7
        \\  .balign 128
        \\  TRAP_ENTRY 4
        \\  .balign 128
        \\  TRAP_ENTRY 5
        \\  .balign 128
        \\  TRAP_ENTRY 6
        \\  .balign 128
        \\  TRAP_ENTRY 7
    );
}

extern const aizigos_vectors: anyopaque;

pub fn install() void {
    regs.msr("vbar_el1", @intFromPtr(&aizigos_vectors));
    regs.isb();
}

const ec_svc64: u32 = 0x15;
const ec_iabt_lower: u32 = 0x20;
const ec_iabt_same: u32 = 0x21;
const ec_dabt_lower: u32 = 0x24;
const ec_dabt_same: u32 = 0x25;
const ec_unknown: u32 = 0x00;

export fn aizigos_trap(kind: u64, esr: u64, far: u64) callconv(.c) void {
    const ec: u32 = @truncate((esr >> 26) & 0x3F);
    const from_user = kind >= 4;
    const slot = kind % 4;

    switch (slot) {
        // synchronous exception
        0 => {
            const trap: types.TrapKind = switch (ec) {
                ec_svc64 => .syscall,
                ec_iabt_lower, ec_iabt_same, ec_dabt_lower, ec_dabt_same => .page_fault,
                ec_unknown => .undefined_instruction,
                else => .fault_other,
            };
            if (on_trap) |cb| {
                cb(trap, esr, far);
            } else {
                fatal(trap, esr, far, from_user);
            }
        },
        // IRQ
        1 => {
            const id = gic.claim();
            if (id != gic.spurious) {
                if (id == timer.irq) {
                    timer.ack();
                    if (on_trap) |cb| cb(.timer, esr, far);
                } else {
                    if (on_trap) |cb| cb(.irq, esr, id);
                }
                gic.complete(id);
            }
        },
        // FIQ / SError
        else => fatal(.fault_other, esr, far, from_user),
    }
}

fn fatal(kind: types.TrapKind, esr: u64, far: u64, from_user: bool) void {
    uart.write("\n[trap] unhandled exception: ");
    uart.write(@tagName(kind));
    uart.write(if (from_user) " (EL0)\n" else " (EL1)\n");
    writeHex("  ESR = ", esr);
    writeHex("  FAR = ", far);
    while (true) regs.wfi();
}

fn writeHex(prefix: []const u8, value: u64) void {
    uart.write(prefix);
    const digits = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var i: usize = 16;
    var v = value;
    while (i > 0) {
        i -= 1;
        buf[i] = digits[@intCast(v & 0xF)];
        v >>= 4;
    }
    uart.write("0x");
    uart.write(&buf);
    uart.write("\n");
}
