//! Zig root for the user executable. `_start` lives in crt0.c.
//!
//! The Zig side of a program is small on purpose, and everything in it is
//! there because C could not do the job well: `tls.zig` is Zig's own TLS
//! client, which needs no allocator and no operating system and so runs here
//! unchanged, and `font.zig` is a TrueType rasteriser, which is all bounds and
//! offsets read out of a file someone else wrote.

comptime {
    _ = @import("tls.zig");
    _ = @import("font.zig");
}

pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    while (true) {}
}
