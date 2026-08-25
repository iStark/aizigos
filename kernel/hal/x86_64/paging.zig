//! x86_64 page tables (four levels, 4 KiB pages). FR-1.2.

const types = @import("../types.zig");

pub const page_size: usize = 4096;
const entries_per_table = 512;
const table_pool_size = 32;

const Table = extern struct {
    e: [entries_per_table]u64 align(page_size) = @splat(0),
};

var table_pool: [table_pool_size]Table align(page_size) = @splat(.{});
var table_used: [table_pool_size]bool = @splat(false);

const p_present: u64 = 1 << 0;
const p_write: u64 = 1 << 1;
const p_user: u64 = 1 << 2;
const p_pwt: u64 = 1 << 3;
const p_pcd: u64 = 1 << 4;
const p_nx: u64 = 1 << 63;
const p_huge: u64 = 1 << 7; // PS: this entry maps a 2 MiB page
const addr_mask: u64 = 0x000F_FFFF_FFFF_F000;

fn allocTable() ?*Table {
    for (&table_used, 0..) |*used, i| {
        if (!used.*) {
            used.* = true;
            table_pool[i] = .{};
            return &table_pool[i];
        }
    }
    return null;
}

fn freeTable(t: *Table) void {
    const idx = (@intFromPtr(t) - @intFromPtr(&table_pool)) / @sizeOf(Table);
    if (idx < table_pool_size) table_used[idx] = false;
}

fn leafFlags(flags: types.MapFlags) u64 {
    var bits: u64 = p_present;
    if (flags.write) bits |= p_write;
    if (flags.user) bits |= p_user;
    if (flags.device) bits |= p_pwt | p_pcd;
    if (!flags.exec) bits |= p_nx;
    return bits;
}

fn index(level: u2, va: u64) usize {
    const shift: u6 = @intCast(39 - @as(u6, level) * 9);
    return @intCast((va >> shift) & 0x1FF);
}

pub const AddressSpace = struct {
    root: ?*Table = null,
    asid: u16 = 0,
};

var next_asid: u16 = 1;

pub fn asInit(space: *AddressSpace) types.MmuError!void {
    const root = allocTable() orelse return error.OutOfTables;
    space.* = .{ .root = root, .asid = next_asid };
    next_asid +%= 1;
    if (next_asid == 0) next_asid = 1;
}

pub fn asDeinit(space: *AddressSpace) void {
    if (space.root) |root| freeTree(root, 0);
    space.* = .{};
}

fn freeTree(table: *Table, level: u2) void {
    if (level < 3) {
        for (&table.e) |*entry_ptr| {
            const entry = entry_ptr.*;
            if (entry & p_present != 0) {
                const child: *Table = @ptrFromInt(entry & addr_mask);
                freeTree(child, level + 1);
            }
        }
    }
    freeTable(table);
}

fn walk(space: *AddressSpace, va: u64, create: bool) types.MmuError!*u64 {
    var table = space.root orelse return error.NotMapped;
    var level: u2 = 0;
    while (level < 3) : (level += 1) {
        const slot = &table.e[index(level, va)];
        if (slot.* & p_present == 0) {
            if (!create) return error.NotMapped;
            const child = allocTable() orelse return error.OutOfTables;
            slot.* = (@intFromPtr(child) & addr_mask) | p_present | p_write | p_user;
        } else if (level == 2 and slot.* & p_huge != 0) {
            // A 2 MiB page already covers this address. Splitting it is a
            // stage-3 problem; refusing is what keeps the identity map intact.
            return error.AlreadyMapped;
        }
        table = @ptrFromInt(slot.* & addr_mask);
    }
    return &table.e[index(3, va)];
}

pub fn asMap(space: *AddressSpace, va: types.VirtAddr, pa: types.PhysAddr, flags: types.MapFlags) types.MmuError!void {
    if (va % page_size != 0 or pa % page_size != 0) return error.Misaligned;
    const slot = try walk(space, va, true);
    if (slot.* & p_present != 0) return error.AlreadyMapped;
    slot.* = (pa & addr_mask) | leafFlags(flags);
    invlpg(va);
}

pub fn asUnmap(space: *AddressSpace, va: types.VirtAddr, pages: usize) types.MmuError!void {
    var i: usize = 0;
    while (i < pages) : (i += 1) {
        const addr = va + i * page_size;
        const slot = try walk(space, addr, false);
        if (slot.* & p_present == 0) return error.NotMapped;
        slot.* = 0;
        invlpg(addr);
    }
}

pub fn asTranslate(space: *AddressSpace, va: types.VirtAddr) ?types.PhysAddr {
    const base = va - (va % page_size);
    const slot = walk(space, base, false) catch return null;
    if (slot.* & p_present == 0) return null;
    return (slot.* & addr_mask) + (va % page_size);
}

pub const block_size: usize = 2 << 20;

/// Map one 2 MiB page at level 2. Identity-mapping RAM with 4 KiB pages would
/// need thousands of tables; with huge pages it needs a handful.
pub fn mapBlock(space: *AddressSpace, va: types.VirtAddr, pa: types.PhysAddr, flags: types.MapFlags) types.MmuError!void {
    if (va % block_size != 0 or pa % block_size != 0) return error.Misaligned;
    var table = space.root orelse return error.NotMapped;
    var level: u2 = 0;
    while (level < 2) : (level += 1) {
        const slot = &table.e[index(level, va)];
        if (slot.* & p_present == 0) {
            const child = allocTable() orelse return error.OutOfTables;
            slot.* = (@intFromPtr(child) & addr_mask) | p_present | p_write | p_user;
        }
        table = @ptrFromInt(slot.* & addr_mask);
    }
    const slot = &table.e[index(2, va)];
    if (slot.* & p_present != 0) return error.AlreadyMapped;
    slot.* = (pa & addr_mask) | leafFlags(flags) | p_huge;
}

/// Identity-map a physical range using 2 MiB pages.
pub fn identityMap(space: *AddressSpace, base: types.PhysAddr, len: u64, flags: types.MapFlags) types.MmuError!void {
    var addr = base & ~@as(u64, block_size - 1);
    const end = base + len;
    while (addr < end) : (addr += block_size) {
        mapBlock(space, addr, addr, flags) catch |e| switch (e) {
            error.AlreadyMapped => {},
            else => return e,
        };
    }
}

/// How many tables are still free in the pool, for diagnostics.
pub fn tablesLeft() usize {
    var n: usize = 0;
    for (table_used) |used| {
        if (!used) n += 1;
    }
    return n;
}

pub fn asActivate(space: *AddressSpace) void {
    const root = space.root orelse return;
    const cr3: u64 = @intFromPtr(root) & addr_mask;
    asm volatile ("movq %[v], %%cr3"
        :
        : [v] "r" (cr3),
        : .{ .memory = true });
}

fn invlpg(va: u64) void {
    asm volatile ("invlpg (%[v])"
        :
        : [v] "r" (va),
        : .{ .memory = true });
}
