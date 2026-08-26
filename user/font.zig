//! A TrueType rasteriser, written here rather than ported.
//!
//! The usual answer is `stb_truetype`, and it is a good answer. This is not
//! that, for two reasons: the file is not on this machine to port, and a
//! system whose kernel, filesystem, network and TLS were all written in the
//! open should not have its letters arrive as a black box either. What it
//! does is the part that matters for reading text on a screen — character to
//! glyph, outline to coverage, coverage to a bitmap the plotter can blend —
//! and nothing else. No hinting, no kerning tables, no shaping.
//!
//! Outlines are quadratic B-splines, which flatten to lines cheaply, and the
//! fill is a four-by-four supersample: sixteen coverage levels, which at the
//! sizes a page is read at is indistinguishable from more. Floating point is
//! allowed here because this is user mode, where FP state is saved.

const std = @import("std");

extern fn aizigos_alloc(size: usize) callconv(.c) ?[*]u8;
extern fn aizigos_write(bytes: [*]const u8, length: usize) callconv(.c) void;

pub const Error = error{
    NotATrueTypeFile,
    TableMissing,
    Unsupported,
    OutOfRoom,
};

// --- reading the file ------------------------------------------------------

const Reader = struct {
    bytes: []const u8,

    fn u8At(self: Reader, at: usize) u8 {
        if (at >= self.bytes.len) return 0;
        return self.bytes[at];
    }

    fn u16At(self: Reader, at: usize) u16 {
        if (at + 2 > self.bytes.len) return 0;
        return std.mem.readInt(u16, self.bytes[at..][0..2], .big);
    }

    fn i16At(self: Reader, at: usize) i16 {
        return @bitCast(self.u16At(at));
    }

    fn u32At(self: Reader, at: usize) u32 {
        if (at + 4 > self.bytes.len) return 0;
        return std.mem.readInt(u32, self.bytes[at..][0..4], .big);
    }
};

const Font = struct {
    reader: Reader = .{ .bytes = &.{} },
    loaded: bool = false,

    units_per_em: f32 = 1000,
    ascent: f32 = 800,
    descent: f32 = -200,
    line_gap: f32 = 0,

    glyph_count: u32 = 0,
    long_loca: bool = false,
    horizontal_metrics: u32 = 0,

    loca: usize = 0,
    glyf: usize = 0,
    hmtx: usize = 0,
    cmap4: usize = 0,
};

/// Four faces, which is what running text needs: an upright, a bold, an
/// italic, and something fixed-width for code. A page that asks for anything
/// else gets the nearest of these, which is what a browser without a font
/// server does anyway.
pub const Face = enum(u32) { regular = 0, bold = 1, italic = 2, mono = 3 };

const face_count = 4;
var faces: [face_count]Font = @splat(.{});
var current: usize = 0;

/// The face being read from. Kept as a pointer-free index so that switching is
/// a number rather than a copy of a struct with a slice in it.
fn font_ptr() *Font {
    return &faces[current];
}

fn findTable(reader: Reader, tag: *const [4]u8) ?usize {
    const table_count = reader.u16At(4);
    var index: usize = 0;
    while (index < table_count) : (index += 1) {
        const record = 12 + index * 16;
        if (record + 16 > reader.bytes.len) return null;
        if (std.mem.eql(u8, reader.bytes[record..][0..4], tag)) {
            return reader.u32At(record + 8);
        }
    }
    return null;
}

/// Point `font` at a file in memory. The bytes are not copied and must outlive
/// every call that follows.
pub fn load(bytes: []const u8) Error!void {
    if (bytes.len < 12) return Error.NotATrueTypeFile;
    const reader = Reader{ .bytes = bytes };
    const version = reader.u32At(0);
    // 0x00010000 is TrueType outlines; 'true' is the same thing with an older
    // signature. 'OTTO' is PostScript outlines, which this does not read.
    if (version != 0x0001_0000 and version != 0x74727565) return Error.NotATrueTypeFile;

    const head = findTable(reader, "head") orelse return Error.TableMissing;
    const maxp = findTable(reader, "maxp") orelse return Error.TableMissing;
    const hhea = findTable(reader, "hhea") orelse return Error.TableMissing;
    const loca = findTable(reader, "loca") orelse return Error.TableMissing;
    const glyf = findTable(reader, "glyf") orelse return Error.TableMissing;
    const hmtx = findTable(reader, "hmtx") orelse return Error.TableMissing;
    const cmap = findTable(reader, "cmap") orelse return Error.TableMissing;

    var self = Font{ .reader = reader, .loaded = true };
    self.units_per_em = @floatFromInt(reader.u16At(head + 18));
    if (self.units_per_em == 0) self.units_per_em = 1000;
    self.long_loca = reader.i16At(head + 50) != 0;
    self.glyph_count = reader.u16At(maxp + 4);
    self.ascent = @floatFromInt(reader.i16At(hhea + 4));
    self.descent = @floatFromInt(reader.i16At(hhea + 6));
    self.line_gap = @floatFromInt(reader.i16At(hhea + 8));
    self.horizontal_metrics = reader.u16At(hhea + 34);
    self.loca = loca;
    self.glyf = glyf;
    self.hmtx = hmtx;
    self.cmap4 = try findFormat4(reader, cmap);

    faces[current] = self;
}

/// The character map, restricted to the one encoding worth reading: Windows
/// Unicode BMP, format 4. Everything a page of text needs is in there, and the
/// alternative is three more parsers for the same answer.
fn findFormat4(reader: Reader, cmap: usize) Error!usize {
    const table_count = reader.u16At(cmap + 2);
    var index: usize = 0;
    var best: ?usize = null;
    while (index < table_count) : (index += 1) {
        const record = cmap + 4 + index * 8;
        const platform = reader.u16At(record);
        const encoding = reader.u16At(record + 2);
        const offset = cmap + reader.u32At(record + 4);
        if (reader.u16At(offset) != 4) continue;
        const windows_bmp = platform == 3 and encoding == 1;
        const unicode = platform == 0;
        if (windows_bmp) return offset;
        if (unicode and best == null) best = offset;
    }
    return best orelse Error.Unsupported;
}

fn glyphOf(codepoint: u32) u32 {
    if (!font_ptr().loaded or codepoint > 0xFFFF) return 0;
    const reader = font_ptr().reader;
    const table = font_ptr().cmap4;
    const segments = reader.u16At(table + 6) / 2;
    if (segments == 0) return 0;

    const end_codes = table + 14;
    const start_codes = end_codes + segments * 2 + 2;
    const deltas = start_codes + segments * 2;
    const range_offsets = deltas + segments * 2;

    const code: u16 = @intCast(codepoint);
    var segment: usize = 0;
    while (segment < segments) : (segment += 1) {
        if (reader.u16At(end_codes + segment * 2) < code) continue;
        const start = reader.u16At(start_codes + segment * 2);
        if (code < start) return 0;

        const range_offset = reader.u16At(range_offsets + segment * 2);
        if (range_offset == 0) {
            return code +% reader.u16At(deltas + segment * 2);
        }
        // The offset is measured from the position of the entry itself, which
        // is the one genuinely strange thing in this format.
        const at = range_offsets + segment * 2 + range_offset + (code - start) * 2;
        const glyph = reader.u16At(at);
        if (glyph == 0) return 0;
        return glyph +% reader.u16At(deltas + segment * 2);
    }
    return 0;
}

fn glyphRange(index: u32) ?struct { start: usize, end: usize } {
    if (index >= font_ptr().glyph_count) return null;
    const reader = font_ptr().reader;
    const start: usize = if (font_ptr().long_loca)
        reader.u32At(font_ptr().loca + index * 4)
    else
        @as(usize, reader.u16At(font_ptr().loca + index * 2)) * 2;
    const end: usize = if (font_ptr().long_loca)
        reader.u32At(font_ptr().loca + (index + 1) * 4)
    else
        @as(usize, reader.u16At(font_ptr().loca + (index + 1) * 2)) * 2;
    if (end <= start) return null; // an empty glyph, such as a space
    return .{ .start = font_ptr().glyf + start, .end = font_ptr().glyf + end };
}

fn advanceOf(index: u32) f32 {
    if (font_ptr().horizontal_metrics == 0) return font_ptr().units_per_em / 2;
    const last = font_ptr().horizontal_metrics - 1;
    const at = if (index < font_ptr().horizontal_metrics) index else last;
    return @floatFromInt(font_ptr().reader.u16At(font_ptr().hmtx + at * 4));
}

// --- outlines --------------------------------------------------------------

const Point = struct { x: f32, y: f32, on_curve: bool };

const max_points = 512;
const max_contours = 32;

const Outline = struct {
    points: [max_points]Point = undefined,
    ends: [max_contours]usize = undefined,
    point_count: usize = 0,
    contour_count: usize = 0,

    fn add(self: *Outline, point: Point) void {
        if (self.point_count >= max_points) return;
        self.points[self.point_count] = point;
        self.point_count += 1;
    }
};

/// Read one glyph's contours in font units. Composite glyphs are followed one
/// level deep with their offsets applied: that covers accented letters, which
/// is what composites are mostly for, and skips the scaling variants that
/// almost nothing uses.
fn readOutline(index: u32, out: *Outline, depth: u32) void {
    const range = glyphRange(index) orelse return;
    const reader = font_ptr().reader;
    const contours = reader.i16At(range.start);

    if (contours < 0) {
        if (depth > 0) return;
        var at = range.start + 10;
        while (at + 4 <= range.end) {
            const flags = reader.u16At(at);
            const component = reader.u16At(at + 2);
            at += 4;

            var dx: f32 = 0;
            var dy: f32 = 0;
            if (flags & 0x0001 != 0) {
                dx = @floatFromInt(reader.i16At(at));
                dy = @floatFromInt(reader.i16At(at + 2));
                at += 4;
            } else {
                dx = @floatFromInt(@as(i8, @bitCast(reader.u8At(at))));
                dy = @floatFromInt(@as(i8, @bitCast(reader.u8At(at + 1))));
                at += 2;
            }
            // Skip whatever transform follows; offsets alone place accents.
            if (flags & 0x0008 != 0) at += 2;
            if (flags & 0x0040 != 0) at += 4;
            if (flags & 0x0080 != 0) at += 8;

            const before = out.point_count;
            readOutline(component, out, depth + 1);
            var moved = before;
            while (moved < out.point_count) : (moved += 1) {
                out.points[moved].x += dx;
                out.points[moved].y += dy;
            }
            if (flags & 0x0020 == 0) break; // no more components
        }
        return;
    }

    const contour_count: usize = @intCast(contours);
    if (contour_count == 0 or out.contour_count + contour_count > max_contours) return;

    var at = range.start + 10;
    const first_point = out.point_count;
    var last_index: usize = 0;
    var contour: usize = 0;
    while (contour < contour_count) : (contour += 1) {
        last_index = reader.u16At(at);
        at += 2;
        out.ends[out.contour_count + contour] = first_point + last_index + 1;
    }
    const point_count = last_index + 1;
    if (first_point + point_count > max_points) return;
    out.contour_count += contour_count;

    const instruction_length = reader.u16At(at);
    at += 2 + instruction_length;

    // Flags, run-length encoded.
    var flags: [max_points]u8 = undefined;
    var read: usize = 0;
    while (read < point_count) {
        const flag = reader.u8At(at);
        at += 1;
        flags[read] = flag;
        read += 1;
        if (flag & 0x08 != 0) {
            var repeat = reader.u8At(at);
            at += 1;
            while (repeat > 0 and read < point_count) : (repeat -= 1) {
                flags[read] = flag;
                read += 1;
            }
        }
    }

    // X then Y, each either a byte with a sign bit in the flags, a repeat of
    // the previous value, or a signed word.
    var x: f32 = 0;
    var index_x: usize = 0;
    while (index_x < point_count) : (index_x += 1) {
        const flag = flags[index_x];
        if (flag & 0x02 != 0) {
            const delta: f32 = @floatFromInt(reader.u8At(at));
            at += 1;
            x += if (flag & 0x10 != 0) delta else -delta;
        } else if (flag & 0x10 == 0) {
            x += @floatFromInt(reader.i16At(at));
            at += 2;
        }
        out.add(.{ .x = x, .y = 0, .on_curve = flag & 0x01 != 0 });
    }

    var y: f32 = 0;
    var index_y: usize = 0;
    while (index_y < point_count) : (index_y += 1) {
        const flag = flags[index_y];
        if (flag & 0x04 != 0) {
            const delta: f32 = @floatFromInt(reader.u8At(at));
            at += 1;
            y += if (flag & 0x20 != 0) delta else -delta;
        } else if (flag & 0x20 == 0) {
            y += @floatFromInt(reader.i16At(at));
            at += 2;
        }
        if (first_point + index_y < out.point_count) out.points[first_point + index_y].y = y;
    }
}

// --- filling ---------------------------------------------------------------

const max_edges = 1024;

const Edge = struct { x0: f32, y0: f32, x1: f32, y1: f32 };

var edges: [max_edges]Edge = undefined;
var edge_count: usize = 0;

fn addEdge(x0: f32, y0: f32, x1: f32, y1: f32) void {
    if (edge_count >= max_edges) return;
    if (y0 == y1) return; // horizontal edges contribute nothing to a scanline
    edges[edge_count] = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
    edge_count += 1;
}

/// Flatten a quadratic into line segments. Sixteen is generous at reading
/// sizes and cheap: the whole curve is a few pixels across.
fn addQuadratic(x0: f32, y0: f32, cx: f32, cy: f32, x1: f32, y1: f32) void {
    const steps = 8;
    var previous_x = x0;
    var previous_y = y0;
    var step: usize = 1;
    while (step <= steps) : (step += 1) {
        const t = @as(f32, @floatFromInt(step)) / steps;
        const inverse = 1 - t;
        const px = inverse * inverse * x0 + 2 * inverse * t * cx + t * t * x1;
        const py = inverse * inverse * y0 + 2 * inverse * t * cy + t * t * y1;
        addEdge(previous_x, previous_y, px, py);
        previous_x = px;
        previous_y = py;
    }
}

/// Walk one contour, turning the on- and off-curve points into edges. A point
/// between two off-curve points is implied at their midpoint, which is the
/// convention that makes TrueType outlines compact.
fn contourEdges(points: []const Point, scale: f32, origin_x: f32, origin_y: f32) void {
    if (points.len < 2) return;

    var start_x: f32 = undefined;
    var start_y: f32 = undefined;
    var first: usize = 0;
    if (points[0].on_curve) {
        start_x = points[0].x;
        start_y = points[0].y;
        first = 1;
    } else if (points[points.len - 1].on_curve) {
        start_x = points[points.len - 1].x;
        start_y = points[points.len - 1].y;
        first = 0;
    } else {
        start_x = (points[0].x + points[points.len - 1].x) / 2;
        start_y = (points[0].y + points[points.len - 1].y) / 2;
        first = 0;
    }

    const toX = struct {
        fn f(v: f32, s: f32, o: f32) f32 {
            return o + v * s;
        }
    }.f;

    var current_x = start_x;
    var current_y = start_y;
    var control: ?Point = null;

    var index: usize = 0;
    while (index < points.len) : (index += 1) {
        const point = points[(first + index) % points.len];
        if (point.on_curve) {
            if (control) |c| {
                addQuadratic(
                    toX(current_x, scale, origin_x),
                    toX(current_y, -scale, origin_y),
                    toX(c.x, scale, origin_x),
                    toX(c.y, -scale, origin_y),
                    toX(point.x, scale, origin_x),
                    toX(point.y, -scale, origin_y),
                );
                control = null;
            } else {
                addEdge(
                    toX(current_x, scale, origin_x),
                    toX(current_y, -scale, origin_y),
                    toX(point.x, scale, origin_x),
                    toX(point.y, -scale, origin_y),
                );
            }
            current_x = point.x;
            current_y = point.y;
        } else {
            if (control) |c| {
                const mid_x = (c.x + point.x) / 2;
                const mid_y = (c.y + point.y) / 2;
                addQuadratic(
                    toX(current_x, scale, origin_x),
                    toX(current_y, -scale, origin_y),
                    toX(c.x, scale, origin_x),
                    toX(c.y, -scale, origin_y),
                    toX(mid_x, scale, origin_x),
                    toX(mid_y, -scale, origin_y),
                );
                current_x = mid_x;
                current_y = mid_y;
            }
            control = point;
        }
    }

    // Close the contour.
    if (control) |c| {
        addQuadratic(
            toX(current_x, scale, origin_x),
            toX(current_y, -scale, origin_y),
            toX(c.x, scale, origin_x),
            toX(c.y, -scale, origin_y),
            toX(start_x, scale, origin_x),
            toX(start_y, -scale, origin_y),
        );
    } else {
        addEdge(
            toX(current_x, scale, origin_x),
            toX(current_y, -scale, origin_y),
            toX(start_x, scale, origin_x),
            toX(start_y, -scale, origin_y),
        );
    }
}

// --- the glyph a caller gets ----------------------------------------------

pub const max_glyph = 64;

pub const Bitmap = extern struct {
    /// Coverage, one byte per pixel, row major.
    pixels: [*]const u8,
    width: i32,
    height: i32,
    /// Where to put it, relative to the pen position and the baseline.
    left: i32,
    top: i32,
    advance: f32,
};

var coverage: [max_glyph * max_glyph]u8 = @splat(0);

/// Rasterise one character at one size. The bitmap belongs to this module and
/// is overwritten by the next call: a caller that wants to keep it copies it,
/// which is what the cache above this does.
pub fn render(codepoint: u32, size_px: f32, out: *Bitmap) bool {
    out.* = .{ .pixels = &coverage, .width = 0, .height = 0, .left = 0, .top = 0, .advance = 0 };
    if (!font_ptr().loaded or size_px <= 0) return false;

    const glyph = glyphOf(codepoint);
    const scale = size_px / font_ptr().units_per_em;
    out.advance = advanceOf(glyph) * scale;

    var outline = Outline{};
    readOutline(glyph, &outline, 0);
    if (outline.point_count == 0 or outline.contour_count == 0) return true; // a space

    // The glyph's extent in font units, so the bitmap is only as big as it
    // needs to be and the caller learns where to put it.
    var min_x: f32 = outline.points[0].x;
    var max_x: f32 = min_x;
    var min_y: f32 = outline.points[0].y;
    var max_y: f32 = min_y;
    for (outline.points[0..outline.point_count]) |point| {
        min_x = @min(min_x, point.x);
        max_x = @max(max_x, point.x);
        min_y = @min(min_y, point.y);
        max_y = @max(max_y, point.y);
    }

    const left = @floor(min_x * scale) - 1;
    const top = @ceil(max_y * scale) + 1;
    const width_f = @ceil(max_x * scale) - left + 2;
    const height_f = top - @floor(min_y * scale) + 2;
    const width: usize = @intFromFloat(@max(1, @min(width_f, @as(f32, max_glyph))));
    const height: usize = @intFromFloat(@max(1, @min(height_f, @as(f32, max_glyph))));

    edge_count = 0;
    var start: usize = 0;
    var contour: usize = 0;
    while (contour < outline.contour_count) : (contour += 1) {
        const end = @min(outline.ends[contour], outline.point_count);
        if (end > start) {
            contourEdges(outline.points[start..end], scale, -left, top);
        }
        start = end;
    }

    fill(width, height);
    out.width = @intCast(width);
    out.height = @intCast(height);
    out.left = @intFromFloat(left);
    out.top = @intFromFloat(top);
    return true;
}

/// Four samples across and four down: sixteen levels of coverage, which is
/// enough that a reader sees letters rather than steps.
fn fill(width: usize, height: usize) void {
    @memset(coverage[0 .. width * height], 0);
    if (edge_count == 0) return;

    const samples: f32 = 4;
    var crossings: [64]f32 = undefined;

    var row: usize = 0;
    while (row < height) : (row += 1) {
        var sub: usize = 0;
        while (sub < 4) : (sub += 1) {
            const y = @as(f32, @floatFromInt(row)) + (@as(f32, @floatFromInt(sub)) + 0.5) / samples;

            var found: usize = 0;
            for (edges[0..edge_count]) |edge| {
                const top_y = @min(edge.y0, edge.y1);
                const bottom_y = @max(edge.y0, edge.y1);
                if (y < top_y or y >= bottom_y) continue;
                if (found >= crossings.len) break;
                const t = (y - edge.y0) / (edge.y1 - edge.y0);
                crossings[found] = edge.x0 + t * (edge.x1 - edge.x0);
                found += 1;
            }
            if (found < 2) continue;

            // Insertion sort: a scanline through a letter crosses a handful of
            // edges, and anything cleverer would be slower here.
            var i: usize = 1;
            while (i < found) : (i += 1) {
                const value = crossings[i];
                var j = i;
                while (j > 0 and crossings[j - 1] > value) : (j -= 1) {
                    crossings[j] = crossings[j - 1];
                }
                crossings[j] = value;
            }

            // Even-odd pairs. TrueType's own rule is non-zero winding, and for
            // the outlines a text face actually contains the two agree.
            var pair: usize = 0;
            while (pair + 1 < found) : (pair += 2) {
                var x = crossings[pair];
                const x_end = crossings[pair + 1];
                while (x < x_end) : (x += 1.0 / samples) {
                    const column: isize = @intFromFloat(@floor(x));
                    if (column < 0 or column >= @as(isize, @intCast(width))) continue;
                    const at = row * width + @as(usize, @intCast(column));
                    if (coverage[at] < 255 - 16) coverage[at] += 16;
                }
            }
        }
    }
}

// --- the C side ------------------------------------------------------------

var file_bytes: ?[]u8 = null;

/// Choose which face the calls below read from. Out of range is ignored: a
/// page asking for a face that does not exist should get plain text, not
/// nothing.
export fn font_select(face: u32) callconv(.c) void {
    if (face < face_count and faces[face].loaded) current = face;
}

/// Whether a face has been loaded, so a caller can fall back rather than
/// measure a string against a font that is not there.
export fn font_has(face: u32) callconv(.c) bool {
    return face < face_count and faces[face].loaded;
}

/// Load a font from memory into one of the four slots. The program reads the
/// file; this parses it.
export fn font_load_face(face: u32, bytes: [*]const u8, length: usize) callconv(.c) c_int {
    if (face >= face_count) return -1;
    const previous = current;
    current = face;
    defer current = previous;
    return font_load(bytes, length);
}

/// Load a font from memory. The program reads the file; this parses it.
export fn font_load(bytes: [*]const u8, length: usize) callconv(.c) c_int {
    load(bytes[0..length]) catch |e| {
        const name = @errorName(e);
        aizigos_write("font: ", 6);
        aizigos_write(name.ptr, name.len);
        aizigos_write("\n", 1);
        return -1;
    };
    return 0;
}

export fn font_ready() callconv(.c) bool {
    return font_ptr().loaded;
}

/// Distance from the top of a line to the baseline, in pixels.
export fn font_ascent(size_px: f32) callconv(.c) f32 {
    if (!font_ptr().loaded) return size_px;
    return font_ptr().ascent * (size_px / font_ptr().units_per_em);
}

export fn font_line_height(size_px: f32) callconv(.c) f32 {
    if (!font_ptr().loaded) return size_px * 1.2;
    return (font_ptr().ascent - font_ptr().descent + font_ptr().line_gap) * (size_px / font_ptr().units_per_em);
}

export fn font_advance(codepoint: u32, size_px: f32) callconv(.c) f32 {
    if (!font_ptr().loaded) return size_px / 2;
    return advanceOf(glyphOf(codepoint)) * (size_px / font_ptr().units_per_em);
}

export fn font_render(codepoint: u32, size_px: f32, out: *Bitmap) callconv(.c) bool {
    return render(codepoint, size_px, out);
}
