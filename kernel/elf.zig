//! ELF64 loader for static executables.
//!
//! No PT_DYNAMIC, no interpreter, no relocations. The file is read in 4 KiB
//! chunks into a kernel scratch, copied through identity-mapped physical
//! frames, and mapped into the process address space.

const std = @import("std");
const builtin = @import("builtin");
const hal = @import("hal/hal.zig");
const vmm = @import("mm/vmm.zig");
const pmm = @import("mm/pmm.zig");
const layout = @import("mm/layout.zig");

pub const Error = error{
    Truncated,
    NotElf,
    BadClass,
    BadEndian,
    BadType,
    BadMachine,
    Dynamic,
    Interpreter,
    BadPhdr,
    Overlap,
    TooLarge,
    OutOfMemory,
    MapFailed,
};

const ident_mag0 = 0x7F;
const ident_class_64: u8 = 2;
const ident_data_lsb: u8 = 1;
const et_exec: u16 = 2;
const et_dyn: u16 = 3;
const em_x86_64: u16 = 62;
const em_aarch64: u16 = 183;
const pt_load: u32 = 1;
const pt_dynamic: u32 = 2;
const pt_interp: u32 = 3;
const pf_x: u32 = 1;
const pf_w: u32 = 2;
const pf_r: u32 = 4;

pub const max_size: u32 = 4 << 20;
pub const max_phdrs: usize = 16;

const Ehdr = extern struct {
    ident: [16]u8,
    type: u16,
    machine: u16,
    version: u32,
    entry: u64,
    phoff: u64,
    shoff: u64,
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,
};

const Phdr = extern struct {
    type: u32,
    flags: u32,
    offset: u64,
    vaddr: u64,
    paddr: u64,
    filesz: u64,
    memsz: u64,
    align_: u64,
};

pub const Image = struct {
    entry: u64,
    phoff: u64,
    phentsize: u16,
    phnum: u16,
};

pub fn parseHeader(bytes: []const u8) Error!Image {
    if (bytes.len < @sizeOf(Ehdr)) return Error.Truncated;
    var eh: Ehdr = undefined;
    @memcpy(std.mem.asBytes(&eh), bytes[0..@sizeOf(Ehdr)]);
    if (eh.ident[0] != ident_mag0 or eh.ident[1] != 'E' or eh.ident[2] != 'L' or eh.ident[3] != 'F') {
        return Error.NotElf;
    }
    if (eh.ident[4] != ident_class_64) return Error.BadClass;
    if (eh.ident[5] != ident_data_lsb) return Error.BadEndian;
    if (eh.type != et_exec and eh.type != et_dyn) return Error.BadType;
    const want_machine: u16 = switch (builtin.cpu.arch) {
        .x86_64 => em_x86_64,
        .aarch64 => em_aarch64,
        else => return Error.BadMachine,
    };
    // Host tests parse an x86_64 image regardless of the host arch.
    if (builtin.os.tag == .freestanding or builtin.os.tag == .uefi) {
        if (eh.machine != want_machine) return Error.BadMachine;
    } else if (eh.machine != em_x86_64 and eh.machine != em_aarch64) {
        return Error.BadMachine;
    }
    if (eh.phentsize != @sizeOf(Phdr) or eh.phnum == 0 or eh.phnum > max_phdrs) return Error.BadPhdr;
    if (eh.phoff > bytes.len) return Error.Truncated;
    return .{
        .entry = eh.entry,
        .phoff = eh.phoff,
        .phentsize = eh.phentsize,
        .phnum = eh.phnum,
    };
}

pub fn parsePhdrs(bytes: []const u8, image: Image, out: []Phdr) Error!usize {
    const start: usize = @intCast(image.phoff);
    const need = @as(usize, image.phnum) * @as(usize, image.phentsize);
    if (start > bytes.len or bytes.len - start < need) return Error.Truncated;
    var n: usize = 0;
    var i: usize = 0;
    while (i < image.phnum) : (i += 1) {
        const off = start + i * image.phentsize;
        var ph: Phdr = undefined;
        @memcpy(std.mem.asBytes(&ph), bytes[off..][0..@sizeOf(Phdr)]);
        if (ph.type == pt_dynamic) return Error.Dynamic;
        if (ph.type == pt_interp) return Error.Interpreter;
        if (ph.type != pt_load) continue;
        if (ph.memsz < ph.filesz) return Error.BadPhdr;
        if (ph.vaddr < layout.user_base) return Error.BadPhdr;
        if (n == out.len) return Error.TooLarge;
        out[n] = ph;
        n += 1;
    }
    if (n == 0) return Error.BadPhdr;
    return n;
}

pub fn load(space: *vmm.AddressSpace, frames: *pmm.Pmm, bytes: []const u8) Error!u64 {
    if (bytes.len < @sizeOf(Ehdr) or bytes.len > max_size) return Error.TooLarge;
    const image = try parseHeader(bytes);
    var phdrs: [max_phdrs]Phdr = undefined;
    const n = try parsePhdrs(bytes, image, &phdrs);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try mapSegment(space, frames, bytes, phdrs[i]);
    }
    return image.entry;
}

fn mapSegment(space: *vmm.AddressSpace, frames: *pmm.Pmm, bytes: []const u8, ph: Phdr) Error!void {
    const page = hal.page_size;
    const va_start = ph.vaddr & ~@as(u64, page - 1);
    const va_end = std.mem.alignForward(u64, ph.vaddr + ph.memsz, page);
    const pages: usize = @intCast((va_end - va_start) / page);
    if (pages == 0) return;

    var flags = hal.MapFlags{ .read = true, .user = true };
    flags.write = ph.flags & pf_w != 0;
    flags.exec = ph.flags & pf_x != 0 and !flags.write;

    space.mapAnonymous(frames, va_start, pages, flags) catch |e| switch (e) {
        error.Overlaps => {
            var page_i: usize = 0;
            while (page_i < pages) : (page_i += 1) {
                const va = va_start + page_i * page;
                if (space.translate(va) != null) continue;
                space.mapAnonymous(frames, va, 1, flags) catch |inner| switch (inner) {
                    error.Overlaps => continue,
                    error.OutOfMemory => return Error.OutOfMemory,
                    else => return Error.MapFailed,
                };
            }
        },
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.MapFailed,
    };

    if (ph.filesz != 0) {
        const file_off: usize = @intCast(ph.offset);
        const file_end = file_off + @as(usize, @intCast(ph.filesz));
        if (file_end > bytes.len) return Error.Truncated;
        writeUser(space, ph.vaddr, bytes[file_off..file_end]) catch return Error.MapFailed;
    }
    if (ph.memsz > ph.filesz) {
        zeroUser(space, ph.vaddr + ph.filesz, ph.memsz - ph.filesz) catch return Error.MapFailed;
    }
}

fn zeroUser(space: *vmm.AddressSpace, va: u64, len: u64) Error!void {
    var off: u64 = 0;
    while (off < len) {
        const page_off = (va + off) % hal.page_size;
        const chunk: usize = @intCast(@min(len - off, @as(u64, hal.page_size - page_off)));
        const pa = space.translate(va + off) orelse return Error.MapFailed;
        const dst: [*]u8 = @ptrFromInt(pa);
        @memset(dst[0..chunk], 0);
        off += chunk;
    }
}

fn writeUser(space: *vmm.AddressSpace, va: u64, data: []const u8) Error!void {
    var off: usize = 0;
    while (off < data.len) {
        const page_off = (va + off) % hal.page_size;
        const chunk = @min(data.len - off, hal.page_size - page_off);
        const pa = space.translate(va + off) orelse return Error.MapFailed;
        const dst: [*]u8 = @ptrFromInt(pa);
        @memcpy(dst[0..chunk], data[off..][0..chunk]);
        off += chunk;
    }
}

const testing = std.testing;

fn makeMinimalElf() [128]u8 {
    var b: [128]u8 = @splat(0);
    b[0] = 0x7F;
    b[1] = 'E';
    b[2] = 'L';
    b[3] = 'F';
    b[4] = 2;
    b[5] = 1;
    b[6] = 1;
    std.mem.writeInt(u16, b[16..18], et_exec, .little);
    std.mem.writeInt(u16, b[18..20], em_x86_64, .little);
    std.mem.writeInt(u32, b[20..24], 1, .little);
    std.mem.writeInt(u64, b[24..32], layout.code_va, .little);
    std.mem.writeInt(u64, b[32..40], 64, .little); // phoff
    std.mem.writeInt(u16, b[52..54], 64, .little); // ehsize
    std.mem.writeInt(u16, b[54..56], 56, .little); // phentsize
    std.mem.writeInt(u16, b[56..58], 1, .little); // phnum
    std.mem.writeInt(u32, b[64..68], pt_load, .little);
    std.mem.writeInt(u32, b[68..72], pf_r | pf_x, .little);
    std.mem.writeInt(u64, b[80..88], layout.code_va, .little);
    std.mem.writeInt(u64, b[96..104], 16, .little); // filesz
    std.mem.writeInt(u64, b[104..112], 16, .little); // memsz
    return b;
}

test "elf: a well-formed static header parses" {
    const bytes = makeMinimalElf();
    const image = try parseHeader(&bytes);
    try testing.expectEqual(layout.code_va, image.entry);
    try testing.expectEqual(@as(u16, 1), image.phnum);
    var ph: [4]Phdr = undefined;
    const n = try parsePhdrs(&bytes, image, &ph);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(layout.code_va, ph[0].vaddr);
}

test "elf: PT_DYNAMIC is refused" {
    var bytes = makeMinimalElf();
    std.mem.writeInt(u32, bytes[64..68], pt_dynamic, .little);
    const image = try parseHeader(&bytes);
    var ph: [4]Phdr = undefined;
    try testing.expectError(Error.Dynamic, parsePhdrs(&bytes, image, &ph));
}

test "elf: a truncated header is refused" {
    const bytes = makeMinimalElf();
    try testing.expectError(Error.Truncated, parseHeader(bytes[0..16]));
}
