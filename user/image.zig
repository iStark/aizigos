//! PNG, and the deflate stream inside it.
//!
//! Written here for the same reason the font rasteriser was: the usual answer
//! is someone else's single-header file, and this system has been reading its
//! own formats since the partition table. It is also the smaller half of the
//! job — a PNG is a handful of chunks around a deflate stream, and deflate is
//! two Huffman tables and a sliding window.
//!
//! What it reads: colour types 0, 2, 3, 4 and 6 at eight bits per channel,
//! every filter, and a palette with transparency. What it does not: sixteen
//! bits per channel, and interlacing. Both are rare on the web and both would
//! be answered by the same code twice over, so they wait until something
//! actually arrives that needs them.

const std = @import("std");

extern fn aizigos_alloc(size: usize) callconv(.c) ?[*]u8;

pub const Error = error{
    NotAPng,
    Truncated,
    Unsupported,
    BadStream,
    OutOfMemory,
};

// --- deflate ---------------------------------------------------------------

/// Canonical Huffman decoding, the way the format describes it: counts per
/// length, then symbols in order. Slower than a lookup table and small enough
/// to read.
const Huffman = struct {
    counts: [16]u16 = @splat(0),
    symbols: [288]u16 = @splat(0),

    fn build(self: *Huffman, lengths: []const u8) void {
        self.counts = @splat(0);
        for (lengths) |length| self.counts[length] += 1;
        self.counts[0] = 0;

        var offsets: [16]u16 = @splat(0);
        var length: usize = 1;
        while (length < 16) : (length += 1) {
            offsets[length] = offsets[length - 1] + self.counts[length - 1];
        }
        for (lengths, 0..) |bits, symbol| {
            if (bits == 0) continue;
            self.symbols[offsets[bits]] = @intCast(symbol);
            offsets[bits] += 1;
        }
    }
};

const Bits = struct {
    bytes: []const u8,
    at: usize = 0,
    bit_buffer: u32 = 0,
    bit_count: u5 = 0,

    fn bit(self: *Bits) Error!u32 {
        if (self.bit_count == 0) {
            if (self.at >= self.bytes.len) return Error.Truncated;
            self.bit_buffer = self.bytes[self.at];
            self.at += 1;
            self.bit_count = 8;
        }
        const value = self.bit_buffer & 1;
        self.bit_buffer >>= 1;
        self.bit_count -= 1;
        return value;
    }

    fn bits(self: *Bits, count: u5) Error!u32 {
        var value: u32 = 0;
        var index: u5 = 0;
        while (index < count) : (index += 1) {
            value |= (try self.bit()) << index;
        }
        return value;
    }

    fn decode(self: *Bits, table: *const Huffman) Error!u16 {
        var code: i32 = 0;
        var first: i32 = 0;
        var index: i32 = 0;
        var length: usize = 1;
        while (length < 16) : (length += 1) {
            code |= @intCast(try self.bit());
            const count: i32 = table.counts[length];
            if (code - first < count) return table.symbols[@intCast(index + (code - first))];
            index += count;
            first = (first + count) << 1;
            code <<= 1;
        }
        return Error.BadStream;
    }

    fn alignToByte(self: *Bits) void {
        self.bit_buffer = 0;
        self.bit_count = 0;
    }
};

const length_base = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const length_extra = [_]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const distance_base = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const distance_extra = [_]u5{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

var literal_table: Huffman = .{};
var distance_table: Huffman = .{};

fn fixedTables() void {
    var lengths: [288]u8 = undefined;
    for (0..144) |i| lengths[i] = 8;
    for (144..256) |i| lengths[i] = 9;
    for (256..280) |i| lengths[i] = 7;
    for (280..288) |i| lengths[i] = 8;
    literal_table.build(&lengths);

    var distances: [30]u8 = @splat(5);
    distance_table.build(&distances);
}

/// The lengths of the two tables are themselves Huffman coded, in an order
/// chosen so that the common ones come first. This is the fiddliest corner of
/// the format and there is no way to make it look simple.
fn dynamicTables(stream: *Bits) Error!void {
    const order = [_]usize{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
    const literals = try stream.bits(5) + 257;
    const distances = try stream.bits(5) + 1;
    const code_lengths = try stream.bits(4) + 4;
    if (literals > 288 or distances > 30) return Error.BadStream;

    var lengths: [19]u8 = @splat(0);
    var index: usize = 0;
    while (index < code_lengths) : (index += 1) {
        lengths[order[index]] = @intCast(try stream.bits(3));
    }
    var code_table: Huffman = .{};
    code_table.build(&lengths);

    var all: [318]u8 = @splat(0);
    var filled: usize = 0;
    while (filled < literals + distances) {
        const symbol = try stream.decode(&code_table);
        switch (symbol) {
            0...15 => {
                all[filled] = @intCast(symbol);
                filled += 1;
            },
            16 => {
                if (filled == 0) return Error.BadStream;
                const previous = all[filled - 1];
                var repeat = 3 + try stream.bits(2);
                while (repeat > 0 and filled < all.len) : (repeat -= 1) {
                    all[filled] = previous;
                    filled += 1;
                }
            },
            17 => {
                var repeat = 3 + try stream.bits(3);
                while (repeat > 0 and filled < all.len) : (repeat -= 1) {
                    all[filled] = 0;
                    filled += 1;
                }
            },
            18 => {
                var repeat = 11 + try stream.bits(7);
                while (repeat > 0 and filled < all.len) : (repeat -= 1) {
                    all[filled] = 0;
                    filled += 1;
                }
            },
            else => return Error.BadStream,
        }
    }

    literal_table.build(all[0..literals]);
    distance_table.build(all[literals .. literals + distances]);
}

/// Inflate `source` into `out`, returning how much was written. The window is
/// the output itself, which is what makes this short: a back reference copies
/// from bytes already produced.
pub fn inflate(source: []const u8, out: []u8) Error!usize {
    var stream = Bits{ .bytes = source };
    var written: usize = 0;

    while (true) {
        const final = try stream.bit();
        const kind = try stream.bits(2);

        switch (kind) {
            0 => {
                stream.alignToByte();
                if (stream.at + 4 > source.len) return Error.Truncated;
                const length = @as(usize, source[stream.at]) | (@as(usize, source[stream.at + 1]) << 8);
                stream.at += 4; // length and its complement
                if (stream.at + length > source.len) return Error.Truncated;
                if (written + length > out.len) return Error.OutOfMemory;
                @memcpy(out[written..][0..length], source[stream.at..][0..length]);
                stream.at += length;
                written += length;
            },
            1, 2 => {
                if (kind == 1) fixedTables() else try dynamicTables(&stream);
                while (true) {
                    const symbol = try stream.decode(&literal_table);
                    if (symbol < 256) {
                        if (written >= out.len) return Error.OutOfMemory;
                        out[written] = @intCast(symbol);
                        written += 1;
                        continue;
                    }
                    if (symbol == 256) break;

                    const length_index = symbol - 257;
                    if (length_index >= length_base.len) return Error.BadStream;
                    const length = length_base[length_index] +
                        try stream.bits(length_extra[length_index]);

                    const distance_symbol = try stream.decode(&distance_table);
                    if (distance_symbol >= distance_base.len) return Error.BadStream;
                    const distance = distance_base[distance_symbol] +
                        try stream.bits(distance_extra[distance_symbol]);
                    if (distance > written) return Error.BadStream;
                    if (written + length > out.len) return Error.OutOfMemory;

                    // One byte at a time on purpose: overlapping copies are
                    // how deflate expresses a run, and a block copy would get
                    // them wrong.
                    var copied: usize = 0;
                    while (copied < length) : (copied += 1) {
                        out[written] = out[written - distance];
                        written += 1;
                    }
                }
            },
            else => return Error.BadStream,
        }
        if (final != 0) break;
    }
    return written;
}

// --- PNG -------------------------------------------------------------------

pub const Image = extern struct {
    /// ARGB8888, row major, as the plotter wants it.
    pixels: [*]const u32,
    width: i32,
    height: i32,
};

const max_pixels = 4096 * 4096;

fn paeth(a: i32, b: i32, c: i32) i32 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Decode a PNG. Memory for the pixels comes from the program's heap and is
/// never given back: an image a page is showing is an image it keeps.
pub fn decode(bytes: []const u8, out: *Image) Error!void {
    if (bytes.len < 8) return Error.NotAPng;
    const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    if (!std.mem.eql(u8, bytes[0..8], &signature)) return Error.NotAPng;

    var width: u32 = 0;
    var height: u32 = 0;
    var depth: u8 = 0;
    var colour: u8 = 0;
    var interlace: u8 = 0;

    var palette: [256][3]u8 = undefined;
    var palette_alpha: [256]u8 = @splat(255);
    var palette_len: usize = 0;

    // The compressed image data can arrive in several chunks and has to be
    // inflated as one stream, so it is gathered first.
    var compressed: ?[]u8 = null;
    var compressed_len: usize = 0;

    var at: usize = 8;
    while (at + 8 <= bytes.len) {
        const length = std.mem.readInt(u32, bytes[at..][0..4], .big);
        const kind = bytes[at + 4 ..][0..4];
        const body_at = at + 8;
        if (body_at + length + 4 > bytes.len) return Error.Truncated;
        const body = bytes[body_at..][0..length];

        if (std.mem.eql(u8, kind, "IHDR")) {
            if (length < 13) return Error.Truncated;
            width = std.mem.readInt(u32, body[0..4], .big);
            height = std.mem.readInt(u32, body[4..8], .big);
            depth = body[8];
            colour = body[9];
            interlace = body[12];
            if (width == 0 or height == 0) return Error.NotAPng;
            if (@as(u64, width) * height > max_pixels) return Error.OutOfMemory;
            if (depth != 8) return Error.Unsupported;
            if (interlace != 0) return Error.Unsupported;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            palette_len = @min(length / 3, 256);
            for (0..palette_len) |index| {
                palette[index] = .{ body[index * 3], body[index * 3 + 1], body[index * 3 + 2] };
            }
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            for (0..@min(length, 256)) |index| palette_alpha[index] = body[index];
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            if (compressed == null) {
                // Generous: deflate never expands by more than a little, and a
                // second pass to measure would mean holding the whole file
                // twice anyway.
                const room = bytes.len;
                const block = aizigos_alloc(room) orelse return Error.OutOfMemory;
                compressed = block[0..room];
            }
            if (compressed_len + length > compressed.?.len) return Error.OutOfMemory;
            @memcpy(compressed.?[compressed_len..][0..length], body);
            compressed_len += length;
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        }

        at = body_at + length + 4;
    }

    if (width == 0 or compressed == null) return Error.NotAPng;

    const channels: usize = switch (colour) {
        0 => 1, // grey
        2 => 3, // truecolour
        3 => 1, // palette index
        4 => 2, // grey and alpha
        6 => 4, // truecolour and alpha
        else => return Error.Unsupported,
    };

    const stride = @as(usize, width) * channels;
    const raw_len = (stride + 1) * height;
    const raw_block = aizigos_alloc(raw_len) orelse return Error.OutOfMemory;
    const raw = raw_block[0..raw_len];

    // A zlib stream: two bytes of header, then deflate.
    if (compressed_len < 2) return Error.Truncated;
    const inflated = try inflate(compressed.?[2..compressed_len], raw);
    if (inflated < raw_len) return Error.Truncated;

    const pixel_block = aizigos_alloc(@as(usize, width) * height * 4) orelse
        return Error.OutOfMemory;
    const pixels: [*]u32 = @ptrCast(@alignCast(pixel_block));

    // Undo the per-row filter, in place, then turn each row into pixels.
    var row: usize = 0;
    while (row < height) : (row += 1) {
        const filter = raw[row * (stride + 1)];
        const line = raw[row * (stride + 1) + 1 ..][0..stride];
        const previous: ?[]const u8 = if (row == 0)
            null
        else
            raw[(row - 1) * (stride + 1) + 1 ..][0..stride];

        var index: usize = 0;
        while (index < stride) : (index += 1) {
            const left: i32 = if (index >= channels) line[index - channels] else 0;
            const up: i32 = if (previous) |p| p[index] else 0;
            const up_left: i32 = if (previous != null and index >= channels)
                previous.?[index - channels]
            else
                0;
            const value: i32 = line[index];
            line[index] = switch (filter) {
                0 => @intCast(value),
                1 => @truncate(@as(u32, @bitCast(value + left))),
                2 => @truncate(@as(u32, @bitCast(value + up))),
                3 => @truncate(@as(u32, @bitCast(value + @divFloor(left + up, 2)))),
                4 => @truncate(@as(u32, @bitCast(value + paeth(left, up, up_left)))),
                else => return Error.BadStream,
            };
        }

        var column: usize = 0;
        while (column < width) : (column += 1) {
            const source = line[column * channels ..];
            var r: u32 = 0;
            var g: u32 = 0;
            var b: u32 = 0;
            var a: u32 = 255;
            switch (colour) {
                0 => {
                    r = source[0];
                    g = source[0];
                    b = source[0];
                },
                2 => {
                    r = source[0];
                    g = source[1];
                    b = source[2];
                },
                3 => {
                    const entry = @min(source[0], 255);
                    if (entry < palette_len) {
                        r = palette[entry][0];
                        g = palette[entry][1];
                        b = palette[entry][2];
                        a = palette_alpha[entry];
                    }
                },
                4 => {
                    r = source[0];
                    g = source[0];
                    b = source[0];
                    a = source[1];
                },
                6 => {
                    r = source[0];
                    g = source[1];
                    b = source[2];
                    a = source[3];
                },
                else => unreachable,
            }
            pixels[row * width + column] = (a << 24) | (r << 16) | (g << 8) | b;
        }
    }

    out.* = .{ .pixels = pixels, .width = @intCast(width), .height = @intCast(height) };
}

// --- the C side ------------------------------------------------------------

/// Decode a PNG held in memory. Returns zero on success, and the pixels belong
/// to the caller's heap from then on.
export fn png_decode(bytes: [*]const u8, length: usize, out: *Image) callconv(.c) c_int {
    decode(bytes[0..length], out) catch return -1;
    return 0;
}
