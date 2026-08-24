//! Process address space: region bookkeeping plus mapping through the HAL.
//! FR-1.2: every process gets its own space and the kernel validates bounds.

const std = @import("std");
const hal = @import("../hal/hal.zig");
const pmm_mod = @import("pmm.zig");

pub const Error = error{
    TooManyRegions,
    Overlaps,
    NotFound,
    Misaligned,
    OutOfMemory,
    MapFailed,
};

pub const max_regions = 16;

pub const Region = struct {
    va: u64 = 0,
    pages: usize = 0,
    flags: hal.MapFlags = .{},
    /// Frames are owned by this space and released on unmap.
    owned: bool = false,
    live: bool = false,

    pub fn end(self: Region) u64 {
        return self.va + self.pages * hal.page_size;
    }
};

pub const AddressSpace = struct {
    arch: hal.AddressSpace = .{},
    regions: [max_regions]Region = @splat(.{}),
    mapped_pages: usize = 0,

    pub fn init(self: *AddressSpace) Error!void {
        hal.asInit(&self.arch) catch return Error.MapFailed;
        self.regions = @splat(.{});
        self.mapped_pages = 0;
    }

    pub fn deinit(self: *AddressSpace, pmm: *pmm_mod.Pmm) void {
        for (&self.regions) |*r| {
            if (r.live and r.owned) {
                var i: usize = 0;
                while (i < r.pages) : (i += 1) {
                    const va = r.va + i * hal.page_size;
                    if (hal.asTranslate(&self.arch, va)) |pa| {
                        pmm.free(pa) catch {};
                    }
                }
            }
            r.* = .{};
        }
        hal.asDeinit(&self.arch);
        self.mapped_pages = 0;
    }

    fn overlaps(self: *const AddressSpace, va: u64, pages: usize) bool {
        const end = va + pages * hal.page_size;
        for (self.regions) |r| {
            if (!r.live) continue;
            if (va < r.end() and r.va < end) return true;
        }
        return false;
    }

    fn addRegion(self: *AddressSpace, r: Region) Error!*Region {
        for (&self.regions) |*slot| {
            if (!slot.live) {
                slot.* = r;
                slot.live = true;
                return slot;
            }
        }
        return Error.TooManyRegions;
    }

    /// Map anonymous memory: frames come from the PMM.
    pub fn mapAnonymous(self: *AddressSpace, pmm: *pmm_mod.Pmm, va: u64, pages: usize, flags: hal.MapFlags) Error!void {
        if (va % hal.page_size != 0) return Error.Misaligned;
        if (self.overlaps(va, pages)) return Error.Overlaps;

        var mapped: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < mapped) : (i += 1) {
                const addr = va + i * hal.page_size;
                if (hal.asTranslate(&self.arch, addr)) |pa| pmm.free(pa) catch {};
                hal.asUnmap(&self.arch, addr, 1) catch {};
            }
        }
        while (mapped < pages) : (mapped += 1) {
            const pa = pmm.alloc() catch return Error.OutOfMemory;
            hal.asMap(&self.arch, va + mapped * hal.page_size, pa, flags) catch {
                pmm.free(pa) catch {};
                return Error.MapFailed;
            };
        }
        _ = try self.addRegion(.{ .va = va, .pages = pages, .flags = flags, .owned = true });
        self.mapped_pages += pages;
    }

    /// Map a specific physical range (MMIO, shared memory).
    pub fn mapPhysical(self: *AddressSpace, va: u64, pa: u64, pages: usize, flags: hal.MapFlags) Error!void {
        if (va % hal.page_size != 0 or pa % hal.page_size != 0) return Error.Misaligned;
        if (self.overlaps(va, pages)) return Error.Overlaps;
        var i: usize = 0;
        errdefer {
            var k: usize = 0;
            while (k < i) : (k += 1) hal.asUnmap(&self.arch, va + k * hal.page_size, 1) catch {};
        }
        while (i < pages) : (i += 1) {
            hal.asMap(&self.arch, va + i * hal.page_size, pa + i * hal.page_size, flags) catch return Error.MapFailed;
        }
        _ = try self.addRegion(.{ .va = va, .pages = pages, .flags = flags, .owned = false });
        self.mapped_pages += pages;
    }

    pub fn unmap(self: *AddressSpace, pmm: *pmm_mod.Pmm, va: u64) Error!void {
        for (&self.regions) |*r| {
            if (!r.live or r.va != va) continue;
            var i: usize = 0;
            while (i < r.pages) : (i += 1) {
                const addr = r.va + i * hal.page_size;
                if (r.owned) {
                    if (hal.asTranslate(&self.arch, addr)) |pa| pmm.free(pa) catch {};
                }
                hal.asUnmap(&self.arch, addr, 1) catch {};
            }
            self.mapped_pages -= r.pages;
            r.* = .{};
            return;
        }
        return Error.NotFound;
    }

    pub fn translate(self: *AddressSpace, va: u64) ?u64 {
        return hal.asTranslate(&self.arch, va);
    }

    /// Check that a user buffer lies entirely inside one mapped region with
    /// the required rights. Used on every system call.
    pub fn checkAccess(self: *const AddressSpace, va: u64, len: usize, need_write: bool) bool {
        if (len == 0) return true;
        const end = va + len;
        for (self.regions) |r| {
            if (!r.live) continue;
            if (va >= r.va and end <= r.end()) {
                if (need_write and !r.flags.write) return false;
                return r.flags.user;
            }
        }
        return false;
    }

    pub fn activate(self: *AddressSpace) void {
        hal.asActivate(&self.arch);
    }
};

// --- tests ---------------------------------------------------------------

const testing = std.testing;
const types = @import("../hal/types.zig");

const test_regions = [_]types.MemRegion{
    .{ .base = 0x0000, .len = 0x1000, .kind = .reserved },
    .{ .base = 0x1000, .len = 0x20000, .kind = .usable },
};

fn testPmm(storage: []u8) !pmm_mod.Pmm {
    return pmm_mod.Pmm.init(storage, hal.page_size, &test_regions);
}

test "vmm: an anonymous mapping translates and is released" {
    var storage: [64]u8 = undefined;
    var pmm = try testPmm(&storage);
    const free_before = pmm.stats().free_frames;

    var space: AddressSpace = .{};
    try space.init();
    defer space.deinit(&pmm);

    try space.mapAnonymous(&pmm, 0x4000_0000, 4, .{ .read = true, .write = true, .user = true });
    try testing.expectEqual(free_before - 4, pmm.stats().free_frames);
    try testing.expect(space.translate(0x4000_0000) != null);
    try testing.expect(space.translate(0x4000_3000) != null);
    try testing.expect(space.translate(0x4000_4000) == null);

    try space.unmap(&pmm, 0x4000_0000);
    try testing.expectEqual(free_before, pmm.stats().free_frames);
    try testing.expect(space.translate(0x4000_0000) == null);
}

test "vmm: overlapping regions are rejected" {
    var storage: [64]u8 = undefined;
    var pmm = try testPmm(&storage);
    var space: AddressSpace = .{};
    try space.init();
    defer space.deinit(&pmm);

    try space.mapAnonymous(&pmm, 0x1000_0000, 2, .{ .write = true, .user = true });
    try testing.expectError(Error.Overlaps, space.mapAnonymous(&pmm, 0x1000_1000, 2, .{ .user = true }));
    try testing.expectError(Error.Misaligned, space.mapAnonymous(&pmm, 0x1000_0800, 1, .{ .user = true }));
}

test "vmm: two spaces are isolated from each other" {
    var storage: [64]u8 = undefined;
    var pmm = try testPmm(&storage);

    var a: AddressSpace = .{};
    var b: AddressSpace = .{};
    try a.init();
    try b.init();
    defer a.deinit(&pmm);
    defer b.deinit(&pmm);

    const va: u64 = 0x2000_0000;
    try a.mapAnonymous(&pmm, va, 1, .{ .write = true, .user = true });
    try b.mapAnonymous(&pmm, va, 1, .{ .write = true, .user = true });

    // The same virtual address leads to different physical frames.
    try testing.expect(a.translate(va).? != b.translate(va).?);
}

test "vmm: checkAccess validates bounds and rights" {
    var storage: [64]u8 = undefined;
    var pmm = try testPmm(&storage);
    var space: AddressSpace = .{};
    try space.init();
    defer space.deinit(&pmm);

    try space.mapAnonymous(&pmm, 0x3000_0000, 2, .{ .read = true, .user = true });
    try testing.expect(space.checkAccess(0x3000_0000, 100, false));
    try testing.expect(!space.checkAccess(0x3000_0000, 100, true)); // no write right
    try testing.expect(!space.checkAccess(0x3000_1FF0, 0x20, false)); // crosses the end
    try testing.expect(!space.checkAccess(0x9999_0000, 8, false)); // not mapped
}
