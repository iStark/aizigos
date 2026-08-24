# AIZigOS

A microkernel OS in pure Zig with capability-based security, a semantic
filesystem and an AI shell instead of a classic desktop.

This is **stage 1**: the kernel (spec section 4.1) and the capability
subsystem (section 4.2). The filesystem, personality servers and the browser
UI runtime are later stages — see [docs/ROADMAP.md](docs/ROADMAP.md).

## What works today

| Requirement | State |
|---|---|
| FR-1.1 priority scheduler with power profiles | implemented, 12 tests |
| FR-1.2 address space isolation | implemented (PMM + VMM + MMU on aarch64/x86_64) |
| FR-1.3 sync/async IPC with capability checks | implemented, 8 tests |
| FR-1.4 HAL with a verified contract | implemented, two targets |
| FR-1.5 kernel size budget | `zig build size-audit`, 144–151 KiB against a 256 KiB budget |
| FR-2.1 access only through a token | implemented |
| FR-2.2 tokens limited by lifetime and scope | implemented |
| FR-2.3 audit log of grants, uses and revocations | implemented |

59 unit and integration tests in total, all running on the host without QEMU.

## Building

Requires Zig 0.16.0.

```sh
zig build test                                   # kernel tests on the host HAL
zig build -Dboard=virt_aarch64 --release=small   # kernel for QEMU virt (AArch64)
zig build -Dboard=pc_x86_64    --release=small   # kernel for Multiboot2 (x86_64)
zig build size-audit -Dboard=virt_aarch64 --release=small   # FR-1.5 budget audit
zig build run -Dboard=virt_aarch64               # boot under QEMU (needs qemu-system-aarch64)
```

The budget is a flag: `-Dkernel-budget=262144`. The audit measures the loadable
image (.text + .rodata + .data), reports .bss separately — the RAM taken by the
kernel's static tables — and lists the ten largest symbols so it is obvious what
consumed the space.

Verified: both targets build and pass the audit. Booting under QEMU has not been
tried on this machine — QEMU is not installed, so the AArch64 and x86_64 startup
paths still need a run on real hardware or an emulator.

## Layout

```
kernel/
  hal/            HAL: the contract plus implementations
    contract.zig  the formal contract, verified at compile time
    aarch64/      PL011, generic timer, GICv2, MMU, exception vectors
    x86_64/       COM1, PIT/TSC, IDT+PIC, four-level page tables, Multiboot2
    host/         software implementation used by the tests
  mm/             pmm.zig (frames), vmm.zig (address spaces)
  cap/            cap.zig (tokens, attenuation, revocation), audit.zig (log)
  sched/          sched.zig (64 priorities, 4 classes), power.zig (profiles)
  ipc/            endpoints, sync/async, token delegation
  proc/           processes: address space + token ownership + threads
  main.zig        kernel assembly and initialisation
tools/size_audit.zig   the size budget audit (FR-1.5)
```

Documentation: [architecture](docs/ARCHITECTURE.md), [roadmap](docs/ROADMAP.md).
