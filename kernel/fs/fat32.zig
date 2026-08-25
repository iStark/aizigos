//! A read-only FAT32 driver, and just enough GPT to find the partition.
//!
//! Read-only on purpose. FR-3.1 asks for copy-on-write with live snapshots,
//! which FAT32 cannot do and should not be asked to; the native filesystem is
//! its own piece of work. What this is for is the disk the machine booted
//! from: the loader, the model weights, a configuration file. Firmware can
//! read that volume, so the kernel can too, and being able to read your own
//! boot medium without help is the difference between an image and a system.
//!
//! No allocation and no I/O of its own: sectors arrive through a Device, which
//! on real hardware is the ATA driver and in the tests is a byte slice. The
//! layout it parses is written by lib/fatimage.zig, and the two are checked
//! against each other in kernel/fs/fat32_test.zig.

const std = @import("std");

pub const sector_size = 512;

pub const Error = error{
    ReadFailed,
    NoPartition,
    NotFat32,
    NotFound,
    NotADirectory,
    IsADirectory,
    BadName,
    NoRoom,
};

/// Where sectors come from. `read` fills `buffer`, whose length is always a
/// multiple of the sector size, and answers whether it managed to.
pub const Device = struct {
    context: ?*anyopaque = null,
    read: *const fn (context: ?*anyopaque, lba: u64, buffer: []u8) bool,
};

pub const File = struct {
    cluster: u32,
    size: u32,
    is_dir: bool,
};

pub const Entry = struct {
    /// "BOOTX64.EFI", not the padded on-disk form.
    name: [13]u8 = @splat(0),
    name_len: u8 = 0,
    is_dir: bool = false,
    size: u32 = 0,
    cluster: u32 = 0,

    pub fn text(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }
};

const no_lba: u64 = 0xFFFF_FFFF_FFFF_FFFF;
const attr_directory = 0x10;
const attr_volume_id = 0x08;
const attr_long_name = 0x0F;

/// EFI System Partition type GUID, in the on-disk mixed-endian form.
const esp_type_guid = [16]u8{
    0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11,
    0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B,
};

pub const Volume = struct {
    device: Device,
    partition_lba: u64 = 0,
    sectors_per_cluster: u32 = 0,
    bytes_per_cluster: u32 = 0,
    fat_lba: u64 = 0,
    fat_sectors: u32 = 0,
    data_lba: u64 = 0,
    root_cluster: u32 = 0,
    cluster_count: u32 = 0,

    // Two buffers, because walking a chain means reading the FAT in the middle
    // of reading a directory, and one buffer would eat the other.
    dir_buffer: [sector_size]u8 = @splat(0),
    fat_buffer: [sector_size]u8 = @splat(0),
    fat_buffer_lba: u64 = no_lba,

    /// Find the EFI System Partition and read its boot sector.
    pub fn mount(device: Device) Error!Volume {
        var self = Volume{ .device = device };
        self.partition_lba = try findPartition(&self);
        try self.readBootSector();
        return self;
    }

    /// Mount a volume that starts at a known sector, skipping the partition
    /// table entirely. Useful for a bare FAT32 image.
    pub fn mountAt(device: Device, lba: u64) Error!Volume {
        var self = Volume{ .device = device, .partition_lba = lba };
        try self.readBootSector();
        return self;
    }

    fn readBootSector(self: *Volume) Error!void {
        const boot = &self.dir_buffer;
        try self.readSectors(self.partition_lba, boot);
        if (boot[510] != 0x55 or boot[511] != 0xAA) return Error.NotFat32;

        if (std.mem.readInt(u16, boot[11..13], .little) != sector_size) return Error.NotFat32;

        self.sectors_per_cluster = boot[13];
        if (self.sectors_per_cluster == 0) return Error.NotFat32;
        self.bytes_per_cluster = self.sectors_per_cluster * sector_size;

        const reserved = std.mem.readInt(u16, boot[14..16], .little);
        const num_fats = boot[16];
        // A FAT32 volume says zero in both of these; anything else is FAT12 or
        // FAT16, which this driver deliberately does not pretend to read.
        if (std.mem.readInt(u16, boot[17..19], .little) != 0) return Error.NotFat32;
        if (std.mem.readInt(u16, boot[22..24], .little) != 0) return Error.NotFat32;

        const small_total = std.mem.readInt(u16, boot[19..21], .little);
        const total_sectors: u32 = if (small_total != 0)
            small_total
        else
            std.mem.readInt(u32, boot[32..36], .little);

        self.fat_sectors = std.mem.readInt(u32, boot[36..40], .little);
        self.root_cluster = std.mem.readInt(u32, boot[44..48], .little);
        if (self.fat_sectors == 0 or self.root_cluster < 2) return Error.NotFat32;

        self.fat_lba = self.partition_lba + reserved;
        self.data_lba = self.fat_lba + @as(u64, num_fats) * self.fat_sectors;

        const metadata = reserved + @as(u32, num_fats) * self.fat_sectors;
        if (total_sectors <= metadata) return Error.NotFat32;
        self.cluster_count = (total_sectors - metadata) / self.sectors_per_cluster;
        self.fat_buffer_lba = no_lba;
    }

    fn readSectors(self: *Volume, lba: u64, buffer: []u8) Error!void {
        if (!self.device.read(self.device.context, lba, buffer)) return Error.ReadFailed;
    }

    fn clusterLba(self: *const Volume, cluster: u32) u64 {
        return self.data_lba + @as(u64, cluster - 2) * self.sectors_per_cluster;
    }

    fn isValid(self: *const Volume, cluster: u32) bool {
        return cluster >= 2 and cluster < self.cluster_count + 2;
    }

    /// The next cluster in a chain, or null at its end.
    fn nextCluster(self: *Volume, cluster: u32) Error!?u32 {
        if (!self.isValid(cluster)) return null;
        const offset = @as(u64, cluster) * 4;
        const lba = self.fat_lba + offset / sector_size;
        if (lba != self.fat_buffer_lba) {
            try self.readSectors(lba, &self.fat_buffer);
            self.fat_buffer_lba = lba;
        }
        const within: usize = @intCast(offset % sector_size);
        const value = std.mem.readInt(u32, self.fat_buffer[within..][0..4], .little) & 0x0FFF_FFFF;
        // 0 is free and 1 is reserved; neither can follow a live cluster, so
        // treat both as damage and stop rather than looping forever.
        if (value < 2 or value >= 0x0FFF_FFF8) return null;
        if (value >= self.cluster_count + 2) return null;
        return value;
    }

    /// Resolve a path such as "/EFI/BOOT/BOOTX64.EFI". Leading and trailing
    /// slashes are optional and repeated ones are ignored.
    pub fn open(self: *Volume, path: []const u8) Error!File {
        var current = File{ .cluster = self.root_cluster, .size = 0, .is_dir = true };
        var parts = std.mem.tokenizeScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, ".")) continue;
            if (!current.is_dir) return Error.NotADirectory;
            current = try self.lookup(current.cluster, part);
        }
        return current;
    }

    fn lookup(self: *Volume, directory: u32, name: []const u8) Error!File {
        const wanted = try shortName(name);
        var iterator = self.iterate(directory);
        while (try iterator.next()) |raw| {
            if (!std.mem.eql(u8, raw[0..11], &wanted)) continue;
            return fileFrom(&raw);
        }
        return Error.NotFound;
    }

    /// Fill `out` with the entries of a directory and return how many there
    /// were. Volume labels and long-name fragments are left out, and so is
    /// ".", which tells a reader nothing they did not already know.
    pub fn list(self: *Volume, path: []const u8, out: []Entry) Error!usize {
        const directory = try self.open(path);
        if (!directory.is_dir) return Error.NotADirectory;

        var count: usize = 0;
        var iterator = self.iterate(directory.cluster);
        while (try iterator.next()) |raw| {
            if (raw[0] == '.' and raw[1] == ' ') continue;
            if (count == out.len) return Error.NoRoom;
            const file = fileFrom(&raw);
            var entry = Entry{
                .is_dir = file.is_dir,
                .size = file.size,
                .cluster = file.cluster,
            };
            entry.name_len = @intCast(formatName(raw[0..11], &entry.name).len);
            out[count] = entry;
            count += 1;
        }
        return count;
    }

    /// Read up to `out.len` bytes of a file starting at `offset`, and return
    /// how many were read. A short read means the end of the file.
    pub fn read(self: *Volume, file: File, offset: u64, out: []u8) Error!usize {
        if (file.is_dir) return Error.IsADirectory;
        if (offset >= file.size) return 0;
        const wanted = @min(out.len, file.size - offset);

        // Walk to the cluster the offset falls in.
        var cluster = file.cluster;
        var skip = offset / self.bytes_per_cluster;
        while (skip > 0) : (skip -= 1) {
            cluster = try self.nextCluster(cluster) orelse return 0;
        }

        var done: usize = 0;
        var within: usize = @intCast(offset % self.bytes_per_cluster);
        while (done < wanted) {
            if (!self.isValid(cluster)) break;
            // A sector at a time through the scratch buffer: a caller's slice
            // has none of the alignment or length a device would ask for.
            const lba = self.clusterLba(cluster) + within / sector_size;
            try self.readSectors(lba, &self.dir_buffer);

            const from = within % sector_size;
            const take = @min(sector_size - from, wanted - done);
            @memcpy(out[done .. done + take], self.dir_buffer[from .. from + take]);
            done += take;
            within += take;

            if (within == self.bytes_per_cluster) {
                within = 0;
                cluster = try self.nextCluster(cluster) orelse break;
            }
        }
        return done;
    }

    fn iterate(self: *Volume, cluster: u32) DirIterator {
        return .{ .volume = self, .cluster = cluster };
    }
};

/// Walks the 32-byte entries of a directory across its whole cluster chain.
/// Entries come back by value: the next call reloads the buffer they sat in.
const DirIterator = struct {
    volume: *Volume,
    cluster: u32,
    sector: u32 = 0,
    index: u32 = 0,
    loaded: bool = false,
    finished: bool = false,

    fn next(self: *DirIterator) Error!?[32]u8 {
        const volume = self.volume;
        while (!self.finished) {
            if (!volume.isValid(self.cluster)) return null;
            if (!self.loaded) {
                try volume.readSectors(volume.clusterLba(self.cluster) + self.sector, &volume.dir_buffer);
                self.loaded = true;
            }

            const at = self.index * 32;
            if (at >= sector_size) {
                self.index = 0;
                self.loaded = false;
                self.sector += 1;
                if (self.sector == volume.sectors_per_cluster) {
                    self.sector = 0;
                    self.cluster = try volume.nextCluster(self.cluster) orelse {
                        self.finished = true;
                        return null;
                    };
                }
                continue;
            }
            self.index += 1;

            var raw: [32]u8 = undefined;
            @memcpy(&raw, volume.dir_buffer[at .. at + 32]);

            if (raw[0] == 0x00) {
                // A zero first byte ends the directory: everything past it is
                // free space rather than data.
                self.finished = true;
                return null;
            }
            if (raw[0] == 0xE5) continue; // deleted
            if (raw[11] & attr_long_name == attr_long_name) continue; // name fragment
            if (raw[11] & attr_volume_id != 0) continue; // the volume label
            return raw;
        }
        return null;
    }
};

fn fileFrom(raw: *const [32]u8) File {
    const high: u32 = std.mem.readInt(u16, raw[20..22], .little);
    const low: u32 = std.mem.readInt(u16, raw[26..28], .little);
    return .{
        .cluster = (high << 16) | low,
        .size = std.mem.readInt(u32, raw[28..32], .little),
        .is_dir = raw[11] & attr_directory != 0,
    };
}

/// Read the GPT and return the first sector of the EFI System Partition. A
/// disk with no GPT is not an error worth guessing about: say so and let the
/// caller decide whether to try a bare volume.
fn findPartition(volume: *Volume) Error!u64 {
    const header = &volume.dir_buffer;
    try volume.readSectors(1, header);
    if (!std.mem.eql(u8, header[0..8], "EFI PART")) return Error.NoPartition;

    const entries_lba = std.mem.readInt(u64, header[72..80], .little);
    const entry_count = std.mem.readInt(u32, header[80..84], .little);
    const entry_size = std.mem.readInt(u32, header[84..88], .little);
    if (entry_size == 0 or entry_size > sector_size) return Error.NoPartition;

    const per_sector = sector_size / entry_size;
    var index: u32 = 0;
    while (index < entry_count and index < 128) : (index += 1) {
        if (index % per_sector == 0) {
            try volume.readSectors(entries_lba + index / per_sector, &volume.dir_buffer);
        }
        const at = (index % per_sector) * entry_size;
        const entry = volume.dir_buffer[at..][0..@min(entry_size, 56)];
        if (!std.mem.eql(u8, entry[0..16], &esp_type_guid)) continue;
        return std.mem.readInt(u64, entry[32..40], .little);
    }
    return Error.NoPartition;
}

/// Fold "bootx64.efi" into the eleven padded bytes a directory entry holds.
/// Short names only: long-name entries are skipped when reading, so a name
/// this cannot express is a name this driver cannot find, and saying so beats
/// matching something else.
pub fn shortName(name: []const u8) Error![11]u8 {
    if (name.len == 0 or name.len > 12) return Error.BadName;
    if (std.mem.eql(u8, name, "..")) {
        var dots: [11]u8 = @splat(' ');
        dots[0] = '.';
        dots[1] = '.';
        return dots;
    }

    var out: [11]u8 = @splat(' ');
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const stem = name[0 .. dot orelse name.len];
    const extension = if (dot) |d| name[d + 1 ..] else "";
    if (stem.len == 0 or stem.len > 8 or extension.len > 3) return Error.BadName;

    for (stem, 0..) |c, i| out[i] = std.ascii.toUpper(c);
    for (extension, 0..) |c, i| out[8 + i] = std.ascii.toUpper(c);
    return out;
}

/// The other direction: "BOOTX64 EFI" becomes "BOOTX64.EFI".
pub fn formatName(raw: []const u8, out: *[13]u8) []const u8 {
    var length: usize = 0;
    var stem: usize = 8;
    while (stem > 0 and raw[stem - 1] == ' ') stem -= 1;
    for (raw[0..stem]) |c| {
        out[length] = c;
        length += 1;
    }
    var extension: usize = 11;
    while (extension > 8 and raw[extension - 1] == ' ') extension -= 1;
    if (extension > 8) {
        out[length] = '.';
        length += 1;
        for (raw[8..extension]) |c| {
            out[length] = c;
            length += 1;
        }
    }
    return out[0..length];
}
