//! Architecture-independent HAL types.
//! Everything above the HAL speaks only in these types (FR-1.4).

pub const PhysAddr = u64;
pub const VirtAddr = u64;

/// Rights and attributes of a page mapping.
pub const MapFlags = packed struct(u8) {
    read: bool = true,
    write: bool = false,
    exec: bool = false,
    /// Reachable from user mode.
    user: bool = false,
    /// Device-nGnRnE / uncached MMIO.
    device: bool = false,
    /// Global entry (survives an ASID change).
    global: bool = false,
    _pad: u2 = 0,
};

pub const MmuError = error{
    OutOfTables,
    AlreadyMapped,
    NotMapped,
    Misaligned,
    Unsupported,
};

pub const MemKind = enum(u8) {
    /// Ordinary free RAM, handed to the PMM.
    usable,
    /// Taken by the kernel or the firmware.
    reserved,
    /// A device MMIO window.
    device,
};

pub const MemRegion = struct {
    base: PhysAddr,
    len: u64,
    kind: MemKind,

    pub fn end(self: MemRegion) PhysAddr {
        return self.base + self.len;
    }
};

/// CPU performance level (the DVFS hint from the power profiles).
/// 0 is the lowest frequency, 255 the highest.
pub const PerfLevel = u8;

pub const perf_min: PerfLevel = 0;
pub const perf_nominal: PerfLevel = 128;
pub const perf_max: PerfLevel = 255;

/// Why the kernel was entered.
pub const TrapKind = enum(u8) {
    syscall,
    page_fault,
    undefined_instruction,
    irq,
    timer,
    fault_other,
};

/// A system call as the kernel sees it, once the HAL has dug the arguments out
/// of whatever the architecture calls a trap frame. The return value goes back
/// into the caller's result register.
pub const SyscallHandler = *const fn (number: u64, a0: u64, a1: u64, a2: u64) u64;
