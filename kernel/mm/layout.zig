//! User virtual memory layout.
//!
//! The kernel identity-maps RAM with 2 MiB pages in the low 1 TiB. User
//! mappings start at PML4/L0 index 2 so they never split a huge page.

pub const user_base: u64 = 0x0000_0100_0000_0000;
pub const code_va: u64 = user_base;
pub const stack_va: u64 = 0x0000_0100_0010_0000;
pub const stack_pages: usize = 4;
pub const heap_base: u64 = 0x0000_0100_4000_0000;
pub const heap_max: u64 = heap_base + 16 * 1024 * 1024;
