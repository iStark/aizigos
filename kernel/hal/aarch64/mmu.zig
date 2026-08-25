//! AArch64 page tables (4 KiB granule, 48-bit VAs, four levels).
//! FR-1.2: isolation of process address spaces.

const types = @import("../types.zig");
const regs = @import("regs.zig");

pub const page_size: usize = 4096;
const entries_per_table = 512;

/// Table pool. The kernel has no dynamic memory, so tables come from a static
/// pool; exhausting it is an honest OutOfTables error.
/// Kernel identity maps plus a handful of process roots. Process page tables
/// will move to the PMM; until then this has to cover two user programs and
/// an ELF without returning OutOfTables.
const table_pool_size = 64;

const Table = extern struct {
    e: [entries_per_table]u64 align(page_size) = @splat(0),
};

var table_pool: [table_pool_size]Table align(page_size) = @splat(.{});
var table_used: [table_pool_size]bool = @splat(false);

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

// --- descriptor format ---------------------------------------------------

const desc_valid: u64 = 1 << 0;
const desc_table: u64 = 1 << 1; // levels 0..2: pointer to the next table
const desc_page: u64 = 1 << 1; // level 3: a page
const attr_af: u64 = 1 << 10; // Access Flag
const attr_sh_inner: u64 = 0b11 << 8;
const attr_ap_rw_el1: u64 = 0b00 << 6;
const attr_ap_rw_all: u64 = 0b01 << 6;
const attr_ap_ro_el1: u64 = 0b10 << 6;
const attr_ap_ro_all: u64 = 0b11 << 6;
const attr_pxn: u64 = 1 << 53;
const attr_uxn: u64 = 1 << 54;
const addr_mask: u64 = 0x0000_FFFF_FFFF_F000;

/// MAIR: index 0 is Normal WB, index 1 is Device-nGnRnE.
const mair_value: u64 = 0xFF | (0x00 << 8);
const attr_idx_normal: u64 = 0 << 2;
const attr_idx_device: u64 = 1 << 2;

fn leafAttrs(flags: types.MapFlags) u64 {
    var attrs: u64 = desc_valid | desc_page | attr_af | attr_sh_inner;
    attrs |= if (flags.device) attr_idx_device else attr_idx_normal;
    // AP bits: the write/user combination.
    attrs |= if (flags.user)
        (if (flags.write) attr_ap_rw_all else attr_ap_ro_all)
    else
        (if (flags.write) attr_ap_rw_el1 else attr_ap_ro_el1);
    if (!flags.exec) {
        attrs |= attr_pxn | attr_uxn;
    } else if (flags.user) {
        attrs |= attr_pxn; // user code stays non-executable in EL1
    } else {
        attrs |= attr_uxn;
    }
    return attrs;
}

fn index(level: u2, va: u64) usize {
    const shift: u6 = @intCast(39 - @as(u6, level) * 9);
    return @intCast((va >> shift) & 0x1FF);
}

pub const AddressSpace = struct {
    root: ?*Table = null,
    asid: u16 = 0,
    /// How many L0 slots are shared with the kernel and must not be freed.
    shared_slots: u16 = 0,
};

var next_asid: u16 = 1;

/// L0[0] and L0[1] cover the low 1 TiB (RAM at 0x4000_0000, MMIO). User
/// space starts at 1 TiB (L0[2]).
pub const kernel_shared_slots: u16 = 2;

/// APTable = 01: the whole subtree is unreachable from EL0.
const aptable_no_el0: u64 = 0b01 << 61;

pub fn asInit(space: *AddressSpace) types.MmuError!void {
    const root = allocTable() orelse return error.OutOfTables;
    space.* = .{ .root = root, .asid = next_asid };
    next_asid +%= 1;
    if (next_asid == 0) next_asid = 1;
}

pub fn asInitFromKernel(space: *AddressSpace, kernel: *AddressSpace) types.MmuError!void {
    try asInit(space);
    space.shared_slots = kernel_shared_slots;
    const dst = space.root orelse return error.NotMapped;
    const src = kernel.root orelse return;
    var i: usize = 0;
    while (i < kernel_shared_slots) : (i += 1) {
        const entry = src.e[i];
        dst.e[i] = if (entry & desc_valid != 0) entry | aptable_no_el0 else entry;
    }
}

pub fn asDeinit(space: *AddressSpace) void {
    if (space.root) |root| {
        const skip = space.shared_slots;
        if (skip == 0) {
            freeTableTree(root, 0);
        } else {
            var i: usize = skip;
            while (i < entries_per_table) : (i += 1) {
                const entry = root.e[i];
                if (entry & desc_valid != 0 and entry & desc_table != 0) {
                    const child: *Table = @ptrFromInt(entry & addr_mask);
                    freeTableTree(child, 1);
                }
            }
            freeTable(root);
        }
    }
    space.* = .{};
}

fn freeTableTree(table: *Table, level: u2) void {
    if (level < 3) {
        for (&table.e) |*entry_ptr| {
            const entry = entry_ptr.*;
            if (entry & desc_valid != 0 and entry & desc_table != 0) {
                const child: *Table = @ptrFromInt(entry & addr_mask);
                freeTableTree(child, level + 1);
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
        if (slot.* & desc_valid == 0) {
            if (!create) return error.NotMapped;
            const child = allocTable() orelse return error.OutOfTables;
            slot.* = (@intFromPtr(child) & addr_mask) | desc_valid | desc_table;
        } else if (slot.* & desc_table == 0) {
            // A block descriptor is a leaf: this address is already covered by
            // a 2 MiB mapping and walking into it would corrupt the map.
            return error.AlreadyMapped;
        }
        table = @ptrFromInt(slot.* & addr_mask);
    }
    return &table.e[index(3, va)];
}

pub fn asMap(space: *AddressSpace, va: types.VirtAddr, pa: types.PhysAddr, flags: types.MapFlags) types.MmuError!void {
    if (va % page_size != 0 or pa % page_size != 0) return error.Misaligned;
    const slot = try walk(space, va, true);
    if (slot.* & desc_valid != 0) return error.AlreadyMapped;
    slot.* = (pa & addr_mask) | leafAttrs(flags);
    regs.dsb();
    invalidate(va, space.asid);
}

pub fn asUnmap(space: *AddressSpace, va: types.VirtAddr, pages: usize) types.MmuError!void {
    var i: usize = 0;
    while (i < pages) : (i += 1) {
        const addr = va + i * page_size;
        const slot = try walk(space, addr, false);
        if (slot.* & desc_valid == 0) return error.NotMapped;
        slot.* = 0;
        invalidate(addr, space.asid);
    }
    regs.dsb();
}

pub fn asTranslate(space: *AddressSpace, va: types.VirtAddr) ?types.PhysAddr {
    const base = va - (va % page_size);
    const slot = walk(space, base, false) catch return null;
    if (slot.* & desc_valid == 0) return null;
    return (slot.* & addr_mask) + (va % page_size);
}

pub const block_size: usize = 2 << 20;

/// Map one 2 MiB block at level 2. Identity-mapping the whole of RAM with
/// 4 KiB pages would need thousands of tables; with blocks it needs three.
pub fn mapBlock(space: *AddressSpace, va: types.VirtAddr, pa: types.PhysAddr, flags: types.MapFlags) types.MmuError!void {
    if (va % block_size != 0 or pa % block_size != 0) return error.Misaligned;
    var table = space.root orelse return error.NotMapped;
    var level: u2 = 0;
    while (level < 2) : (level += 1) {
        const slot = &table.e[index(level, va)];
        if (slot.* & desc_valid == 0) {
            const child = allocTable() orelse return error.OutOfTables;
            slot.* = (@intFromPtr(child) & addr_mask) | desc_valid | desc_table;
        }
        table = @ptrFromInt(slot.* & addr_mask);
    }
    const slot = &table.e[index(2, va)];
    if (slot.* & desc_valid != 0) return error.AlreadyMapped;
    // A block descriptor is a leaf with bit 1 clear.
    slot.* = (pa & addr_mask) | (leafAttrs(flags) & ~desc_page);
}

/// Identity-map a physical range using 2 MiB blocks.
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

fn invalidate(va: u64, asid: u16) void {
    const operand: u64 = (@as(u64, asid) << 48) | (va >> 12);
    asm volatile ("tlbi vae1is, %[op]"
        :
        : [op] "r" (operand),
        : .{ .memory = true });
    regs.dsb();
    regs.isb();
}

/// Point TTBR0 at this space. The MMU must already be enabled.
pub fn asActivate(space: *AddressSpace) void {
    const root = space.root orelse return;
    const ttbr: u64 = (@as(u64, space.asid) << 48) | (@intFromPtr(root) & addr_mask);
    regs.msr("ttbr0_el1", ttbr);
    regs.isb();
}

/// Enable the MMU. Called only once a correct identity mapping for the
/// kernel has been built (see docs/ARCHITECTURE.md, stage 2).
pub fn enable(kernel_space: *AddressSpace) void {
    regs.msr("mair_el1", mair_value);
    // T0SZ=16 (48 bits), TG0=4K, inner-shareable, WB cacheable; TTBR1 disabled.
    const tcr: u64 = 16 | (0b11 << 12) | (0b01 << 10) | (0b01 << 8) |
        (@as(u64, 0b10) << 32) | (@as(u64, 1) << 23);
    regs.msr("tcr_el1", tcr);
    asActivate(kernel_space);
    regs.isb();
    const sctlr = regs.mrs("sctlr_el1") | 1 | (1 << 2) | (1 << 12); // M | C | I
    regs.msr("sctlr_el1", sctlr);
    regs.isb();
}
