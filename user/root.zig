//! Zig root for the user executable. `_start` lives in crt0.c.

pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    while (true) {}
}
