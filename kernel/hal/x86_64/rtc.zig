//! What time it is, and where randomness comes from.
//!
//! Two things a machine cannot work out from first principles. Until now this
//! kernel had neither: `nowNs` counts from the moment it started, which is
//! enough to schedule with and useless for deciding whether a certificate
//! expired last March.
//!
//! The clock is the CMOS RTC, which every PC has had since 1984 and which UEFI
//! leaves running. The randomness is RDRAND where the processor has it, and an
//! honest admission where it does not — a program asking for entropy deserves
//! to know whether it got any.

const io = @import("serial.zig");

const address_port: u16 = 0x70;
const data_port: u16 = 0x71;

fn cmos(register: u8) u8 {
    // The top bit disables the non-maskable interrupt while the register is
    // selected; leaving it set is the conventional way to read these.
    io.outb(address_port, 0x80 | register);
    return io.inb(data_port);
}

fn updating() bool {
    return cmos(0x0A) & 0x80 != 0;
}

fn fromBcd(value: u8) u8 {
    return (value & 0x0F) + ((value >> 4) * 10);
}

/// Seconds since the Unix epoch, or zero when the clock cannot be read.
///
/// Read twice and accept only a matching pair: the registers tick over while
/// they are being read, and 23:59:59 followed by the next day's date is a
/// plausible way to be an hour wrong once a day.
pub fn unixSeconds() u64 {
    var attempt: usize = 0;
    var previous: [7]u8 = @splat(0xFF);
    while (attempt < 8) : (attempt += 1) {
        var guard: usize = 0;
        while (updating() and guard < 1_000_000) : (guard += 1) {}

        const status = cmos(0x0B);
        const binary = status & 0x04 != 0;
        const hour_raw = cmos(0x04);
        var fields = [7]u8{
            cmos(0x00), // second
            cmos(0x02), // minute
            hour_raw & 0x7F,
            cmos(0x07), // day
            cmos(0x08), // month
            cmos(0x09), // year within the century
            cmos(0x32), // century, where the firmware keeps one
        };
        if (!binary) {
            for (&fields, 0..) |*field, index| {
                // The hour keeps its 12-hour flag in the top bit, already
                // masked off above; the rest convert straight across.
                _ = index;
                field.* = fromBcd(field.*);
            }
        }
        // A 12-hour clock says so in the top bit of the raw hour byte.
        if (status & 0x02 == 0 and hour_raw & 0x80 != 0) {
            fields[2] = (fields[2] % 12) + 12;
        }

        if (equal(fields, previous)) return assemble(fields);
        previous = fields;
    }
    return 0;
}

fn equal(a: [7]u8, b: [7]u8) bool {
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn assemble(f: [7]u8) u64 {
    const century: u64 = if (f[6] >= 19 and f[6] <= 21) f[6] else 20;
    const year: u64 = century * 100 + f[5];
    const month: u64 = f[4];
    const day: u64 = f[3];
    if (month < 1 or month > 12 or day < 1 or day > 31 or year < 1970) return 0;

    // Days from the civil calendar, by the usual shift-March-to-the-front
    // trick: it makes the leap day the last day of the year and removes every
    // special case from the arithmetic.
    const y: u64 = if (month <= 2) year - 1 else year;
    const era = y / 400;
    const year_of_era = y - era * 400;
    const shifted_month = if (month > 2) month - 3 else month + 9;
    const day_of_year = (153 * shifted_month + 2) / 5 + day - 1;
    const day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    const days = era * 146097 + day_of_era - 719468;

    return days * 86400 + @as(u64, f[2]) * 3600 + @as(u64, f[1]) * 60 + f[0];
}

// --- randomness -----------------------------------------------------------

var has_rdrand: ?bool = null;

fn rdrandAvailable() bool {
    if (has_rdrand) |known| return known;
    var ecx: u32 = 0;
    asm volatile ("cpuid"
        : [ecx] "={ecx}" (ecx),
        : [leaf] "{eax}" (@as(u32, 1)),
        : .{ .eax = true, .ebx = true, .edx = true });
    const present = ecx & (1 << 30) != 0;
    has_rdrand = present;
    return present;
}

fn rdrand64() ?u64 {
    var value: u64 = 0;
    var ok: u8 = 0;
    var attempt: usize = 0;
    while (attempt < 10) : (attempt += 1) {
        asm volatile (
            \\rdrand %[v]
            \\setc %[ok]
            : [v] "=r" (value),
              [ok] "=r" (ok),
        );
        if (ok != 0) return value;
    }
    return null;
}

/// Fill `out` with random bytes. The answer says whether they came from the
/// processor's generator: a caller doing cryptography has a right to know that
/// it is about to build a key out of a stopwatch.
pub fn random(out: []u8) bool {
    if (rdrandAvailable()) {
        var at: usize = 0;
        var hardware = true;
        while (at < out.len) {
            const chunk = rdrand64() orelse {
                hardware = false;
                break;
            };
            const take = @min(8, out.len - at);
            var byte: usize = 0;
            while (byte < take) : (byte += 1) {
                out[at + byte] = @truncate(chunk >> @intCast(byte * 8));
            }
            at += take;
        }
        if (hardware and at == out.len) return true;
    }

    // No generator, or it gave up. What is left is timing jitter, which is not
    // a substitute and is not being presented as one: the false return is the
    // whole point of this function's signature.
    const pit = @import("pit.zig");
    var state: u64 = pit.rdtsc();
    for (out) |*byte| {
        state ^= pit.rdtsc();
        state = state *% 6364136223846793005 +% 1442695040888963407;
        byte.* = @truncate(state >> 33);
    }
    return false;
}
