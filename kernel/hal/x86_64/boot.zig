//! x86_64 entry point: Multiboot2 header, 32-bit trampoline, identity
//! mapping of the first 4 GiB and the switch to long mode.

comptime {
    asm (
        \\.section .multiboot,"a",@progbits
        \\.balign 8
        \\mb_header:
        \\  .long 0xE85250D6
        \\  .long 0
        \\  .long mb_header_end - mb_header
        \\  .long -(0xE85250D6 + 0 + (mb_header_end - mb_header))
        \\  .short 0
        \\  .short 0
        \\  .long 8
        \\mb_header_end:
        \\
        \\.section .bss,"aw",@nobits
        \\.balign 4096
        \\boot_pml4: .skip 4096
        \\boot_pdpt: .skip 4096
        \\boot_pd:   .skip 4096 * 4
        \\.global aizigos_mb_info
        \\aizigos_mb_info: .skip 8
        \\
        \\.section .rodata,"a",@progbits
        \\.balign 16
        \\gdt64:
        \\  .quad 0
        \\  .quad 0x00AF9A000000FFFF
        \\  .quad 0x00AF92000000FFFF
        \\gdt64_ptr:
        \\  .short 23
        \\  .long gdt64
        \\
        \\.section .text.boot32,"ax",@progbits
        \\.code32
        \\.global _start
        \\_start:
        \\  cli
        \\  cld
        \\  movl $__stack_top, %esp
        \\  movl %ebx, %esi
        \\  movl $__bss_start, %edi
        \\  movl $__bss_end, %ecx
        \\  subl %edi, %ecx
        \\  xorl %eax, %eax
        \\  rep stosb
        \\  movl %esi, aizigos_mb_info
        \\  movl $boot_pdpt, %eax
        \\  orl  $3, %eax
        \\  movl %eax, boot_pml4
        \\  movl $boot_pd, %eax
        \\  orl  $3, %eax
        \\  xorl %ecx, %ecx
        \\1:
        \\  movl %eax, boot_pdpt(,%ecx,8)
        \\  addl $4096, %eax
        \\  incl %ecx
        \\  cmpl $4, %ecx
        \\  jb 1b
        \\  xorl %ecx, %ecx
        \\  movl $0x83, %eax
        \\  xorl %edx, %edx
        \\2:
        \\  movl %eax, boot_pd(,%ecx,8)
        \\  movl %edx, boot_pd+4(,%ecx,8)
        \\  addl $0x200000, %eax
        \\  adcl $0, %edx
        \\  incl %ecx
        \\  cmpl $2048, %ecx
        \\  jb 2b
        \\  movl $boot_pml4, %eax
        \\  movl %eax, %cr3
        \\  movl %cr4, %eax
        \\  orl  $32, %eax
        \\  movl %eax, %cr4
        \\  movl $0xC0000080, %ecx
        \\  rdmsr
        \\  orl  $256, %eax
        \\  wrmsr
        \\  movl %cr0, %eax
        \\  orl  $0x80000001, %eax
        \\  movl %eax, %cr0
        \\  lgdt gdt64_ptr
        \\  ljmp $0x08, $3f
        \\.code64
        \\3:
        \\  movw $0x10, %ax
        \\  movw %ax, %ds
        \\  movw %ax, %es
        \\  movw %ax, %fs
        \\  movw %ax, %gs
        \\  movw %ax, %ss
        \\  movabsq $__stack_top, %rsp
        \\  xorq %rbp, %rbp
        \\  callq kmain
        \\4:
        \\  hlt
        \\  jmp 4b
    );
}
