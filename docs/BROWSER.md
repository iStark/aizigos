# Getting to a browser

What stands between the system as it is today and a window showing a page from
the internet. Written in the order the work has to happen, because most of it
is prerequisites rather than browser code.

## The one structural decision

**The browser cannot live inside the kernel.** FR-1.5 gives the kernel a size
budget so it can be audited — 384 KiB, of which the UEFI board currently has
40 KiB to spare. NetSurf with its libraries, a TLS stack and a font rasteriser
is several megabytes. Linking it in would not overrun the budget so much as
make the budget meaningless.

So the browser is a program: a file on the volume, loaded into its own address
space, talking to the kernel only through system calls, holding capabilities
for exactly the hosts it may reach and the files it may read. That is what the
microkernel was for, and it is why the first third of this plan is about
loading programs rather than about rendering pages.

The same conclusion in one line: **before the browser, the platform.**

---

## Stage B0 — a platform a real program can run on

Today a "user program" is a blob of position-independent assembly baked into
the kernel image, and the system call surface is eight calls: write, yield,
sleep, time, fs\_access, report, audit\_len, task\_id. Neither survives contact
with a program that has a heap, opens files and draws.

| Piece | What it is | Size |
| --- | --- | --- |
| One address space per process | Roadmap stage 2c, still open. `hal` already has the address-space methods; processes need to own one, and the switch needs to happen on the context switch. | M |
| ELF64 loader | Read the program off FAT32, map its segments with the right permissions, set up the stack and the entry point. No dynamic linking: static binaries only, which is a decision and not a limitation. | M |
| Memory system calls | **Done.** `brk`, with a ceiling of 256 MiB rather than 16, and address-space regions that merge so a heap grown in steps stays one region. | M |
| File system calls | **Done.** `open`, `read`, `seek`, `size`, `close`; each opening checked against the capability, each handle owned by the process that opened it and released when it dies. | S |
| Socket system calls | `connect`/`send`/`recv`/`close`, checked against the net token's host and port range. Depends on stage B2. | M |
| Surface system calls | **Done.** `grab`, `event`, `release`, `blit`: the shell hands over a rectangle and the input that lands in it, in the program's own coordinates, and Escape always comes back to the shell. | M |
| User-side libc | `lib/libc` already compiles; it needs a `crt0` and backends that call into the kernel instead of into `libc_port.zig`. Same sources, second seam. | S |

**Proof it works:** a C program built from `lib/libc`, written to the image by
`zig build image`, loaded from `/BIN/HELLO.ELF`, printing through a system
call, allocating from its own heap, and dying without taking anything with it.

---

## Stage B1 — arithmetic

Every board currently builds with floating point removed from the target:
`soft_float` added, `x87`, `sse`, `sse2` and `neon` subtracted. That was the
right call for a kernel that saves no FP state on a context switch, and it is
the wrong call for a font rasteriser.

| Piece | What it is | Size |
| --- | --- | --- |
| FP for user mode | Enable SSE on x86 (CR0.MP, clear CR0.EM, CR4.OSFXSR and OSXMMEXCPT) and FPEN in CPACR\_EL1 on aarch64. Save and restore with `fxsave`/`fxrstor` and the q registers, **per process, lazily**: trap the first FP instruction, save the previous owner's state, hand the unit over. The kernel itself stays free of floating point, so the budget and the interrupt path are unaffected. | M |
| libm subset | `sqrt`, `pow`, `exp`, `log`, `fabs`, `floor`, `ceil`, `fmod`, `sin`, `cos`, `atan2`, `ldexp`, `strtod`. Not a full libm — the list of what the engine actually calls, implemented and tested against known values. | M |

**Proof it works:** a user program computing a float-heavy loop across a
hundred context switches and getting the same answer as the host does, with a
second process doing the same thing at the same time.

---

## Stage B2 — the network a browser needs

The stack today is honest but small: Ethernet, ARP, IPv4, ICMP, no I/O of its
own, all testable. A browser needs four more layers on top, and the third one
is the largest single piece of work in this plan.

| Piece | What it is | Size |
| --- | --- | --- |
| UDP | A hundred lines on top of what IPv4 already does. | S |
| DNS | A resolver: query, parse the answer, cache with the TTL the record carries. Names come from the user, so the parser has to be careful about compression pointers and loops. | M |
| DHCP | Optional at first: QEMU's user network hands out a fixed address, and the stack already assumes 10.0.2.15. Needed for real hardware. | S |
| **TCP** | Connection state machine, sequence numbers, retransmission with backoff, receive and send windows, delayed acknowledgement, RTT estimation, and closing properly in both directions. Testable on the host against a synthetic peer, which is how the rest of the stack was built. | **L** |
| Sockets under capabilities | FR-2.1 applies: a process connects through a token that names the host and port range, and every connection is an audit record. The mechanism exists (`Scope.net`); it needs to sit in front of the socket calls. | S |
| HTTP/1.1 | Request, response, headers, chunked transfer, redirects, keep-alive, and enough content negotiation to be sent HTML rather than an error page. | M |
| TLS 1.3 | **Done, except verification.** Zig's own `std.crypto.tls` client runs in user space over the socket calls; the kernel supplies entropy from RDRAND and the date from the CMOS. What remains is the certificate store: a CA bundle on the volume, and `Certificate.Bundle` wants an allocator and a `std.Io`, neither of which exists here yet. Until then every connection is encrypted and unauthenticated, and says so on screen. | **M** |

**Proof it works:** `get http://example.com/` in the shell printing real HTML
off the real internet, then the same over HTTPS, with the audit log showing the
token that allowed it. Both work today; the remaining piece of this stage is
certificate verification.

---

## Stage B3 — pixels and text

The desktop draws with an 8x8 bitmap font and solid rectangles. A page needs
proportional text at several sizes, alpha blending and images.

| Piece | What it is | Size |
| --- | --- | --- |
| Plotting | **Done.** Back buffer, an intersecting clip so nesting is safe, alpha blending, lines, scaled bitmaps and glyph coverage — shaped like the plotter table an engine expects. | M |
| Font rasteriser | **Done, and written rather than ported.** cmap format 4, quadratic outlines, a four-by-four supersample. No hinting, no kerning, no shaping. The face is a file on the volume, placed by the build from the host. | M |
| Text measurement | **Done** for advances, which is what wrapping needs. Kerning and a glyph cache are still to come, and the cache will matter first. | S |
| Image decoding | **PNG done**, inflate and all five filters included, colour types 0/2/3/4/6 at eight bits. Not interlaced, not sixteen bit, no JPEG or GIF yet. | S |

**Proof it works:** a page of real text in a real typeface, scrolling smoothly,
with a photograph on it.

---

## Stage B4 — the engine

Two routes, and the honest answer is to walk both in order.

### B4a — the walking skeleton (recommended first)

A minimal viewer of our own: an HTML tokeniser, a box tree with block and
inline layout, a handful of CSS properties, and paint through stage B3. Perhaps
2000 lines of Zig. It will not render the modern web and is not meant to. What
it does is prove the whole path — fetch, parse, lay out, paint, scroll, follow
a link — while the pieces underneath it are still young enough to change
cheaply. Every mistake in the surface protocol, the fetch API and the plotter
table shows up here, where fixing it costs an afternoon rather than a port.

### B4b — NetSurf

The engine the specification asks for in FR-5.1, in dependency order. Each is
a C library that builds against the libc from stage B0 once its gaps are
filled:

1. **libwapcaplet** — string interning. Small, no dependencies. First because
   everything else uses it, and because it is the honest test of whether the
   libc is ready.
2. **libparserutils** — input streams and character encodings. Wants an iconv;
   the built-in UTF-8 and 8859 support covers most of the web, and the rest can
   arrive later.
3. **libhubbub** — the HTML5 tokeniser and tree builder.
4. **libdom** — the document model.
5. **libcss** — parsing and selection. Uses fixed-point arithmetic internally,
   which is a relief.
6. **libnsutils**, **libnslog**, **libnsgif**, **libnsbmp**, **libnspsl** —
   the small ones.
7. **NetSurf core** — content handling, the box tree, layout, rendering.
8. **The front end** — ours. A fetcher over stage B2 instead of libcurl, a
   plotter table over stage B3, a font handler over the rasteriser, an event
   loop, a scheduler for the engine's callbacks, and the `about:` resources as
   files on the volume.

The front end is where the work is: perhaps 2500 lines, all of it against
interfaces that stage B4a will already have exercised.

---

## Stage B5 — a browser that belongs to this system

FR-5.1 says one engine renders every first-party application, FR-5.2 asks for
PWA-like packages, and FR-5.3 says windows are contexts the AI shell manages.
That changes what gets built here: not a browser with a toolbar, but a renderer
the shell hands documents to.

| Piece | What it is | Size |
| --- | --- | --- |
| Tabs as shell contexts | The shell owns the list; the browser renders what it is given. Closing a tab is the shell revoking a context. | M |
| App packages | A manifest, a folder on the volume, and a capability set granted at install time and visible in `caps`. An application is then a folder the AI can open, which is section 5.0's whole idea. | M |
| The agent's side | "открой example.com", "найди в этой странице", "прочитай мне её" — intents on top of the same recogniser, and Ascora replacing the phrase table without any of the plumbing changing. | S |

---

## Order, and what it costs

```
B0 platform ──┬─→ B1 arithmetic ──┐
              │                   ├─→ B3 pixels ──┐
              └─→ B2 network ─────┘               ├─→ B4a skeleton ─→ B4b NetSurf ─→ B5 shell
                       └── TCP, TLS ──────────────┘
```

B0 and B2 can proceed in parallel: nothing in the network stack depends on the
program loader, and the walking skeleton needs both. B1 is small but must land
before B3. The two long poles are **TCP** and **TLS**, and neither has a
shortcut worth taking — a browser that cannot open an HTTPS page is a demo.

The soonest honest milestone is a page from the internet, over plain HTTP, in a
window, rendered by our own skeleton: that needs B0, B1, B2 through HTTP, B3
and B4a. NetSurf then replaces the skeleton without disturbing anything below
it, which is the point of building it in that order.

## Decisions to take before starting

1. **The browser as a separate program, in user mode** — this plan assumes it,
   because FR-1.5 leaves no other choice. It is worth saying out loud, because
   it makes stage B0 non-optional and it is the largest change of direction
   here.
2. **TLS: Zig or C.** `std.crypto.tls` keeps the promise of a system in pure
   Zig and is one fewer C dependency to keep. BearSSL is proven in exactly this
   kind of place. This can be decided at stage B2 and not before.
3. **How far the walking skeleton goes.** It could stop at "it proved the
   interfaces" or grow into the engine for first-party applications, with
   NetSurf reserved for the open web. The second is more work and more ours.
4. **Fonts.** Which faces ship on the volume, and whether they are subset.
   Affects the image size more than anything else in this plan.
