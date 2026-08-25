//! GDT and TSS.
//!
//! The firmware leaves a GDT behind that works for kernel code, but it has no
//! ring 3 segments and no task state segment, so nothing can drop privilege on
//! it. This builds the kernel's own: kernel code and data, user code and data,
//! and a TSS whose RSP0 tells the CPU which stack to take an interrupt on when
//! it arrives from ring 3.

const builtin = @import("builtin");

pub const kernel_code: u16 = 0x08;
pub const kernel_data: u16 = 0x10;
pub const user_data: u16 = 0x18;
pub const user_code: u16 = 0x20;
pub const tss_selector: u16 = 0x28;

/// Selectors as user mode sees them, with the requested privilege level.
pub const user_code_rpl3: u16 = user_code | 3;
pub const user_data_rpl3: u16 = user_data | 3;

const Tss = extern struct {
    reserved0: u32 align(1) = 0,
    rsp0: u64 align(1) = 0,
    rsp1: u64 align(1) = 0,
    rsp2: u64 align(1) = 0,
    reserved1: u64 align(1) = 0,
    ist: [7]u64 align(1) = @splat(0),
    reserved2: u64 align(1) = 0,
    reserved3: u16 align(1) = 0,
    io_map_base: u16 align(1) = @sizeOf(Tss),
};

const Descriptor = extern struct {
    limit: u16 align(1),
    base: u64 align(1),
};

/// Five 8-byte entries plus a 16-byte TSS descriptor.
var gdt: [7]u64 align(16) = @splat(0);
var tss: Tss align(16) = .{};

/// Access byte bits: present, descriptor type, executable, read/write.
fn segment(dpl: u2, executable: bool, long_mode: bool) u64 {
    var access: u64 = 0b1001_0010; // present, code/data, read/write
    if (executable) access |= 0b0000_1000;
    access |= @as(u64, dpl) << 5;
    var flags: u64 = 0;
    if (long_mode) flags |= 0b0010; // L bit
    return (access << 40) | (flags << 52);
}

pub fn init(kernel_stack_top: u64) void {
    gdt[0] = 0;
    gdt[kernel_code / 8] = segment(0, true, true);
    gdt[kernel_data / 8] = segment(0, false, false);
    gdt[user_data / 8] = segment(3, false, false);
    gdt[user_code / 8] = segment(3, true, true);

    tss = .{};
    tss.rsp0 = kernel_stack_top;
    const tss_base = @intFromPtr(&tss);
    const tss_limit: u64 = @sizeOf(Tss) - 1;
    // A system descriptor is 16 bytes: type 9 (available 64-bit TSS), present.
    gdt[tss_selector / 8] = tss_limit |
        ((tss_base & 0xFFFF) << 16) |
        (((tss_base >> 16) & 0xFF) << 32) |
        (@as(u64, 0x89) << 40) |
        (((tss_base >> 24) & 0xFF) << 56);
    gdt[tss_selector / 8 + 1] = tss_base >> 32;

    const desc = Descriptor{ .limit = @sizeOf(@TypeOf(gdt)) - 1, .base = @intFromPtr(&gdt) };
    asm volatile (
        \\lgdt (%[desc])
        \\pushq %[code]
        \\leaq 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        \\movw %[data], %%ax
        \\movw %%ax, %%ds
        \\movw %%ax, %%es
        \\movw %%ax, %%ss
        \\movw %%ax, %%fs
        \\movw %%ax, %%gs
        :
        : [desc] "r" (&desc),
          [code] "i" (@as(u64, kernel_code)),
          [data] "i" (kernel_data),
        : .{ .rax = true, .memory = true });

    asm volatile ("ltr %[sel]"
        :
        : [sel] "r" (tss_selector),
        : .{ .memory = true });
}

/// Which stack the CPU should switch to when an interrupt arrives from ring 3.
/// Called on every switch to a user thread: get it wrong and the first
/// interrupt runs on the user's stack, which is exactly the hole ring 3 exists
/// to close.
pub fn setKernelStack(top: u64) void {
    tss.rsp0 = top;
}

/// Drop to ring 3 by faking the frame an interrupt return expects.
pub fn enterUserMode(entry: u64, user_stack_top: u64) noreturn {
    // System V wants rsp to be eight past a sixteen-byte boundary when a
    // function starts, because a call would have pushed a return address to
    // get there. Handing over a perfectly aligned stack shifts every local by
    // eight, and the first aligned SSE store into one of them is a general
    // protection fault. Nothing noticed until a program did some arithmetic
    // wide enough to want those instructions.
    const aligned = (user_stack_top & ~@as(u64, 15)) - 8;
    asm volatile (
        \\pushq %[ss]
        \\pushq %[rsp]
        \\pushq $0x202
        \\pushq %[cs]
        \\pushq %[rip]
        \\iretq
        :
        : [ss] "r" (@as(u64, user_data_rpl3)),
          [rsp] "r" (aligned),
          [cs] "r" (@as(u64, user_code_rpl3)),
          [rip] "r" (entry),
        : .{ .memory = true });
    unreachable;
}
