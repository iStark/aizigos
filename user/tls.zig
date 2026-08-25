//! TLS 1.3 for user programs, over the kernel's sockets.
//!
//! The handshake and the record layer are Zig's own `std.crypto.tls.Client`,
//! which compiles for a freestanding target unchanged: no allocator, no
//! operating system, nothing but bytes in and bytes out. What this file adds
//! is the two ends of that pipe — a reader and a writer over `connect`, `send`
//! and `recv` — and the two things the machine has to supply that arithmetic
//! cannot: random bytes and the date.
//!
//! It runs in user mode, on the far side of the system call gate, for the same
//! reason HTTP does: a microkernel with a size budget has no business holding
//! a certificate parser. The kernel's part is the socket and the capability in
//! front of it.
//!
//! **The server is not authenticated yet.** The handshake completes and the
//! traffic is encrypted, but nothing checks that the certificate belongs to
//! the host it claims to, because that needs a certificate store this system
//! does not have yet. Every caller is told so, and the viewer says it on the
//! page. Encryption without authentication stops someone reading the traffic
//! and does not stop someone answering in the server's place — a difference
//! worth stating in the interface rather than in a comment.

const std = @import("std");
const Client = std.crypto.tls.Client;

// The kernel's side of the gate, as declared in lib/libc/include/aizigos.h.
extern fn aizigos_connect(host: [*]const u8, host_len: usize, port: u16) callconv(.c) i64;
extern fn aizigos_send(handle: i64, buf: [*]const u8, length: usize) callconv(.c) i64;
extern fn aizigos_recv(handle: i64, buf: [*]u8, length: usize) callconv(.c) i64;
extern fn aizigos_close(handle: i64) callconv(.c) void;
extern fn aizigos_random(buf: [*]u8, length: usize) callconv(.c) i64;
extern fn aizigos_realtime() callconv(.c) u64;
extern fn aizigos_write(bytes: [*]const u8, length: usize) callconv(.c) void;

/// Errors a C caller can act on, negative so they cannot be mistaken for a
/// length. The kernel's own codes come through unchanged.
pub const Error = enum(i64) {
    no_entropy = -110,
    no_clock = -111,
    handshake = -112,
    write_failed = -113,
    read_failed = -114,
    too_long = -115,
};

/// Say something on the console. A handshake that fails has one interesting
/// fact in it — which step objected — and losing that to a single error code
/// would mean guessing.
fn note(prefix: []const u8, detail: []const u8) void {
    aizigos_write(prefix.ptr, prefix.len);
    aizigos_write(detail.ptr, detail.len);
    aizigos_write("\n", 1);
}

fn fail(e: Error) i64 {
    return @intFromEnum(e);
}

/// A socket dressed as the reader and writer the TLS client expects. The
/// buffers belong to the caller: this file allocates nothing.
const Socket = struct {
    handle: i64,
    reader: std.Io.Reader,
    writer: std.Io.Writer,

    fn init(handle: i64, read_buffer: []u8, write_buffer: []u8) Socket {
        return .{
            .handle = handle,
            .reader = .{
                .vtable = &.{ .stream = streamIn },
                .buffer = read_buffer,
                .seek = 0,
                .end = 0,
            },
            .writer = .{
                .vtable = &.{ .drain = drainOut },
                .buffer = write_buffer,
                .end = 0,
            },
        };
    }

    fn ofReader(reader: *std.Io.Reader) *Socket {
        return @alignCast(@fieldParentPtr("reader", reader));
    }

    fn ofWriter(writer: *std.Io.Writer) *Socket {
        return @alignCast(@fieldParentPtr("writer", writer));
    }

    /// Read once into whatever space the caller offered. A socket that returns
    /// zero has been closed by the other end, which is the end of the stream
    /// and not a failure.
    fn streamIn(reader: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self = ofReader(reader);
        const destination = limit.slice(try w.writableSliceGreedy(1));
        const got = aizigos_recv(self.handle, destination.ptr, destination.len);
        if (got < 0) return error.ReadFailed;
        if (got == 0) return error.EndOfStream;
        w.advance(@intCast(got));
        return @intCast(got);
    }

    /// Send everything: the buffer first, then each slice, then the last one
    /// repeated. The count returned is of bytes taken from `data` only —
    /// bytes that came out of the buffer do not belong in it, and counting
    /// them there tells the caller it has sent something it has not.
    fn drainOut(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self = ofWriter(writer);
        const buffered = writer.buffered();
        if (buffered.len > 0) {
            _ = try self.sendAll(buffered);
            writer.end = 0;
        }

        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |chunk| {
            if (chunk.len == 0) continue;
            _ = try self.sendAll(chunk);
            consumed += chunk.len;
        }

        const last = data[data.len - 1];
        if (last.len > 0) {
            var repeat: usize = 0;
            while (repeat < splat) : (repeat += 1) {
                _ = try self.sendAll(last);
                consumed += last.len;
            }
        }
        return consumed;
    }

    fn sendAll(self: *Socket, bytes: []const u8) std.Io.Writer.Error!usize {
        var at: usize = 0;
        while (at < bytes.len) {
            const wrote = aizigos_send(self.handle, bytes.ptr + at, bytes.len - at);
            if (wrote <= 0) return error.WriteFailed;
            at += @intCast(wrote);
        }
        return at;
    }
};

/// One whole TLS record, plus room to work in. Every one of these four
/// buffers has to hold a record: the client asserts as much about the streams
/// it is given, and it is right to — a record cannot be processed in halves.
pub const buffer_len = Client.min_buffer_len + 2048;

/// Everything one connection needs, so a caller can put it wherever it has
/// room. It does not fit on a program's stack and is not meant to.
pub const Session = struct {
    client: Client,
    socket: Socket,
    /// The plaintext side, which the client hands to the program.
    tls_read: [buffer_len]u8,
    tls_write: [buffer_len]u8,
    /// The ciphertext side, which the client hands to the socket.
    socket_read: [buffer_len]u8,
    socket_write: [buffer_len]u8,
};

/// Fetch https://host/path into `out`, headers included. Returns the number of
/// bytes, or a negative error.
///
/// `scratch` is space the caller owns — `sizeOf(Session)` bytes of it.
/// The connection is opened, used and closed within this call: keeping it open
/// is what a browser will want, and this is not one yet.
pub fn get(
    scratch: *Session,
    host: []const u8,
    path: []const u8,
    out: []u8,
) i64 {
    var entropy: [Client.Options.entropy_len]u8 = undefined;
    if (aizigos_random(&entropy, entropy.len) != @as(i64, entropy.len)) {
        return fail(.no_entropy);
    }

    const seconds = aizigos_realtime();
    if (seconds == 0) return fail(.no_clock);

    const handle = aizigos_connect(host.ptr, host.len, 443);
    if (handle < 0) return handle;
    defer aizigos_close(handle);

    scratch.socket = Socket.init(handle, &scratch.socket_read, &scratch.socket_write);

    scratch.client = Client.init(&scratch.socket.reader, &scratch.socket.writer, .{
        .host = .{ .explicit = host },
        // Nothing verifies the certificate yet: see the note at the top of this
        // file, and the words the viewer puts on the page.
        .ca = .no_verification,
        .read_buffer = &scratch.tls_read,
        .write_buffer = &scratch.tls_write,
        .entropy = &entropy,
        .realtime_now = .{ .nanoseconds = @as(i96, seconds) * 1_000_000_000 },
    }) catch |e| {
        note("tls: handshake failed: ", @errorName(e));
        return fail(.handshake);
    };

    var request_buffer: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buffer, "GET {s} HTTP/1.1\r\n" ++
        "Host: {s}\r\n" ++
        "User-Agent: AIZigOS/0.2\r\n" ++
        "Accept: text/html\r\n" ++
        "Connection: close\r\n" ++
        "\r\n", .{ path, host }) catch return fail(.too_long);

    // `writer` and `reader` are the plaintext ends of the connection; the
    // ciphertext ends are the socket's, and the client moves between them.
    scratch.client.writer.writeAll(request) catch return fail(.write_failed);
    // Two flushes, because there are two streams: the first encrypts the
    // request into the socket's buffer, the second puts it on the wire. Only
    // doing the first leaves the server waiting for a request that is sitting
    // in memory a few feet away.
    scratch.client.writer.flush() catch return fail(.write_failed);
    scratch.socket.writer.flush() catch return fail(.write_failed);

    var filled: usize = 0;
    while (filled < out.len) {
        // A short read means the stream ended, which for "Connection: close"
        // is how a complete answer arrives.
        const got = scratch.client.reader.readSliceShort(out[filled..]) catch |e| {
            if (filled > 0) break;
            note("tls: read failed: ", @errorName(e));
            return fail(.read_failed);
        };
        if (got == 0) break;
        filled += got;
    }
    return @intCast(filled);
}

// --- the C side of the gate ------------------------------------------------

var session: Session = undefined;

/// `aizigos_tls_get(host, path, buf, len)` — one connection, one request.
export fn aizigos_tls_get(
    host: [*:0]const u8,
    path: [*:0]const u8,
    buf: [*]u8,
    len: usize,
) callconv(.c) i64 {
    return get(&session, std.mem.span(host), std.mem.span(path), buf[0..len]);
}

/// Whether the last connection authenticated the server. It did not, and this
/// exists so that a caller has to ask rather than assume: when verification
/// arrives, this starts telling the truth instead of always saying no.
export fn aizigos_tls_verified() callconv(.c) bool {
    return false;
}
