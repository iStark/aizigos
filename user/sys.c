/* User-side implementation of the four-call seam in aizigos.h.
 *
 * Same C sources in lib/libc; this file is the second seam. The kernel
 * exports the same names from libc_port.zig for in-kernel C.
 */

#include <stddef.h>
#include <stdint.h>
#include <aizigos.h>

#define SYS_WRITE 0
#define SYS_EXIT 8
#define SYS_BRK 9
#define SYS_SURFACE_INFO 10
#define SYS_SURFACE_BLIT 11
#define SYS_HTTP_GET 12

static uint64_t call3(uint64_t n, uint64_t a0, uint64_t a1, uint64_t a2) {
#if defined(__x86_64__)
    uint64_t ret;
    __asm__ volatile("int $0x80" : "=a"(ret) : "a"(n), "D"(a0), "S"(a1), "d"(a2) : "memory", "rcx", "r11");
    return ret;
#elif defined(__aarch64__)
    register uint64_t x8 __asm__("x8") = n;
    register uint64_t x0 __asm__("x0") = a0;
    register uint64_t x1 __asm__("x1") = a1;
    register uint64_t x2 __asm__("x2") = a2;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    return x0;
#else
    (void)n;
    (void)a0;
    (void)a1;
    (void)a2;
    return 0;
#endif
}

void aizigos_write(const char *bytes, size_t length) {
    (void)call3(SYS_WRITE, (uint64_t)(uintptr_t)bytes, (uint64_t)length, 0);
}

void aizigos_exit(int status) {
    (void)call3(SYS_EXIT, (uint64_t)(unsigned)status, 0, 0);
    for (;;) {
    }
}

void aizigos_panic(const char *message) {
    size_t n = 0;
    while (message[n] != 0) n++;
    aizigos_write("\n[libc] ", 8);
    aizigos_write(message, n);
    aizigos_write("\n", 1);
    aizigos_exit(1);
}

static uintptr_t heap_cur;
static uintptr_t heap_end;

static uintptr_t sys_brk(uintptr_t value) {
    return (uintptr_t)call3(SYS_BRK, (uint64_t)value, 0, 0);
}

void *aizigos_alloc(size_t size) {
    if (size == 0) size = 1;
    size = (size + 15u) & ~(size_t)15;
    if (heap_cur == 0) {
        heap_cur = sys_brk(0);
        heap_end = heap_cur;
        if (heap_cur == 0) return NULL;
    }
    if (size > (uintptr_t)-1 - heap_cur) return NULL;
    uintptr_t need = heap_cur + size;
    if (need > heap_end) {
        uintptr_t got = sys_brk(need);
        if (got < need) return NULL;
        heap_end = got;
    }
    void *block = (void *)heap_cur;
    heap_cur += size;
    return block;
}

void *aizigos_realloc(void *pointer, size_t size) {
    if (pointer == NULL) return aizigos_alloc(size);
    if (size == 0) return NULL;
    unsigned char *block = aizigos_alloc(size);
    if (block == NULL) return NULL;
    unsigned char *src = pointer;
    size_t i = 0;
    while (i < size) {
        block[i] = src[i];
        i++;
    }
    return block;
}

void aizigos_free(void *pointer) {
    (void)pointer;
}

static uint64_t call6(uint64_t n, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5) {
#if defined(__x86_64__)
    uint64_t ret;
    register uint64_t r8 __asm__("r8") = a4;
    register uint64_t r9 __asm__("r9") = a5;
    __asm__ volatile("int $0x80"
                     : "=a"(ret)
                     : "a"(n), "D"(a0), "S"(a1), "d"(a2), "c"(a3), "r"(r8), "r"(r9)
                     : "memory", "r11");
    return ret;
#elif defined(__aarch64__)
    register uint64_t x8 __asm__("x8") = n;
    register uint64_t x0 __asm__("x0") = a0;
    register uint64_t x1 __asm__("x1") = a1;
    register uint64_t x2 __asm__("x2") = a2;
    register uint64_t x3 __asm__("x3") = a3;
    register uint64_t x4 __asm__("x4") = a4;
    register uint64_t x5 __asm__("x5") = a5;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory");
    return x0;
#else
    (void)n;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
    (void)a4;
    (void)a5;
    return 0;
#endif
}

uint64_t aizigos_surface_info(void) {
    return call3(SYS_SURFACE_INFO, 0, 0, 0);
}

uint64_t aizigos_surface_blit(const void *pixels, uint32_t w, uint32_t h, uint32_t x, uint32_t y) {
    return call6(SYS_SURFACE_BLIT, (uint64_t)(uintptr_t)pixels, w, h, x, y, 0);
}

int64_t aizigos_http_get(const char *host, size_t host_len, const char *path, size_t path_len, void *buf, size_t buf_len) {
    uint64_t r = call6(SYS_HTTP_GET, (uint64_t)(uintptr_t)host, host_len, (uint64_t)(uintptr_t)path, path_len,
                       (uint64_t)(uintptr_t)buf, buf_len);
    return (int64_t)r;
}
