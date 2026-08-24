//! Архитектурно-независимые типы HAL.
//! Всё, что выше HAL, оперирует только этими типами (FR-1.4).

pub const PhysAddr = u64;
pub const VirtAddr = u64;

/// Права и атрибуты страничного отображения.
pub const MapFlags = packed struct(u8) {
    read: bool = true,
    write: bool = false,
    exec: bool = false,
    /// Доступно из пользовательского режима.
    user: bool = false,
    /// Device-nGnRnE / uncached MMIO.
    device: bool = false,
    /// Глобальная запись (не сбрасывается при смене ASID).
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
    /// Обычная свободная ОЗУ, отдаётся в PMM.
    usable,
    /// Занято ядром/прошивкой.
    reserved,
    /// MMIO-окно устройства.
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

/// Уровень производительности CPU (DVFS-подсказка планировщику энергопрофилей).
/// 0 — минимальная частота, 255 — максимальная.
pub const PerfLevel = u8;

pub const perf_min: PerfLevel = 0;
pub const perf_nominal: PerfLevel = 128;
pub const perf_max: PerfLevel = 255;

/// Причина входа в ядро из пользовательского режима.
pub const TrapKind = enum(u8) {
    syscall,
    page_fault,
    undefined_instruction,
    irq,
    timer,
    fault_other,
};
