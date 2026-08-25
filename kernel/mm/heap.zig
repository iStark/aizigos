//! The kernel heap.
//!
//! The kernel itself still allocates nothing dynamically — every table it owns
//! is static, and that is deliberate. This exists for the code that cannot
//! work any other way: C libraries, which assume malloc, and the font and
//! parsing work that follows them.
//!
//! Small requests are carved out of pages by size class and never merged back
//! into anything larger; large ones take whole runs of pages. That is enough
//! for a workload of parsers and rasterisers, and it stays honest about what
//! it is: a simple allocator, not a general purpose one.

const std = @import("std");
const pmm = @import("pmm.zig");

pub const Error = error{ OutOfMemory, BadPointer };

/// Sizes a small allocation is rounded up to. Anything larger becomes a run of
/// pages of its own.
const size_classes = [_]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048 };

const magic_small: u32 = 0x5A16_0001;
const magic_large: u32 = 0xA15E_0002;

/// Every allocation carries this in front of it, so free() knows what it is
/// looking at without a table on the side.
const Header = extern struct {
    magic: u32,
    /// Index into `size_classes`, or the page count for a large block.
    detail: u32,
};

const header_len = @sizeOf(Header);

const FreeNode = extern struct {
    next: ?*FreeNode,
};

pub const Stats = struct {
    pages_held: usize,
    bytes_live: usize,
    allocations: u64,
    frees: u64,
};

pub const Heap = struct {
    frames: *pmm.Pmm,
    page_size: usize,
    free_lists: [size_classes.len]?*FreeNode = @splat(null),
    pages_held: usize = 0,
    bytes_live: usize = 0,
    allocations: u64 = 0,
    frees: u64 = 0,

    pub fn init(frames: *pmm.Pmm) Heap {
        return .{ .frames = frames, .page_size = frames.page_size };
    }

    pub fn stats(self: *const Heap) Stats {
        return .{
            .pages_held = self.pages_held,
            .bytes_live = self.bytes_live,
            .allocations = self.allocations,
            .frees = self.frees,
        };
    }

    fn classFor(size: usize) ?usize {
        for (size_classes, 0..) |class, index| {
            if (size <= class) return index;
        }
        return null;
    }

    /// Cut a fresh page into blocks of one size class and put them on its list.
    fn refill(self: *Heap, class: usize) Error!void {
        const page = self.frames.alloc() catch return Error.OutOfMemory;
        self.pages_held += 1;

        const block = header_len + size_classes[class];
        const count = self.page_size / block;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const node: *FreeNode = @ptrFromInt(page + index * block);
            node.next = self.free_lists[class];
            self.free_lists[class] = node;
        }
    }

    pub fn alloc(self: *Heap, size: usize) Error![*]u8 {
        if (size == 0) return Error.OutOfMemory;

        if (classFor(size)) |class| {
            if (self.free_lists[class] == null) try self.refill(class);
            const node = self.free_lists[class] orelse return Error.OutOfMemory;
            self.free_lists[class] = node.next;

            const header: *Header = @ptrCast(@alignCast(node));
            header.* = .{ .magic = magic_small, .detail = @intCast(class) };
            self.allocations += 1;
            self.bytes_live += size_classes[class];
            return @ptrFromInt(@intFromPtr(node) + header_len);
        }

        const total = header_len + size;
        const pages = (total + self.page_size - 1) / self.page_size;
        const base = self.frames.allocContiguous(pages) catch return Error.OutOfMemory;
        self.pages_held += pages;

        const header: *Header = @ptrFromInt(base);
        header.* = .{ .magic = magic_large, .detail = @intCast(pages) };
        self.allocations += 1;
        self.bytes_live += pages * self.page_size;
        return @ptrFromInt(base + header_len);
    }

    pub fn free(self: *Heap, pointer: [*]u8) void {
        const header: *Header = @ptrFromInt(@intFromPtr(pointer) - header_len);
        switch (header.magic) {
            magic_small => {
                const class = header.detail;
                const node: *FreeNode = @ptrCast(@alignCast(header));
                node.next = self.free_lists[class];
                self.free_lists[class] = node;
                self.bytes_live -= size_classes[class];
                self.frees += 1;
            },
            magic_large => {
                const pages = header.detail;
                self.bytes_live -= pages * self.page_size;
                self.pages_held -= pages;
                self.frees += 1;
                self.frames.freeContiguous(@intFromPtr(header), pages) catch {};
            },
            // Freeing something that was never allocated here is a bug in the
            // caller; the kernel refuses rather than corrupting its lists.
            else => {},
        }
    }

    /// How much room the caller actually got, which realloc needs to know.
    pub fn usableSize(self: *const Heap, pointer: [*]u8) usize {
        const header: *const Header = @ptrFromInt(@intFromPtr(pointer) - header_len);
        return switch (header.magic) {
            magic_small => size_classes[header.detail],
            magic_large => header.detail * self.page_size - header_len,
            else => 0,
        };
    }

    pub fn realloc(self: *Heap, pointer: ?[*]u8, size: usize) Error![*]u8 {
        const old = pointer orelse return self.alloc(size);
        const capacity = self.usableSize(old);
        if (capacity == 0) return Error.BadPointer;
        if (size <= capacity) return old;

        const fresh = try self.alloc(size);
        @memcpy(fresh[0..capacity], old[0..capacity]);
        self.free(old);
        return fresh;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const types = @import("../hal/types.zig");

/// The heap writes through the addresses the frame allocator hands out, so a
/// test has to back those addresses with memory that really exists.
const test_pages = 64;
var arena: [test_pages * 4096]u8 align(4096) = undefined;
var arena_bitmap: [test_pages / 8 + 1]u8 = undefined;

const Fixture = struct {
    frames: pmm.Pmm,
    heap: Heap,
};

fn fixture() !Fixture {
    const base = @intFromPtr(&arena);
    const regions = [_]types.MemRegion{
        .{ .base = base, .len = arena.len, .kind = .usable },
    };
    var frames = try pmm.Pmm.init(&arena_bitmap, 4096, &regions);
    return .{ .frames = frames, .heap = Heap.init(&frames) };
}

test "heap: small allocations come back distinct and writable" {
    var f = try fixture();
    f.heap.frames = &f.frames;

    const a = try f.heap.alloc(24);
    const b = try f.heap.alloc(24);
    try testing.expect(a != b);

    @memset(a[0..24], 0xAB);
    @memset(b[0..24], 0xCD);
    try testing.expectEqual(@as(u8, 0xAB), a[0]);
    try testing.expectEqual(@as(u8, 0xCD), b[23]);
    try testing.expectEqual(@as(u64, 2), f.heap.stats().allocations);
}

test "heap: freed blocks are handed out again" {
    var f = try fixture();
    f.heap.frames = &f.frames;

    const first = try f.heap.alloc(100);
    f.heap.free(first);
    const second = try f.heap.alloc(100);
    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(u64, 1), f.heap.stats().frees);
}

test "heap: one page serves many small allocations" {
    var f = try fixture();
    f.heap.frames = &f.frames;
    const before = f.frames.stats().free_frames;

    var kept: [8][*]u8 = undefined;
    for (&kept) |*slot| slot.* = try f.heap.alloc(16);
    // Sixteen-byte blocks with a header fit many to a page, so eight of them
    // must not have cost eight pages.
    try testing.expectEqual(before - 1, f.frames.stats().free_frames);
}

test "heap: a large request takes whole pages and gives them back" {
    var f = try fixture();
    f.heap.frames = &f.frames;
    const before = f.frames.stats().free_frames;

    const big = try f.heap.alloc(9000);
    try testing.expectEqual(@as(usize, 3), f.heap.stats().pages_held);
    @memset(big[0..9000], 7);
    try testing.expectEqual(@as(u8, 7), big[8999]);

    f.heap.free(big);
    try testing.expectEqual(before, f.frames.stats().free_frames);
    try testing.expectEqual(@as(usize, 0), f.heap.stats().pages_held);
}

test "heap: realloc keeps the contents" {
    var f = try fixture();
    f.heap.frames = &f.frames;

    const small = try f.heap.alloc(20);
    @memcpy(small[0..5], "hello");
    const bigger = try f.heap.realloc(small, 300);
    try testing.expectEqualStrings("hello", bigger[0..5]);

    // Growing inside the same size class does not move the block.
    const same = try f.heap.realloc(bigger, 310);
    try testing.expectEqual(bigger, same);
}

test "heap: running out of memory is an error, not a crash" {
    var f = try fixture();
    f.heap.frames = &f.frames;
    var taken: usize = 0;
    while (taken < 1000) : (taken += 1) {
        _ = f.heap.alloc(4096) catch break;
    }
    try testing.expectError(Error.OutOfMemory, f.heap.alloc(4096));
}
