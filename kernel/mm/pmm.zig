//! Аллокатор физических страниц: битовая карта поверх карты памяти от HAL.
//! FR-1.2 (нижний слой: выдача физических кадров под адресные пространства).

const std = @import("std");
const types = @import("../hal/types.zig");

pub const Error = error{
    OutOfMemory,
    NotAllocated,
    OutOfRange,
    BitmapTooSmall,
};

pub const Stats = struct {
    total_frames: usize,
    free_frames: usize,
    used_frames: usize,
    page_size: usize,
};

pub const Pmm = struct {
    bitmap: []u8,
    base: types.PhysAddr = 0,
    frames: usize = 0,
    free_frames: usize = 0,
    page_size: usize = 4096,
    hint: usize = 0,

    /// storage должен вмещать по одному биту на кадр в диапазоне карты памяти.
    /// Изначально занято всё; свободными помечаются только usable-области.
    pub fn init(storage: []u8, page_size: usize, regions: []const types.MemRegion) Error!Pmm {
        var lo: types.PhysAddr = std.math.maxInt(u64);
        var hi: types.PhysAddr = 0;
        for (regions) |r| {
            if (r.kind == .device) continue;
            lo = @min(lo, r.base);
            hi = @max(hi, r.end());
        }
        if (hi <= lo) return Error.OutOfRange;

        const base = std.mem.alignBackward(u64, lo, page_size);
        const frames: usize = @intCast((std.mem.alignForward(u64, hi, page_size) - base) / page_size);
        if (storage.len * 8 < frames) return Error.BitmapTooSmall;

        var self = Pmm{
            .bitmap = storage[0..((frames + 7) / 8)],
            .base = base,
            .frames = frames,
            .free_frames = 0,
            .page_size = page_size,
        };
        @memset(self.bitmap, 0xFF);

        for (regions) |r| {
            if (r.kind != .usable) continue;
            const start = std.mem.alignForward(u64, r.base, page_size);
            const end = std.mem.alignBackward(u64, r.end(), page_size);
            var addr = start;
            while (addr + page_size <= end) : (addr += page_size) {
                const idx = self.frameIndex(addr) orelse continue;
                if (self.testBit(idx)) {
                    self.clearBit(idx);
                    self.free_frames += 1;
                }
            }
        }
        return self;
    }

    fn frameIndex(self: *const Pmm, pa: types.PhysAddr) ?usize {
        if (pa < self.base) return null;
        const idx: usize = @intCast((pa - self.base) / self.page_size);
        return if (idx < self.frames) idx else null;
    }

    fn frameAddr(self: *const Pmm, idx: usize) types.PhysAddr {
        return self.base + @as(u64, idx) * self.page_size;
    }

    fn testBit(self: *const Pmm, idx: usize) bool {
        return self.bitmap[idx / 8] & (@as(u8, 1) << @intCast(idx % 8)) != 0;
    }
    fn setBit(self: *Pmm, idx: usize) void {
        self.bitmap[idx / 8] |= @as(u8, 1) << @intCast(idx % 8);
    }
    fn clearBit(self: *Pmm, idx: usize) void {
        self.bitmap[idx / 8] &= ~(@as(u8, 1) << @intCast(idx % 8));
    }

    pub fn alloc(self: *Pmm) Error!types.PhysAddr {
        var scanned: usize = 0;
        var idx = self.hint;
        while (scanned < self.frames) : (scanned += 1) {
            if (idx >= self.frames) idx = 0;
            if (!self.testBit(idx)) {
                self.setBit(idx);
                self.free_frames -= 1;
                self.hint = idx + 1;
                return self.frameAddr(idx);
            }
            idx += 1;
        }
        return Error.OutOfMemory;
    }

    pub fn allocContiguous(self: *Pmm, count: usize) Error!types.PhysAddr {
        if (count == 0) return Error.OutOfRange;
        var start: usize = 0;
        while (start + count <= self.frames) {
            var i: usize = 0;
            while (i < count and !self.testBit(start + i)) : (i += 1) {}
            if (i == count) {
                var k: usize = 0;
                while (k < count) : (k += 1) self.setBit(start + k);
                self.free_frames -= count;
                return self.frameAddr(start);
            }
            start += i + 1;
        }
        return Error.OutOfMemory;
    }

    pub fn free(self: *Pmm, pa: types.PhysAddr) Error!void {
        const idx = self.frameIndex(pa) orelse return Error.OutOfRange;
        if (!self.testBit(idx)) return Error.NotAllocated;
        self.clearBit(idx);
        self.free_frames += 1;
        if (idx < self.hint) self.hint = idx;
    }

    pub fn freeContiguous(self: *Pmm, pa: types.PhysAddr, count: usize) Error!void {
        var i: usize = 0;
        while (i < count) : (i += 1) try self.free(pa + @as(u64, i) * self.page_size);
    }

    pub fn stats(self: *const Pmm) Stats {
        return .{
            .total_frames = self.frames,
            .free_frames = self.free_frames,
            .used_frames = self.frames - self.free_frames,
            .page_size = self.page_size,
        };
    }
};

// --- тесты ---------------------------------------------------------------

const testing = std.testing;

const test_regions = [_]types.MemRegion{
    .{ .base = 0x0000, .len = 0x4000, .kind = .reserved }, // 4 кадра занято
    .{ .base = 0x4000, .len = 0x8000, .kind = .usable }, // 8 кадров свободно
};

test "pmm: usable-области свободны, reserved заняты" {
    var storage: [64]u8 = undefined;
    var pmm = try Pmm.init(&storage, 4096, &test_regions);
    try testing.expectEqual(@as(usize, 12), pmm.stats().total_frames);
    try testing.expectEqual(@as(usize, 8), pmm.stats().free_frames);
}

test "pmm: alloc выдаёт только кадры из usable" {
    var storage: [64]u8 = undefined;
    var pmm = try Pmm.init(&storage, 4096, &test_regions);
    var seen: [8]u64 = undefined;
    for (&seen) |*slot| {
        const pa = try pmm.alloc();
        try testing.expect(pa >= 0x4000 and pa < 0xC000);
        slot.* = pa;
    }
    try testing.expectError(Error.OutOfMemory, pmm.alloc());

    for (seen, 0..) |a, i| {
        for (seen[i + 1 ..]) |b| try testing.expect(a != b);
    }

    try pmm.free(seen[3]);
    try testing.expectEqual(@as(usize, 1), pmm.stats().free_frames);
    try testing.expectEqual(seen[3], try pmm.alloc());
}

test "pmm: двойное освобождение и выход за диапазон дают ошибку" {
    var storage: [64]u8 = undefined;
    var pmm = try Pmm.init(&storage, 4096, &test_regions);
    const pa = try pmm.alloc();
    try pmm.free(pa);
    try testing.expectError(Error.NotAllocated, pmm.free(pa));
    try testing.expectError(Error.OutOfRange, pmm.free(0xFFFF_0000));
}

test "pmm: непрерывное выделение" {
    var storage: [64]u8 = undefined;
    var pmm = try Pmm.init(&storage, 4096, &test_regions);
    const run = try pmm.allocContiguous(4);
    try testing.expectEqual(@as(u64, 0x4000), run);
    try testing.expectEqual(@as(usize, 4), pmm.stats().free_frames);
    try pmm.freeContiguous(run, 4);
    try testing.expectEqual(@as(usize, 8), pmm.stats().free_frames);
}

test "pmm: слишком маленькая битовая карта отвергается" {
    var tiny: [1]u8 = undefined;
    try testing.expectError(Error.BitmapTooSmall, Pmm.init(&tiny, 4096, &test_regions));
}
