//! Building a bootable disk image: GPT with one FAT32 EFI System Partition.
//!
//! This lives in a library rather than in the tool because the kernel's
//! filesystem tests read images built by exactly this code. A reader and a
//! writer that were written from the same specification but never met would
//! agree right up until they did not.

const std = @import("std");

pub const sector_size = 512;
pub const esp_first_lba = 2048;
const gpt_entries = 128;
const gpt_entry_size = 128;

pub const Error = error{ ImageTooSmall, TooManyFiles, NameTooLong };

/// A file to place in the root directory of the volume. The loader has its own
/// path and is passed separately.
pub const Entry = struct {
    /// An 8.3 name, upper case, exactly as it will appear on disk: "TEST TXT".
    name_8_3: []const u8,
    data: []const u8,
};

pub const max_root_entries = 8;

/// Lay out a whole disk image in `image`, which must be a multiple of the
/// sector size and at least large enough for a valid FAT32 volume.
pub fn build(image: []u8, loader: []const u8, extras: []const Entry) Error!void {
    if (image.len % sector_size != 0) return Error.ImageTooSmall;
    if (extras.len > max_root_entries) return Error.TooManyFiles;

    const total_sectors: u32 = @intCast(image.len / sector_size);
    if (total_sectors < 4096) return Error.ImageTooSmall;
    @memset(image, 0);

    const esp_last_lba: u32 = total_sectors - 34;
    writeProtectiveMbr(image, total_sectors);
    writeGpt(image, total_sectors, esp_first_lba, esp_last_lba);
    try writeFat32(
        image[esp_first_lba * sector_size .. (esp_last_lba + 1) * sector_size],
        loader,
        extras,
    );
}

// --- protective MBR -------------------------------------------------------

fn writeProtectiveMbr(image: []u8, total_sectors: u32) void {
    const p = image[0x1BE..];
    p[0] = 0x00; // not bootable
    p[1] = 0x00; // start CHS
    p[2] = 0x02;
    p[3] = 0x00;
    p[4] = 0xEE; // GPT protective
    p[5] = 0xFF; // end CHS
    p[6] = 0xFF;
    p[7] = 0xFF;
    std.mem.writeInt(u32, p[8..12], 1, .little);
    std.mem.writeInt(u32, p[12..16], @min(total_sectors - 1, 0xFFFF_FFFF), .little);
    image[510] = 0x55;
    image[511] = 0xAA;
}

// --- GPT ------------------------------------------------------------------

/// EFI System Partition type GUID, in the on-disk mixed-endian form.
const esp_type_guid = [16]u8{
    0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11,
    0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B,
};

/// Fixed GUIDs keep image builds byte-for-byte reproducible.
const disk_guid = [16]u8{
    0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
    0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x01,
};
const part_guid = [16]u8{
    0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18,
    0x29, 0x3A, 0x4B, 0x5C, 0x6D, 0x7E, 0x8F, 0x90,
};

fn writeGpt(image: []u8, total_sectors: u32, first_lba: u32, last_lba: u32) void {
    const entries_sectors = gpt_entries * gpt_entry_size / sector_size; // 32
    const primary_entries = image[2 * sector_size ..][0 .. entries_sectors * sector_size];

    const e = primary_entries[0..gpt_entry_size];
    @memcpy(e[0..16], &esp_type_guid);
    @memcpy(e[16..32], &part_guid);
    std.mem.writeInt(u64, e[32..40], first_lba, .little);
    std.mem.writeInt(u64, e[40..48], last_lba, .little);
    std.mem.writeInt(u64, e[48..56], 0, .little);
    const name = "EFI System";
    for (name, 0..) |c, i| std.mem.writeInt(u16, e[56 + i * 2 ..][0..2], c, .little);

    const entries_crc = std.hash.Crc32.hash(primary_entries);

    const backup_entries_lba = total_sectors - 1 - entries_sectors;
    @memcpy(
        image[backup_entries_lba * sector_size ..][0 .. entries_sectors * sector_size],
        primary_entries,
    );

    writeGptHeader(image[sector_size..][0..sector_size], .{
        .current = 1,
        .backup = total_sectors - 1,
        .first_usable = 34,
        .last_usable = total_sectors - 34,
        .entries_lba = 2,
        .entries_crc = entries_crc,
    });
    writeGptHeader(image[(total_sectors - 1) * sector_size ..][0..sector_size], .{
        .current = total_sectors - 1,
        .backup = 1,
        .first_usable = 34,
        .last_usable = total_sectors - 34,
        .entries_lba = backup_entries_lba,
        .entries_crc = entries_crc,
    });
}

const GptHeaderFields = struct {
    current: u64,
    backup: u64,
    first_usable: u64,
    last_usable: u64,
    entries_lba: u64,
    entries_crc: u32,
};

fn writeGptHeader(sector: []u8, f: GptHeaderFields) void {
    @memset(sector, 0);
    @memcpy(sector[0..8], "EFI PART");
    std.mem.writeInt(u32, sector[8..12], 0x0001_0000, .little); // revision 1.0
    std.mem.writeInt(u32, sector[12..16], 92, .little); // header size
    std.mem.writeInt(u32, sector[16..20], 0, .little); // header CRC, filled below
    std.mem.writeInt(u32, sector[20..24], 0, .little); // reserved
    std.mem.writeInt(u64, sector[24..32], f.current, .little);
    std.mem.writeInt(u64, sector[32..40], f.backup, .little);
    std.mem.writeInt(u64, sector[40..48], f.first_usable, .little);
    std.mem.writeInt(u64, sector[48..56], f.last_usable, .little);
    @memcpy(sector[56..72], &disk_guid);
    std.mem.writeInt(u64, sector[72..80], f.entries_lba, .little);
    std.mem.writeInt(u32, sector[80..84], gpt_entries, .little);
    std.mem.writeInt(u32, sector[84..88], gpt_entry_size, .little);
    std.mem.writeInt(u32, sector[88..92], f.entries_crc, .little);
    const crc = std.hash.Crc32.hash(sector[0..92]);
    std.mem.writeInt(u32, sector[16..20], crc, .little);
}

// --- FAT32 ----------------------------------------------------------------

fn writeFat32(part: []u8, loader: []const u8, extras: []const Entry) Error!void {
    const part_sectors: u32 = @intCast(part.len / sector_size);
    const reserved: u32 = 32;
    const num_fats: u32 = 2;
    const sectors_per_cluster: u32 = 1;

    // Solve for a FAT that describes the data area it leaves behind.
    var fat_sectors: u32 = 1;
    var clusters: u32 = 0;
    var iteration: usize = 0;
    while (iteration < 8) : (iteration += 1) {
        const data_sectors = part_sectors - reserved - num_fats * fat_sectors;
        clusters = data_sectors / sectors_per_cluster;
        const needed = ((clusters + 2) * 4 + sector_size - 1) / sector_size;
        if (needed == fat_sectors) break;
        fat_sectors = needed;
    }
    // Below 65525 clusters the volume would be FAT16 by definition, and some
    // firmware refuses an ESP that claims FAT32 with fewer.
    if (clusters < 65525) return Error.ImageTooSmall;

    const fat0_off = reserved * sector_size;
    const fat1_off = fat0_off + fat_sectors * sector_size;
    const data_off = fat1_off + fat_sectors * sector_size;

    writeBootSector(part[0..sector_size], part_sectors, reserved, num_fats, fat_sectors, sectors_per_cluster);
    writeFsInfo(part[sector_size..][0..sector_size]);
    // Backup boot sector at LBA 6, as the specification asks for.
    @memcpy(part[6 * sector_size ..][0..sector_size], part[0..sector_size]);
    @memcpy(part[7 * sector_size ..][0..sector_size], part[sector_size..][0..sector_size]);

    const fat = part[fat0_off..][0 .. fat_sectors * sector_size];
    const data = part[data_off..];
    const cluster_bytes = sectors_per_cluster * sector_size;

    setFat(fat, 0, 0x0FFF_FFF8);
    setFat(fat, 1, 0x0FFF_FFFF);

    // Cluster 2: the root directory.
    const root = data[0..cluster_bytes];
    @memset(root, 0);
    writeDirEntry(root[0..32], "EFI        ", 0x10, 3, 0);
    setFat(fat, 2, 0x0FFF_FFFF);

    // Cluster 3: /EFI.
    const efi_dir = data[cluster_bytes..][0..cluster_bytes];
    @memset(efi_dir, 0);
    writeDirEntry(efi_dir[0..32], ".          ", 0x10, 3, 0);
    writeDirEntry(efi_dir[32..64], "..         ", 0x10, 0, 0);
    writeDirEntry(efi_dir[64..96], "BOOT       ", 0x10, 4, 0);
    setFat(fat, 3, 0x0FFF_FFFF);

    // Cluster 4: /EFI/BOOT.
    const boot_dir = data[2 * cluster_bytes ..][0..cluster_bytes];
    @memset(boot_dir, 0);
    writeDirEntry(boot_dir[0..32], ".          ", 0x10, 4, 0);
    writeDirEntry(boot_dir[32..64], "..         ", 0x10, 3, 0);
    writeDirEntry(boot_dir[64..96], "BOOTX64 EFI", 0x20, 5, @intCast(loader.len));
    setFat(fat, 4, 0x0FFF_FFFF);

    var next_cluster: u32 = 5;
    next_cluster = try placeFile(fat, data, cluster_bytes, clusters, next_cluster, loader);

    // Anything else goes in the root directory, after the EFI entry.
    var slot: usize = 1;
    for (extras) |entry| {
        if (entry.name_8_3.len != 11) return Error.NameTooLong;
        const start = next_cluster;
        next_cluster = try placeFile(fat, data, cluster_bytes, clusters, next_cluster, entry.data);
        writeDirEntry(root[slot * 32 ..][0..32], entry.name_8_3, 0x20, start, @intCast(entry.data.len));
        slot += 1;
    }

    // The second FAT is an exact copy.
    @memcpy(part[fat1_off..][0 .. fat_sectors * sector_size], fat);
}

/// Copy a file into the data area starting at `start`, chaining its clusters,
/// and return the next free cluster.
fn placeFile(
    fat: []u8,
    data: []u8,
    cluster_bytes: u32,
    clusters: u32,
    start: u32,
    contents: []const u8,
) Error!u32 {
    const needed: u32 = @intCast((contents.len + cluster_bytes - 1) / cluster_bytes);
    if (start + needed > clusters + 2) return Error.ImageTooSmall;
    if (needed == 0) {
        return start;
    }

    var index: u32 = 0;
    while (index < needed) : (index += 1) {
        const cluster = start + index;
        const destination = data[(cluster - 2) * cluster_bytes ..][0..cluster_bytes];
        @memset(destination, 0);
        const from = index * cluster_bytes;
        const length = @min(cluster_bytes, contents.len - from);
        @memcpy(destination[0..length], contents[from .. from + length]);
        setFat(fat, cluster, if (index + 1 == needed) 0x0FFF_FFFF else cluster + 1);
    }
    return start + needed;
}

fn setFat(fat: []u8, index: u32, value: u32) void {
    const offset = index * 4;
    if (offset + 4 > fat.len) return;
    std.mem.writeInt(u32, fat[offset..][0..4], value, .little);
}

fn writeBootSector(
    sector: []u8,
    part_sectors: u32,
    reserved: u32,
    num_fats: u32,
    fat_sectors: u32,
    sectors_per_cluster: u32,
) void {
    @memset(sector, 0);
    sector[0] = 0xEB; // jmp short + nop, as every FAT volume starts
    sector[1] = 0x58;
    sector[2] = 0x90;
    @memcpy(sector[3..11], "AIZIGOS ");
    std.mem.writeInt(u16, sector[11..13], sector_size, .little);
    sector[13] = @intCast(sectors_per_cluster);
    std.mem.writeInt(u16, sector[14..16], @intCast(reserved), .little);
    sector[16] = @intCast(num_fats);
    std.mem.writeInt(u16, sector[17..19], 0, .little); // root entries: 0 on FAT32
    std.mem.writeInt(u16, sector[19..21], 0, .little); // small sector count: unused
    sector[21] = 0xF8; // fixed disk
    std.mem.writeInt(u16, sector[22..24], 0, .little); // FAT16 size: unused
    std.mem.writeInt(u16, sector[24..26], 32, .little); // sectors per track
    std.mem.writeInt(u16, sector[26..28], 8, .little); // heads
    std.mem.writeInt(u32, sector[28..32], esp_first_lba, .little); // hidden sectors
    std.mem.writeInt(u32, sector[32..36], part_sectors, .little);
    std.mem.writeInt(u32, sector[36..40], fat_sectors, .little);
    std.mem.writeInt(u16, sector[40..42], 0, .little); // ext flags: mirrored FATs
    std.mem.writeInt(u16, sector[42..44], 0, .little); // version
    std.mem.writeInt(u32, sector[44..48], 2, .little); // root cluster
    std.mem.writeInt(u16, sector[48..50], 1, .little); // FSInfo sector
    std.mem.writeInt(u16, sector[50..52], 6, .little); // backup boot sector
    sector[64] = 0x80; // drive number
    sector[66] = 0x29; // extended boot signature
    std.mem.writeInt(u32, sector[67..71], 0x4149_5A47, .little); // volume id
    @memcpy(sector[71..82], "AIZIGOS ESP");
    @memcpy(sector[82..90], "FAT32   ");
    sector[510] = 0x55;
    sector[511] = 0xAA;
}

fn writeFsInfo(sector: []u8) void {
    @memset(sector, 0);
    std.mem.writeInt(u32, sector[0..4], 0x4161_5252, .little);
    std.mem.writeInt(u32, sector[484..488], 0x6141_7272, .little);
    std.mem.writeInt(u32, sector[488..492], 0xFFFF_FFFF, .little); // free count unknown
    std.mem.writeInt(u32, sector[492..496], 0xFFFF_FFFF, .little); // next free unknown
    std.mem.writeInt(u32, sector[508..512], 0xAA55_0000, .little);
}

fn writeDirEntry(entry: []u8, name_8_3: []const u8, attr: u8, cluster: u32, size: u32) void {
    @memset(entry, 0);
    @memcpy(entry[0..11], name_8_3[0..11]);
    entry[11] = attr;
    std.mem.writeInt(u16, entry[20..22], @intCast(cluster >> 16), .little);
    std.mem.writeInt(u16, entry[26..28], @intCast(cluster & 0xFFFF), .little);
    std.mem.writeInt(u32, entry[28..32], size, .little);
    // A fixed timestamp, so images stay reproducible.
    std.mem.writeInt(u16, entry[22..24], 0, .little);
    std.mem.writeInt(u16, entry[24..26], (46 << 9) | (1 << 5) | 1, .little);
}
