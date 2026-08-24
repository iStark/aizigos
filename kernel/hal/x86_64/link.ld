/* Multiboot2: ядро грузится по 1 МиБ */
ENTRY(_start)

SECTIONS
{
    . = 0x00100000;
    __kernel_start = .;

    .text : {
        KEEP(*(.multiboot))
        KEEP(*(.text.boot32))
        *(.text.isr)
        *(.text.ctx)
        *(.text .text.*)
    }

    . = ALIGN(4096);
    .rodata : { *(.rodata .rodata.*) }

    . = ALIGN(4096);
    .data : { *(.data .data.*) }

    . = ALIGN(4096);
    __bss_start = .;
    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    }
    . = ALIGN(8);
    __bss_end = .;

    . = ALIGN(4096);
    __stack_bottom = .;
    . += 64K;
    __stack_top = .;

    . = ALIGN(4096);
    __kernel_end = .;

    /DISCARD/ : { *(.comment) *(.note.*) *(.eh_frame*) }
}
