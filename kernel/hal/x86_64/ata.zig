//! ATA over programmed I/O: the disk the machine booted from, read back.
//!
//! Polled, 28-bit, read-only, primary channel. That is a deliberately small
//! target. DMA, queueing and 48-bit addressing all matter for a disk you write
//! to at speed, and none of them matter for reading a few megabytes off the
//! boot volume during start-up. When the native filesystem arrives it will
//! want AHCI or NVMe underneath it, and that driver can be written knowing
//! what it is for; this one exists so the kernel can find its own files.
//!
//! Every machine this targets has this interface: QEMU's default disk is IDE,
//! VirtualBox's is too unless told otherwise, and firmware left the controller
//! in a state we can use. Real modern hardware in AHCI mode is not covered,
//! and `present()` answers honestly rather than reading rubbish.

const io = @import("serial.zig");

pub const sector_size = 512;

// The primary channel's registers, at the addresses they have had since 1986.
const data: u16 = 0x1F0;
const error_reg: u16 = 0x1F1;
const sector_count: u16 = 0x1F2;
const lba_low: u16 = 0x1F3;
const lba_mid: u16 = 0x1F4;
const lba_high: u16 = 0x1F5;
const drive_head: u16 = 0x1F6;
const status_reg: u16 = 0x1F7;
const command_reg: u16 = 0x1F7;
const control_reg: u16 = 0x3F6;

const status_err: u8 = 0x01;
const status_drq: u8 = 0x08;
const status_df: u8 = 0x20;
const status_ready: u8 = 0x40;
const status_busy: u8 = 0x80;

const cmd_read_sectors: u8 = 0x20;
const cmd_identify: u8 = 0xEC;

/// How many polls to give the drive before calling it dead. Generous: a
/// spinning disk seeking across a platter is slow, and a wrong answer here
/// looks like a corrupt filesystem rather than a timeout.
const spin_limit: u32 = 5_000_000;

var detected = false;
var sectors_total: u64 = 0;
var model: [40]u8 = @splat(' ');

pub fn present() bool {
    return detected;
}

pub fn sectorCount() u64 {
    return sectors_total;
}

/// The drive's own name for itself, trailing spaces trimmed.
pub fn modelName() []const u8 {
    var end: usize = model.len;
    while (end > 0 and (model[end - 1] == ' ' or model[end - 1] == 0)) end -= 1;
    return model[0..end];
}

/// Identify the master drive on the primary channel. Safe to call on a machine
/// that has no such drive: it leaves `present()` false and returns.
pub fn init() void {
    detected = false;
    sectors_total = 0;

    // Interrupts off on this channel: everything here polls, and a stray IRQ14
    // with no handler is worse than no interrupt at all.
    io.outb(control_reg, 0x02);

    selectDrive(0);
    io.outb(sector_count, 0);
    io.outb(lba_low, 0);
    io.outb(lba_mid, 0);
    io.outb(lba_high, 0);
    io.outb(command_reg, cmd_identify);

    // A floating bus reads as 0xFF; status zero means nothing is there.
    const first = io.inb(status_reg);
    if (first == 0 or first == 0xFF) return;

    if (!waitWhileBusy()) return;
    // A non-zero signature in these two means ATAPI or SATA speaking a
    // different protocol. Neither is a disk this driver can read.
    if (io.inb(lba_mid) != 0 or io.inb(lba_high) != 0) return;
    if (!waitForData()) return;

    var identify: [256]u16 = @splat(0);
    for (&identify) |*word| word.* = io.inw(data);

    // Words 27..46 hold the model, byte-swapped within each word.
    for (0..20) |index| {
        const word = identify[27 + index];
        model[index * 2] = @intCast(word >> 8);
        model[index * 2 + 1] = @intCast(word & 0xFF);
    }
    // Words 60..61: the 28-bit sector count, low word first.
    sectors_total = @as(u64, identify[60]) | (@as(u64, identify[61]) << 16);
    if (sectors_total == 0) return;
    detected = true;
}

/// Read whole sectors into `buffer`, whose length must be a multiple of the
/// sector size. False means the drive refused or never answered, and the
/// buffer's contents are then not to be trusted.
pub fn read(lba: u64, buffer: []u8) bool {
    if (!detected) return false;
    if (buffer.len == 0 or buffer.len % sector_size != 0) return false;

    const wanted = buffer.len / sector_size;
    var done: usize = 0;
    while (done < wanted) {
        // 28-bit addressing, and 256 sectors per command at most; the count
        // register calls that zero.
        const chunk: usize = @min(wanted - done, 128);
        const count: u8 = @intCast(chunk);
        const at = lba + done;
        if (at + chunk > sectors_total) return false;
        if (at >= 1 << 28) return false;

        const span = buffer[done * sector_size ..][0 .. chunk * sector_size];
        if (!readChunk(at, count, span)) return false;
        done += chunk;
    }
    return true;
}

fn readChunk(lba: u64, count: u8, into: []u8) bool {
    if (!waitWhileBusy()) return false;

    selectDrive(@intCast((lba >> 24) & 0x0F));
    io.outb(error_reg, 0);
    io.outb(sector_count, count);
    io.outb(lba_low, @intCast(lba & 0xFF));
    io.outb(lba_mid, @intCast((lba >> 8) & 0xFF));
    io.outb(lba_high, @intCast((lba >> 16) & 0xFF));
    io.outb(command_reg, cmd_read_sectors);

    var sector: usize = 0;
    while (sector < count) : (sector += 1) {
        if (!waitForData()) return false;
        // The drive hands over one 16-bit word at a time, and the caller's
        // buffer may sit at any address, so bytes go in one at a time too.
        const target = into[sector * sector_size ..][0..sector_size];
        var index: usize = 0;
        while (index < sector_size) : (index += 2) {
            const word = io.inw(data);
            target[index] = @intCast(word & 0xFF);
            target[index + 1] = @intCast(word >> 8);
        }
    }
    return true;
}

fn selectDrive(lba_top: u8) void {
    // 0xE0: master drive, LBA mode, top four address bits in the low nibble.
    io.outb(drive_head, 0xE0 | (lba_top & 0x0F));
    // Reading the alternate status four times is the specified way to wait
    // 400ns for the selection to take effect.
    var settle: usize = 0;
    while (settle < 4) : (settle += 1) _ = io.inb(control_reg);
}

fn waitWhileBusy() bool {
    var spins: u32 = 0;
    while (spins < spin_limit) : (spins += 1) {
        const status = io.inb(status_reg);
        if (status & status_busy == 0) return true;
    }
    return false;
}

/// Wait for the drive to have a sector ready, and treat an error bit as an
/// answer rather than something to keep waiting through.
fn waitForData() bool {
    var spins: u32 = 0;
    while (spins < spin_limit) : (spins += 1) {
        const status = io.inb(status_reg);
        if (status & status_busy != 0) continue;
        if (status & (status_err | status_df) != 0) return false;
        if (status & status_drq != 0) return true;
        if (status & status_ready == 0) continue;
    }
    return false;
}
