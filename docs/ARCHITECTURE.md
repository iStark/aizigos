# AIZigOS architecture (stage 1)

This document records the decisions behind spec sections 4.1 and 4.2 and how
each of them is covered by tests.

## 1. HAL and portability (FR-1.4)

The usual failure of a "portable" OS is that architecture details leak upwards.
Here that is blocked mechanically:

* `kernel/hal/contract.zig` is the formal contract. `contract.verify(impl)` runs
  in a comptime block inside `hal.zig` and checks that every required item
  exists **and has the right signature**. An implementation that drifts from the
  contract breaks the build in one understandable place instead of somewhere
  deep in the kernel.
* `kernel/hal/hal.zig` is the only module that knows about architectures at all.
  Selecting an implementation is a single `switch` on `builtin.cpu.arch`.
* Everything above the HAL imports only `hal.zig` and `hal/types.zig`.

Adding a target means a `kernel/hal/<arch>/` directory, one line in that switch
and one entry in `Board` in `build.zig`. No kernel code changes.

Interrupt handling is the telling case. Without the contract the kernel would
have to know about `vectors.on_trap` (AArch64) or `idt.on_trap` (x86). Instead
the contract has `setTrapHandler`, and the kernel installs one handler without
knowing how it is delivered. The test `hal: the trap handler is installed
through the contract` checks exactly that.

The contract surface: platform constants, console, memory map, time, timer,
interrupts, DVFS and deep idle, address spaces (`asInit`, `asMap`, `asUnmap`,
`asTranslate`, `asActivate`) and contexts (`ctxInit`, `ctxSwitch`).

Implementations:

| | aarch64 (QEMU virt) | x86_64 (Multiboot2) | x86_64 (UEFI) | host (tests) |
|---|---|---|---|---|
| console out | PL011 @0x09000000 | COM1 @0x3F8 | GOP framebuffer + COM1 | stderr |
| console in | PL011 receive FIFO | PS/2 + COM1 | PS/2 + COM1 | scripted queue |
| time | CNTPCT_EL0 | TSC calibrated against PIT ch2 | same | virtual clock |
| timer | CNTP_TVAL_EL0 | PIT ch0, IRQ0 | same | stub |
| interrupts | GICv2 + VBAR_EL1 | IDT + PIC | same, CS read at runtime | a flag |
| MMU | 4 levels, 4 KiB, ASID | 4 levels, 4 KiB, NX | firmware tables kept | model of mappings |
| memory map | hardcoded for the board | conservative constant | UEFI GetMemoryMap | fixed test map |

`readKey` is part of the contract too: a shell needs input, and what counts as a
keyboard is a platform decision — a PS/2 controller, a UART, or a queue a test
fills in.

## 2. Memory (FR-1.2)

Two layers:

* `mm/pmm.zig` is a bitmap of physical frames over the memory map from the HAL.
  Everything starts as used and only `usable` regions are freed, so MMIO and
  kernel code can never be handed to a process by accident.
* `mm/vmm.zig` is an address space: a region list plus mappings through the HAL.
  `mapAnonymous` takes frames from the PMM and owns them; `mapPhysical` maps
  memory owned elsewhere (MMIO, shared buffers) and owns no frames. `deinit`
  returns only owned frames to the PMM.

`checkAccess(va, len, need_write)` validates a user buffer on every system call:
the buffer must lie entirely inside one region, with the `user` flag and the
write right when writing.

The kernel uses no dynamic memory. Every table is static and its size counts
against the FR-1.5 budget. That is a deliberate trade: predictability and no OOM
inside the kernel, paid for with hard limits (256 tokens, 64 tasks, 32 processes
in the current `main.zig` configuration).

## 3. Scheduler (FR-1.1)

64 priority levels in four classes:

| class | levels | quantum | purpose |
|---|---|---|---|
| realtime | 0–15 | ×1 | audio, input, drivers with deadlines |
| interactive | 16–31 | ×1 | the AI shell, the UI runtime |
| normal | 32–47 | ×2 | ordinary applications |
| background | 48–63 | ×4 | indexing, deduplication, updates |

Round robin inside a level. Starvation is cured by ageing: a task waiting longer
than `aging_interval` climbs one level, but never past its class boundary — so
background work can never overtake realtime. On reaching the CPU the priority
returns to its base value.

Waking an interactive task gives it a temporary boost (`interactive_boost`): it
has just been waiting for an event, so it matters for responsiveness.

### How a switch actually happens

`sched.zig` only decides; the switch itself lives in `main.reschedule`. The
timer interrupt calls `tick`, and if the quantum ran out or a higher-priority
task became ready, `reschedule` runs *inside the interrupt handler*: the
interrupted registers are saved into the task's context and another task
continues on its own stack. When that task is scheduled again, `ctxSwitch`
returns inside its handler frame and the handler finishes with `eret`/`iretq`.

Two details are easy to get wrong and were both caught by running it:

* The interrupt controller has to be acknowledged **before** the handler may
  switch away, or the next interrupt never arrives.
* A fresh thread starts at a trampoline rather than inside a handler, so the
  trampoline unmasks interrupts itself. Otherwise the first thread to run does
  so with interrupts off forever.

The boot thread becomes the idle thread. It is not in the scheduler's tables:
control returns to it exactly when nothing else may run, which is also what
makes the `critical` profile honest — with every class forbidden, the machine
idles instead of pretending there is work.

Blocking and sleeping clear the scheduler's notion of a current task before the
switch, so the kernel tracks the *running* context separately. Getting this
wrong saved a sleeping thread's registers into the idle context and restarted
the thread from its entry point on every wake-up.

### Power profiles

A profile is a tuning table, not a separate code path:

| profile | quantum | DVFS | background | normal | deep idle |
|---|---|---|---|---|---|
| performance | 2 ms | max | yes | yes | no |
| balanced | 5 ms | nominal | yes | yes | yes |
| power_save | 12 ms | 64 | no | yes | yes |
| critical | 20 ms | min | no | no | yes |

`critical` is the power emergency mode: only realtime and interactive tasks
remain. Background semantic indexing stops on its own, with no cooperation from
applications.

The governor (`sched/power.zig`) picks a profile from the sensors with
hysteresis: emergency below 7% charge, released at 12%; throttling at 85 °C,
released at 75 °C. A manual user choice overrides the automation but not an
emergency. Profile changes reach the hardware through `hal.setPerfLevel`.

## 4. Capabilities (section 4.2)

A token is a record in a kernel registry; a process holds its identifier.

```
Capability = { id, parent, holder, issuer, object, rights, scope,
               issued_at, expires_at?, uses_left?, purpose, state }
```

* **rights** — 12 of them (`read`, `write`, `execute`, `create`, `delete`,
  `list`, `map`, `send`, `recv`, `grant`, `revoke`, `admin`).
* **scope** — `any`, a filesystem subtree, a network range (host plus ports) or
  a device class. Path prefixes compare on component boundaries:
  `/home/user/Documents` covers `…/Documents/a.txt` but not `…/Documents2`.
* **purpose** — why it was granted; visible to the user in the panel and log.

### Attenuation

`derive` is the only way to pass access on. It checks that the caller holds the
parent, has the `grant` right, and that rights are a subset of the parent's,
scope is a subset of the parent's, and the lifetime is no longer than the
parent's. A never-expiring child of an expiring parent is clamped to the
parent's deadline. The use budget is never larger than the parent's.

Revocation cascades: `revoke` kills the whole subtree. Terminating a process
revokes all of its tokens, including the ones it derived for others — delegated
access does not outlive the agent that granted it.

### The FR-2.2 scenario

The AI shell holds a root token on `/home/user`. For task X an agent receives a
derived token: `read`+`list` only, scope `/home/user/Documents`, lifetime 10
minutes, purpose "task X: assemble the report". The tests check that reading
inside the scope is allowed, `/home/user/.ssh` is `out_of_scope`, writing is
`missing_rights`, after 10 minutes it is `expired`, an early revocation makes it
`revoked` — and that all of it shows up in the log.

### Audit (FR-2.3)

A fixed-size ring log. Events: `issued`, `derived`, `used`, `denied`, `revoked`,
`expired`, `transferred`. On overflow it counts `dropped`, so the log never lies
about being complete. Queries: by holder, by token. This is the basis for the
user-facing "who was granted what" panel and for revocation.

## 5. IPC (FR-1.3)

An endpoint is an object with an owner. Every operation needs a token: `send`
requires the `send` right, `recv` and `reply` require `recv`.

* asynchronous: the message goes into the endpoint's ring queue; overflow is an
  honest `QueueFull` error (backpressure, not silent loss);
* synchronous: the sender blocks, the server answers through `reply`, the answer
  lands in a slot and the thread is woken.

A message carries up to 4 tokens. Passing them is **delegation**: the kernel
calls `derive` on the sender's behalf, so the receiver can never gain more
rights than the sender had, the transfer lands in the log, and revoking the
original kills the transferred token. Without the `grant` right a token cannot
be forwarded at all.

## 6. Kernel budget (FR-1.5)

`zig build size-audit` parses the ELF, prints the sections, the ten largest
symbols, the image size and .bss, and fails when the budget is exceeded
(256 KiB by default, `-Dkernel-budget` to change it).

Current state (ReleaseSafe): image 151 KiB (aarch64) / 144 KiB (x86_64),
.bss 271 / 295 KiB.

Two decisions were made for the sake of the budget:

1. Homegrown formatting in `klog` instead of `std.fmt`, because the standard
   formatter drags in the Io infrastructure.
2. Trimmed static tables: a 64-byte IPC payload, 8-message queues, and 32 page
   tables in the MMU pool.

## 7. System calls

A call arrives as `svc #0` on AArch64 or `int 0x80` on x86_64. The HAL is the
only part that knows this: it digs the number and arguments out of the trap
frame, calls the handler the kernel installed through `setSyscallHandler`, and
puts the result back into the caller's result register. The gate descriptor on
x86 is DPL=3 already, so user code will be able to reach it unchanged.

`syscall.zig` holds the dispatcher. The interesting call is `fs_access`: it
takes a capability id, a path and the rights being asked for, resolves the
caller's process from the running thread, and answers with the capability
decision. Allowed or denied, the attempt lands in the audit log — which is the
whole point of putting the check at this boundary rather than inside whichever
service happens to serve the request.

There is no user mode yet, so the callers are kernel threads. The shape is the
one user processes will use; when ring 3 arrives the checks are already here.

## 8. User mode

A program runs unprivileged when three things are true, and the kernel now
arranges all three.

**Segments and a trap stack.** The firmware's GDT has no ring 3 entries and no
task state segment, so `hal/x86_64/gdt.zig` builds its own: kernel code and
data, user code and data, and a TSS whose RSP0 tells the CPU which stack to
take an interrupt on when one arrives from ring 3. Getting RSP0 wrong means the
first interrupt runs on the user's stack, which is the hole ring 3 exists to
close. On AArch64 none of this is needed: SP_EL1 is already separate, and the
drop is an `eret` with SPSR set to EL0t.

**Pages the user may touch.** The program and its stack are mapped with the
user bit set, at addresses far above anything the kernel identity-maps — a
4 KiB mapping inside a region already covered by a 2 MiB kernel page would
otherwise corrupt the map, so the page walk now refuses to descend into a huge
page rather than treating it as a table.

**A single door back in.** The syscall gate is DPL=3; everything else is DPL=0.
The program can call `write`, `yield`, `fs_access` and the rest, and can do
nothing else to the kernel.

The evidence that it works is the program itself: it asks the kernel to report
its privilege level, and the kernel answers from the trap frame — CS=0x23 on
x86_64, a lower-EL vector on AArch64, "privileged: no" on both.

The other half is what happens when a program misbehaves. `user fault` runs a
variant that writes to kernel memory on purpose; the hardware faults, and the
kernel kills that thread instead of stopping the machine. The shell is still
answering afterwards, which is the whole point of the boundary.

What is still missing: each process should have its own address space. Today
user programs share the kernel's, mapped at one fixed address, so exactly one
can run at a time — starting a second would rewrite the code the first is
executing. The kernel refuses instead.

## 9. Booting

Two paths, both in the repository.

**AArch64** is loaded by QEMU at 0x40080000 and starts at `_start`: park the
secondary cores, set the stack, zero .bss, call `kmain`.

**x86_64** boots as a UEFI application. There is no separate loader: the kernel
*is* `/EFI/BOOT/BOOTX64.EFI`, so the firmware does the loading, and Zig can
target PE directly. `hal/uefi_x86_64/boot.zig` then, in this order:

1. claims the GOP framebuffer while boot services are still alive, so a failure
   can still be reported through the firmware console;
2. reads the memory map into a static buffer;
3. calls ExitBootServices and never talks to the firmware again.

From that moment the kernel owns the machine: its own IDT, its own PIC/PIT
programming, its own text console drawing 8x8 glyphs into the framebuffer.

`tools/mkimage.zig` builds the disk image itself — protective MBR, GPT with one
ESP, a FAT32 volume, and the loader written into it. That is a few hundred lines
against a dependency on GRUB, xorriso and mtools, none of which exist on a plain
Windows machine.

## 10. What running it on hardware changed

The first boot found four bugs that no host test could have caught, which is the
argument for booting early rather than building more layers first.

* **AArch64 faulted on the first formatted log line.** With the MMU off, the CPU
  treats all memory as Device, where unaligned access is illegal — and the
  compiler emits unaligned stores freely. The MMU is not an optimisation on this
  architecture, it is a prerequisite; `enableMmu` now identity-maps RAM and MMIO
  with 2 MiB blocks before anything else runs.
* **The AArch64 vector table was silently wrong.** Each slot is exactly 128
  bytes, and a full register save does not fit, so the assembler pushed the next
  handler past its slot and the CPU jumped into the middle of the previous one.
  Slots now hold a four-instruction stub that jumps to a shared tail.
* **The x86 interrupt frame was off by one slot.** The common handler read the
  vector number where the error code lives, so every interrupt was misclassified.
* **The IDT used a hardcoded code selector.** 0x08 is what a Multiboot kernel
  builds for itself, but UEFI hands over its own GDT; the first interrupt turned
  into a triple fault. The selector is now read from CS at init.

## 11. Deliberately out of scope for this stage

* Per-process address spaces. They exist in the HAL and in the tests, but the
  kernel does not switch to them yet, so all user programs share the kernel's
  space at one fixed address and only one may run at a time.
* Loading programs: there is no ELF loader, so every program is a blob compiled
  into the kernel.
* The shell polls the keyboard on a 5 ms timer instead of waking on its
  interrupt. It sleeps rather than spins, so it does not starve anything, but a
  keystroke can wait a few milliseconds longer than it should.
* SMP: the HAL has `max_cpus`, but secondary cores are parked.
