//! Zig root for the user executable. `_start` lives in crt0.c.
//!
//! The Zig side of a program is small on purpose, and everything in it is
//! there because C could not do the job: `tls.zig` is Zig's own TLS client,
//! which needs no allocator and no operating system and so runs here unchanged.

comptime {
    _ = @import("tls.zig");
}

pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    while (true) {}
}
