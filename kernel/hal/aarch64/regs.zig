//! Доступ к системным регистрам AArch64.

pub inline fn mrs(comptime reg: []const u8) u64 {
    return asm volatile ("mrs %[out], " ++ reg
        : [out] "=r" (-> u64),
    );
}

pub inline fn msr(comptime reg: []const u8, value: u64) void {
    asm volatile ("msr " ++ reg ++ ", %[in]"
        :
        : [in] "r" (value),
        : .{ .memory = true });
}

pub inline fn isb() void {
    asm volatile ("isb" ::: .{ .memory = true });
}

pub inline fn dsb() void {
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

pub inline fn wfi() void {
    asm volatile ("wfi");
}

pub inline fn wfe() void {
    asm volatile ("wfe");
}

/// Текущий уровень исключения (EL0..EL3).
pub inline fn currentEl() u2 {
    return @truncate(mrs("CurrentEL") >> 2);
}
