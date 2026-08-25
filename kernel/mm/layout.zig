//! User virtual memory layout.
//!
//! The kernel identity-maps RAM with 2 MiB pages in the low 1 TiB. User
//! mappings start at PML4/L0 index 2 so they never split a huge page.

pub const user_base: u64 = 0x0000_0100_0000_0000;
pub const code_va: u64 = user_base;
pub const stack_va: u64 = 0x0000_0100_0010_0000;
/// 512 KiB. Four pages was enough for a program that printed a line. A TLS
/// handshake parses certificates and does elliptic curve arithmetic on the
/// stack, and measured with a page fault it wanted a shade over 128 KiB, so
/// this is that with room to be wrong in. Below the region is unmapped, which
/// makes running out a fault rather than a mystery.
pub const stack_pages: usize = 128;
pub const heap_base: u64 = 0x0000_0100_4000_0000;
/// 256 MiB. Sixteen was enough for a program that fetched a page of text and
/// drew it. A document with images in it, laid out, is a different order of
/// thing, and a browser that dies at sixteen megabytes is not one. This is a
/// ceiling, not a reservation: pages arrive as `brk` asks for them.
pub const heap_max: u64 = heap_base + 256 * 1024 * 1024;
