//! Builds a bootable UEFI disk image: GPT + one FAT32 EFI System Partition
//! containing /EFI/BOOT/BOOTX64.EFI, plus any extra files in the root.
//!
//! Written from scratch on purpose. The alternative is depending on GRUB,
//! xorriso and mtools, none of which exist on a plain Windows box, and the
//! whole point of the Zig toolchain here is that `zig build image` is enough.
//!
//! The layout itself lives in lib/fatimage.zig, because the kernel's own FAT32
//! reader is tested against images this code produces.
//!
//! The result boots in QEMU with OVMF and in VirtualBox with EFI enabled
//! (after `VBoxManage convertfromraw`).

const std = @import("std");
const fatimage = @import("fatimage");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.debug.print("usage: mkimage <BOOTX64.EFI> <out.img> [size-in-MiB] [[NAME=]file...]\n", .{});
        std.process.exit(2);
    }
    const efi_path = args[1];
    const out_path = args[2];
    const size_mib: u64 = if (args.len > 3) try std.fmt.parseInt(u64, args[3], 10) else 64;

    const cwd = std.Io.Dir.cwd();
    const efi = try cwd.readFileAlloc(init.io, efi_path, arena, .limited(32 << 20));

    var extras: std.ArrayList(fatimage.Entry) = .empty;
    for (args[@min(4, args.len)..]) |argument| {
        // "NAME=path" places the file under a name of the caller's choosing.
        // Three faces of the same family all shorten to the same eight
        // characters, and a volume with three files called NOTOSANS.TTF has
        // one file called NOTOSANS.TTF.
        var path = argument;
        var chosen: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, argument, '=')) |at| {
            chosen = argument[0..at];
            path = argument[at + 1 ..];
        }
        const data = try cwd.readFileAlloc(init.io, path, arena, .limited(8 << 20));
        const basename = chosen orelse std.fs.path.basename(path);
        const name = try arena.dupe(u8, &shortName(basename));
        try extras.append(arena, .{ .name_8_3 = name, .data = data });
    }

    const total_sectors: u32 = @intCast(size_mib * 1024 * 1024 / fatimage.sector_size);
    const image = try arena.alloc(u8, total_sectors * fatimage.sector_size);
    try fatimage.build(image, efi, extras.items);

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = image });

    std.debug.print("image: {s}\n", .{out_path});
    std.debug.print("  size      : {d} MiB ({d} sectors)\n", .{ size_mib, total_sectors });
    std.debug.print("  ESP       : LBA {d}..{d}\n", .{ fatimage.esp_first_lba, total_sectors - 34 });
    std.debug.print("  payload   : /EFI/BOOT/BOOTX64.EFI, {d} bytes\n", .{efi.len});
    for (extras.items) |entry| {
        std.debug.print("  file      : /{s}, {d} bytes\n", .{ entry.name_8_3, entry.data.len });
    }
}

/// Fold a host file name into the 11 padded bytes a short directory entry
/// wants. Long names are truncated rather than refused: this is a build tool,
/// and the file it is given is the file it should place.
fn shortName(basename: []const u8) [11]u8 {
    var out: [11]u8 = @splat(' ');
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.');
    const stem = basename[0 .. dot orelse basename.len];
    const extension = if (dot) |d| basename[d + 1 ..] else "";
    for (stem[0..@min(8, stem.len)], 0..) |c, i| out[i] = std.ascii.toUpper(c);
    for (extension[0..@min(3, extension.len)], 0..) |c, i| out[8 + i] = std.ascii.toUpper(c);
    return out;
}
