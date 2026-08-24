//! AArch64 entry point (QEMU -M virt, EL1, MMU off).

comptime {
    asm (
        \\.section .text.boot,"ax",@progbits
        \\.global _start
        \\_start:
        \\  mrs  x0, mpidr_el1
        \\  and  x0, x0, #0xFF
        \\  cbz  x0, .Lprimary
        \\.Lpark:
        \\  wfe
        \\  b    .Lpark
        \\.Lprimary:
        \\  adrp x0, __stack_top
        \\  add  x0, x0, :lo12:__stack_top
        \\  mov  sp, x0
        \\  adrp x0, __bss_start
        \\  add  x0, x0, :lo12:__bss_start
        \\  adrp x1, __bss_end
        \\  add  x1, x1, :lo12:__bss_end
        \\.Lbss:
        \\  cmp  x0, x1
        \\  b.hs .Lbss_done
        \\  str  xzr, [x0], #8
        \\  b    .Lbss
        \\.Lbss_done:
        \\  mov  x29, xzr
        \\  mov  x30, xzr
        \\  bl   kmain
        \\.Lhang:
        \\  wfi
        \\  b    .Lhang
    );
}
