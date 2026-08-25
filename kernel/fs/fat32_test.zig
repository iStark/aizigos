//! The FAT32 reader, checked against the writer that makes the real image.
//!
//! These live in their own file because they import the image builder, which
//! is a host-side module the kernel itself never links. What they prove is
//! that `zig build image` and the driver in the running kernel agree about
//! what is on the disk — the two halves were written apart, so they are made
//! to meet here rather than on a machine that has already booted.

const std = @import("std");
const fatimage = @import("fatimage");
const fat32 = @import("fat32.zig");
const testing = std.testing;

/// The smallest image a FAT32 volume is allowed to be, plus room to work in.
const image_mib = 40;

const Image = struct {
    bytes: []u8,

    fn read(context: ?*anyopaque, lba: u64, buffer: []u8) bool {
        const self: *Image = @ptrCast(@alignCast(context.?));
        const from = lba * fat32.sector_size;
        if (from + buffer.len > self.bytes.len) return false;
        @memcpy(buffer, self.bytes[from .. from + buffer.len]);
        return true;
    }

    fn device(self: *Image) fat32.Device {
        return .{ .context = self, .read = read };
    }
};

fn buildImage(allocator: std.mem.Allocator, loader: []const u8, extras: []const fatimage.Entry) ![]u8 {
    const bytes = try allocator.alloc(u8, image_mib * 1024 * 1024);
    try fatimage.build(bytes, loader, extras);
    return bytes;
}

test "fat32: the loader written into the image reads back byte for byte" {
    const allocator = testing.allocator;

    // A payload larger than one cluster, so the FAT chain is actually walked,
    // and not a repeating pattern, so a misread cluster cannot look right.
    const loader = try allocator.alloc(u8, 5000);
    defer allocator.free(loader);
    var seed: u32 = 0x1234_5678;
    for (loader) |*byte| {
        seed = seed *% 1664525 +% 1013904223;
        byte.* = @truncate(seed >> 16);
    }

    const bytes = try buildImage(allocator, loader, &.{});
    defer allocator.free(bytes);

    var image = Image{ .bytes = bytes };
    var volume = try fat32.Volume.mount(image.device());

    try testing.expectEqual(@as(u64, fatimage.esp_first_lba), volume.partition_lba);

    const file = try volume.open("/EFI/BOOT/BOOTX64.EFI");
    try testing.expect(!file.is_dir);
    try testing.expectEqual(@as(u32, @intCast(loader.len)), file.size);

    const out = try allocator.alloc(u8, loader.len);
    defer allocator.free(out);
    try testing.expectEqual(loader.len, try volume.read(file, 0, out));
    try testing.expectEqualSlices(u8, loader, out);

    // Reading past the end stops at the end rather than running on.
    try testing.expectEqual(@as(usize, 0), try volume.read(file, loader.len, out));
}

test "fat32: a read at an offset lands in the right cluster" {
    const allocator = testing.allocator;

    const loader = try allocator.alloc(u8, 4096);
    defer allocator.free(loader);
    for (loader, 0..) |*byte, i| byte.* = @truncate(i);

    const bytes = try buildImage(allocator, loader, &.{});
    defer allocator.free(bytes);

    var image = Image{ .bytes = bytes };
    var volume = try fat32.Volume.mount(image.device());
    const file = try volume.open("/EFI/BOOT/BOOTX64.EFI");

    // An offset in the middle of the third cluster, crossing into the fourth.
    var window: [700]u8 = undefined;
    try testing.expectEqual(window.len, try volume.read(file, 1000, &window));
    try testing.expectEqualSlices(u8, loader[1000 .. 1000 + window.len], &window);

    // The last handful of bytes, where the file ends mid-cluster.
    var tail: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 10), try volume.read(file, loader.len - 10, &tail));
    try testing.expectEqualSlices(u8, loader[loader.len - 10 ..], tail[0..10]);
}

test "fat32: root files and directory listings" {
    const allocator = testing.allocator;

    const readme = "AIZigOS read this off its own boot disk.\n";
    const bytes = try buildImage(allocator, "loader", &.{
        .{ .name_8_3 = "README  TXT", .data = readme },
        .{ .name_8_3 = "MODEL   BIN", .data = "weights would go here" },
    });
    defer allocator.free(bytes);

    var image = Image{ .bytes = bytes };
    var volume = try fat32.Volume.mount(image.device());

    var entries: [8]fat32.Entry = undefined;
    const count = try volume.list("/", &entries);
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualStrings("EFI", entries[0].text());
    try testing.expect(entries[0].is_dir);
    try testing.expectEqualStrings("README.TXT", entries[1].text());
    try testing.expect(!entries[1].is_dir);
    try testing.expectEqual(@as(u32, readme.len), entries[1].size);
    try testing.expectEqualStrings("MODEL.BIN", entries[2].text());

    // Case does not matter on the way in, and neither do extra slashes.
    const file = try volume.open("//readme.txt");
    var out: [64]u8 = undefined;
    const read = try volume.read(file, 0, &out);
    try testing.expectEqualStrings(readme, out[0..read]);

    const deep = try volume.list("/EFI/BOOT", &entries);
    try testing.expectEqual(@as(usize, 2), deep); // ".." and the loader
    try testing.expectEqualStrings("..", entries[0].text());
    try testing.expectEqualStrings("BOOTX64.EFI", entries[1].text());
}

test "fat32: paths that do not resolve say why" {
    const allocator = testing.allocator;
    const bytes = try buildImage(allocator, "loader", &.{});
    defer allocator.free(bytes);

    var image = Image{ .bytes = bytes };
    var volume = try fat32.Volume.mount(image.device());

    try testing.expectError(error.NotFound, volume.open("/NOPE.TXT"));
    try testing.expectError(error.NotFound, volume.open("/EFI/BOOT/OTHER.EFI"));
    // A file is not a directory, and walking through one is a mistake, not a
    // miss: the caller asked for something that cannot exist.
    try testing.expectError(error.NotADirectory, volume.open("/EFI/BOOT/BOOTX64.EFI/inside"));
    try testing.expectError(error.NotADirectory, volume.list("/EFI/BOOT/BOOTX64.EFI", &.{}));
    try testing.expectError(error.IsADirectory, volume.read(try volume.open("/EFI"), 0, &.{}));
    // Long names need long-name entries, which this driver skips on the way
    // in; refusing is honest, matching something similar would not be.
    try testing.expectError(error.BadName, volume.open("/a-rather-long-name.text"));
}

test "fat32: a disk with no partition table is reported, not guessed at" {
    const allocator = testing.allocator;
    const bytes = try allocator.alloc(u8, 4 * fat32.sector_size);
    defer allocator.free(bytes);
    @memset(bytes, 0);

    var image = Image{ .bytes = bytes };
    try testing.expectError(error.NoPartition, fat32.Volume.mount(image.device()));
    try testing.expectError(error.NotFat32, fat32.Volume.mountAt(image.device(), 0));
}

test "fat32: short names round trip" {
    var out: [13]u8 = undefined;
    try testing.expectEqualStrings("BOOTX64 EFI", &try fat32.shortName("bootx64.efi"));
    try testing.expectEqualStrings("BOOTX64.EFI", fat32.formatName("BOOTX64 EFI", &out));
    try testing.expectEqualStrings("EFI        ", &try fat32.shortName("EFI"));
    try testing.expectEqualStrings("EFI", fat32.formatName("EFI        ", &out));
    try testing.expectEqualStrings("..", fat32.formatName("..         ", &out));
    try testing.expectError(error.BadName, fat32.shortName("toolongname.txt"));
    try testing.expectError(error.BadName, fat32.shortName(""));
}
