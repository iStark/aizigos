//! Kernel size budget audit (FR-1.5).
//!
//! Parses the built kernel's ELF64, prints a section table and fails if the
//! loadable image exceeds the budget.
//! .bss is reported separately: it takes no space in the image but does count
//! against the microkernel's RAM budget.

const std = @import("std");

const Section = struct {
    name: []const u8,
    size: u64,
    addr: u64,
    alloc: bool,
    nobits: bool,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.debug.print("usage: size-audit <kernel.elf> <budget-in-bytes>\n", .{});
        std.process.exit(2);
    }
    const path = args[1];
    const budget = try std.fmt.parseInt(u64, args[2], 10);

    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(64 << 20));

    if (data.len < 64 or !std.mem.eql(u8, data[0..4], "\x7fELF")) {
        std.debug.print("not an ELF file: {s}\n", .{path});
        std.process.exit(2);
    }

    const shoff = std.mem.readInt(u64, data[0x28..0x30], .little);
    const shentsize = std.mem.readInt(u16, data[0x3A..0x3C], .little);
    const shnum = std.mem.readInt(u16, data[0x3C..0x3E], .little);
    const shstrndx = std.mem.readInt(u16, data[0x3E..0x40], .little);

    const strtab_off = sectionField(data, shoff, shentsize, shstrndx, 0x18);
    const strtab: []const u8 = data[@intCast(strtab_off)..];

    var sections: std.ArrayList(Section) = .empty;
    var image_bytes: u64 = 0;
    var bss_bytes: u64 = 0;

    var i: u16 = 0;
    while (i < shnum) : (i += 1) {
        const base: usize = @intCast(shoff + @as(u64, i) * shentsize);
        if (base + shentsize > data.len) break;
        const name_off = std.mem.readInt(u32, data[base..][0..4], .little);
        const sh_type = std.mem.readInt(u32, data[base + 4 ..][0..4], .little);
        const flags = std.mem.readInt(u64, data[base + 8 ..][0..8], .little);
        const addr = std.mem.readInt(u64, data[base + 16 ..][0..8], .little);
        const size = std.mem.readInt(u64, data[base + 32 ..][0..8], .little);

        const alloc_flag = flags & 0x2 != 0; // SHF_ALLOC
        const nobits = sh_type == 8; // SHT_NOBITS
        if (!alloc_flag or size == 0) continue;

        const name = std.mem.sliceTo(strtab[name_off..], 0);
        if (nobits) bss_bytes += size else image_bytes += size;
        try sections.append(arena, .{
            .name = name,
            .size = size,
            .addr = addr,
            .alloc = alloc_flag,
            .nobits = nobits,
        });
    }

    std.debug.print("\nKernel size audit (FR-1.5): {s}\n", .{path});
    std.debug.print("{s:<20} {s:>12} {s:>18}\n", .{ "section", "bytes", "address" });
    std.debug.print("{s}\n", .{"-" ** 52});
    for (sections.items) |s| {
        std.debug.print("{s:<20} {d:>12} {s}0x{x:0>12}\n", .{
            s.name,
            s.size,
            if (s.nobits) "  (bss) " else "        ",
            s.addr,
        });
    }
    std.debug.print("{s}\n", .{"-" ** 52});

    try printTopSymbols(arena, data, shoff, shentsize, shnum, strtab);

    std.debug.print("image (text+rodata+data): {d} bytes ({d:.1} KiB)\n", .{ image_bytes, @as(f64, @floatFromInt(image_bytes)) / 1024.0 });
    std.debug.print("bss (RAM for tables):     {d} bytes ({d:.1} KiB)\n", .{ bss_bytes, @as(f64, @floatFromInt(bss_bytes)) / 1024.0 });
    std.debug.print("budget:                   {d} bytes ({d:.1} KiB)\n", .{ budget, @as(f64, @floatFromInt(budget)) / 1024.0 });

    if (image_bytes > budget) {
        const over = image_bytes - budget;
        std.debug.print("OVER BUDGET by {d} bytes ({d:.1}%)\n\n", .{
            over,
            @as(f64, @floatFromInt(over)) * 100.0 / @as(f64, @floatFromInt(budget)),
        });
        std.process.exit(1);
    }
    const left = budget - image_bytes;
    std.debug.print("within budget, {d} bytes to spare ({d:.1}%)\n\n", .{
        left,
        @as(f64, @floatFromInt(left)) * 100.0 / @as(f64, @floatFromInt(budget)),
    });
}

const Symbol = struct { name: []const u8, size: u64 };

/// Largest symbols: without this list it is guesswork what ate the budget.
fn printTopSymbols(
    arena: std.mem.Allocator,
    data: []const u8,
    shoff: u64,
    shentsize: u16,
    shnum: u16,
    shstrtab: []const u8,
) !void {
    var symtab_off: u64 = 0;
    var symtab_size: u64 = 0;
    var strtab_off: u64 = 0;

    var i: u16 = 0;
    while (i < shnum) : (i += 1) {
        const base: usize = @intCast(shoff + @as(u64, i) * shentsize);
        if (base + shentsize > data.len) break;
        const name_off = std.mem.readInt(u32, data[base..][0..4], .little);
        const name = std.mem.sliceTo(shstrtab[name_off..], 0);
        const off = std.mem.readInt(u64, data[base + 24 ..][0..8], .little);
        const size = std.mem.readInt(u64, data[base + 32 ..][0..8], .little);
        if (std.mem.eql(u8, name, ".symtab")) {
            symtab_off = off;
            symtab_size = size;
        } else if (std.mem.eql(u8, name, ".strtab")) {
            strtab_off = off;
        }
    }
    if (symtab_off == 0 or strtab_off == 0) return;

    const strtab: []const u8 = data[@intCast(strtab_off)..];
    var symbols: std.ArrayList(Symbol) = .empty;

    const entry_size = 24;
    var off: u64 = symtab_off;
    while (off + entry_size <= symtab_off + symtab_size) : (off += entry_size) {
        const base: usize = @intCast(off);
        const name_off = std.mem.readInt(u32, data[base..][0..4], .little);
        const size = std.mem.readInt(u64, data[base + 16 ..][0..8], .little);
        if (size == 0) continue;
        const name = std.mem.sliceTo(strtab[name_off..], 0);
        if (name.len == 0) continue;
        try symbols.append(arena, .{ .name = name, .size = size });
    }

    std.mem.sort(Symbol, symbols.items, {}, struct {
        fn lessThan(_: void, a: Symbol, b: Symbol) bool {
            return a.size > b.size;
        }
    }.lessThan);

    const show = @min(symbols.items.len, 10);
    if (show == 0) return;
    std.debug.print("largest symbols:\n", .{});
    for (symbols.items[0..show]) |s| {
        std.debug.print("  {d:>10}  {s}\n", .{ s.size, s.name });
    }
    std.debug.print("{s}\n", .{"-" ** 52});
}

fn sectionField(data: []const u8, shoff: u64, shentsize: u16, index: u16, offset: usize) u64 {
    const base: usize = @intCast(shoff + @as(u64, index) * shentsize);
    return std.mem.readInt(u64, data[base + offset ..][0..8], .little);
}
