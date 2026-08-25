//! The kernel side of the C library's seam.
//!
//! Four functions, exported with the C ABI, are everything `lib/libc` is
//! allowed to reach for: memory from the kernel heap, output through the same
//! console the shell writes to, and a way to die. A C library that needs a
//! fifth one is a C library that needs a conversation first.

const hal = @import("hal/hal.zig");
const klog = @import("klog.zig");
const heap = @import("mm/heap.zig");

/// The heap the C code allocates from. The kernel's own tables stay static;
/// this exists for code that cannot work any other way.
pub var arena: ?*heap.Heap = null;

pub fn attach(kernel_heap: *heap.Heap) void {
    arena = kernel_heap;
}

export fn aizigos_alloc(size: usize) callconv(.c) ?[*]u8 {
    const target = arena orelse return null;
    return target.alloc(size) catch null;
}

export fn aizigos_realloc(pointer: ?[*]u8, size: usize) callconv(.c) ?[*]u8 {
    const target = arena orelse return null;
    return target.realloc(pointer, size) catch null;
}

export fn aizigos_free(pointer: ?[*]u8) callconv(.c) void {
    const target = arena orelse return;
    const block = pointer orelse return;
    target.free(block);
}

export fn aizigos_write(bytes: [*]const u8, length: usize) callconv(.c) void {
    klog.raw(bytes[0..length]);
}

export fn aizigos_panic(message: [*:0]const u8) callconv(.c) noreturn {
    var length: usize = 0;
    while (message[length] != 0) length += 1;
    klog.raw("\n[libc] ");
    klog.raw(message[0..length]);
    klog.raw("\n");
    hal.halt();
}

/// The C self test, which proves the whole path: compiled by this build,
/// linked into this kernel, running on this heap.
pub extern fn aizigos_libc_selftest() callconv(.c) c_int;
