# Roadmap

The order follows the dependencies: without a syscall layer there are no user
mode processes, without those there are no personality servers, without a
filesystem there is no semantic index, and without that index an AI shell is
pointless.

## Stage 1 — kernel and capabilities (done)

Spec sections 4.1 and 4.2: HAL with a contract, PMM/VMM, a scheduler with power
profiles, IPC with token checks, the audit log and the size budget audit.

## Stage 1b — it boots and you can talk to it (done)

* A third HAL target: x86_64 booted by UEFI, with the firmware handover, the GOP
  framebuffer and a text console of our own.
* `tools/mkimage.zig`: GPT + FAT32 bootable image, no external tooling.
* Console input in the HAL contract (`readKey`): PS/2, UART, or a serial line.
* An interactive shell over live kernel state: memory, tasks, power profiles,
  capabilities, audit log, grant and revoke.
* Verified by booting AArch64 and x86_64/UEFI under QEMU, which cost four real
  bugs (see the architecture document).

## Stage 2 — threads, page tables, system calls (done)

* Real preemptive context switching: threads have their own stacks, the timer
  interrupt switches between them, and the boot thread becomes the idle thread.
  The shell and a background worker are separate threads.
* Kernel page tables of our own on x86_64 under UEFI, built from the firmware
  memory map with 2 MiB pages, plus the framebuffer.
* A system call boundary: `svc`/`int 0x80`, a dispatcher, and `fs_access` that
  answers with a capability decision and records the attempt in the audit log.
* Verified on both architectures under QEMU.

## Stage 2b — user mode (done)

* A GDT with user segments and a TSS on x86, an EL0 entry path on AArch64.
* User programs mapped with user permissions above the kernel's identity map,
  entered through the privilege drop, reaching the kernel only through the
  system call gate.
* A faulting program is killed; the kernel and the shell survive it.
* Verified on both architectures: the program reports CS=0x23 / a lower-EL
  vector, and the kernel answers "privileged: no".

## Stage 2d — a pointer surface (done)

* PS/2 mouse on the auxiliary port, IRQ12 behind the cascade.
* A cursor with a backing store, a window, buttons that act on live kernel
  state, and a way back to the shell.
* Not the browser runtime: that is stage 6 and a different order of work.

## Stage 2c — one address space per process

* Switching CR3/TTBR on context switch, with the kernel mapped into every
  space, so more than one user program can run and none can see another's
  memory.
* Validating system call buffers with `AddressSpace.checkAccess` now that
  pointers arrive from another address space.
* An ELF loader for native Zig applications (FR-4.1, level 0), replacing the
  blobs compiled into the kernel.
* Waking the shell on the keyboard interrupt instead of polling.
* Battery and thermal drivers, so the governor runs on real data.
* Parsing the Multiboot2 memory map on x86_64 instead of a conservative
  constant.

Done when: two user programs run at once, each denied access to the other's
memory and to anything it holds no token for.

## Stage 3 — filesystem (section 4.3)

* FR-3.2: content-addressable block store, BLAKE3 addressing, block-level
  deduplication.
* FR-3.1: a copy-on-write tree, volume snapshots without stopping the system.
* FR-3.4: transactional change sessions with rollback.
* FR-3.5: a POSIX-compatible layer over the native API, for stage 5.
* FR-3.3: the semantic index (embeddings, tags, links) as a **background**
  service in the `background` class — it then freezes automatically in
  power_save and critical, which the scheduler already does.

The key part: filesystem access only by token; granting a token on a subtree is
already a working mechanism (`Scope.fs`).

## Stage 4 — services and drivers in user mode

The microkernel split: block devices, networking and input become separate
processes talking over IPC. A token on a device class (`Scope.device`) already
exists.

## Stage 5 — personality servers (section 4.4)

FR-4.1 (level 0) — native Zig/WASM applications with no translation: a WASM
runtime whose imports map onto capability calls. Heavier compatibility levels
come after the POSIX filesystem layer stabilises.

## Stage 6 — UI runtime and the AI shell (sections 4.5 and 5.0)

* FR-5.1: a single browser engine as the renderer for all first-party apps.
* FR-5.2: applications as PWA-like packages (manifest + assets + service
  worker), each one a directory with its own set of tokens.
* FR-5.3: "windows" as contexts/tabs managed by the AI shell.
* The interface is chat plus browser: the shell hands agents temporary tokens
  (FR-2.2) and shows the user a log panel with a revoke button (FR-2.3).

Estimate: the browser engine is the heaviest part of the project. The realistic
path is porting an existing engine as a personality server rather than writing
one.

## Open questions

1. **The kernel budget (FR-1.5)** is fixed at a 256 KiB image and is getting
   tight: the UEFI build is at 235 KiB with the pointer surface in it. Before
   the security audit we need to decide whether .bss counts against the budget,
   and whether the shell and the surface belong in the kernel image at all —
   they are the obvious first candidates to become user programs once there is
   a loader.
2. The embedding format, and where the model runs for FR-3.3: it cannot live in
   the kernel, so it needs a service holding a token on the GPU/NPU.
3. Realtime guarantees: whether a strict realtime class with priority
   inheritance is needed, or the current ageing scheme is enough.
4. Whether the shell stays a command line or becomes a chat once an agent can
   run: the parser is deliberately thin so the answer can change late.
