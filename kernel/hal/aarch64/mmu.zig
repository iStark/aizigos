//! Страничные таблицы AArch64 (4 КБ гранула, 48-битные VA, 4 уровня).
//! FR-1.2: изоляция адресных пространств процессов.

const types = @import("../types.zig");
const regs = @import("regs.zig");

pub const page_size: usize = 4096;
const entries_per_table = 512;

/// Пул таблиц. Ядро не использует динамическую память, поэтому таблицы
/// раздаются из статического пула; исчерпание — честная ошибка OutOfTables.
const table_pool_size = 32;

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

// --- формат дескрипторов -------------------------------------------------

const desc_valid: u64 = 1 << 0;
const desc_table: u64 = 1 << 1; // на уровнях 0..2: указатель на таблицу
const desc_page: u64 = 1 << 1; // на уровне 3: страница
const attr_af: u64 = 1 << 10; // Access Flag
const attr_sh_inner: u64 = 0b11 << 8;
const attr_ap_rw_el1: u64 = 0b00 << 6;
const attr_ap_rw_all: u64 = 0b01 << 6;
const attr_ap_ro_el1: u64 = 0b10 << 6;
const attr_ap_ro_all: u64 = 0b11 << 6;
const attr_pxn: u64 = 1 << 53;
const attr_uxn: u64 = 1 << 54;
const addr_mask: u64 = 0x0000_FFFF_FFFF_F000;

/// MAIR: индекс 0 — Normal WB, индекс 1 — Device-nGnRnE.
const mair_value: u64 = 0xFF | (0x00 << 8);
const attr_idx_normal: u64 = 0 << 2;
const attr_idx_device: u64 = 1 << 2;

fn leafAttrs(flags: types.MapFlags) u64 {
    var attrs: u64 = desc_valid | desc_page | attr_af | attr_sh_inner;
    attrs |= if (flags.device) attr_idx_device else attr_idx_normal;
    // AP-биты: комбинация write/user.
    attrs |= if (flags.user)
        (if (flags.write) attr_ap_rw_all else attr_ap_ro_all)
    else
        (if (flags.write) attr_ap_rw_el1 else attr_ap_ro_el1);
    if (!flags.exec) {
        attrs |= attr_pxn | attr_uxn;
    } else if (flags.user) {
        attrs |= attr_pxn; // пользовательский код неисполняем в EL1
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
};

var next_asid: u16 = 1;

pub fn asInit(space: *AddressSpace) types.MmuError!void {
    const root = allocTable() orelse return error.OutOfTables;
    space.* = .{ .root = root, .asid = next_asid };
    next_asid +%= 1;
    if (next_asid == 0) next_asid = 1;
}

pub fn asDeinit(space: *AddressSpace) void {
    if (space.root) |root| freeTableTree(root, 0);
    space.* = .{};
}

fn freeTableTree(table: *Table, level: u2) void {
    if (level < 3) {
        for (table.e) |entry| {
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

fn invalidate(va: u64, asid: u16) void {
    const operand: u64 = (@as(u64, asid) << 48) | (va >> 12);
    asm volatile ("tlbi vae1is, %[op]"
        :
        : [op] "r" (operand),
        : .{ .memory = true });
    regs.dsb();
    regs.isb();
}

/// Переключение TTBR0 на данное пространство. MMU при этом уже должен быть включён.
pub fn asActivate(space: *AddressSpace) void {
    const root = space.root orelse return;
    const ttbr: u64 = (@as(u64, space.asid) << 48) | (@intFromPtr(root) & addr_mask);
    regs.msr("ttbr0_el1", ttbr);
    regs.isb();
}

/// Включение MMU. Вызывается только когда для ядра построено
/// корректное identity-отображение (см. docs/ARCHITECTURE.md, этап 2).
pub fn enable(kernel_space: *AddressSpace) void {
    regs.msr("mair_el1", mair_value);
    // T0SZ=16 (48 бит), TG0=4K, inner-shareable, WB cacheable; TTBR1 отключён.
    const tcr: u64 = 16 | (0b11 << 12) | (0b01 << 10) | (0b01 << 8) |
        (@as(u64, 0b10) << 32) | (@as(u64, 1) << 23);
    regs.msr("tcr_el1", tcr);
    asActivate(kernel_space);
    regs.isb();
    const sctlr = regs.mrs("sctlr_el1") | 1 | (1 << 2) | (1 << 12); // M | C | I
    regs.msr("sctlr_el1", sctlr);
    regs.isb();
}
