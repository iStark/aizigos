/* The seam between C and the kernel (or, in user mode, the system call stubs).
 *
 * Everything the C library cannot do for itself — memory, output, dying —
 * goes through these calls. Kernel and user programs share lib/libc; each
 * side supplies its own implementation of this header.
 */
#ifndef AIZIGOS_H
#define AIZIGOS_H

#include <stddef.h>
#include <stdint.h>

void *aizigos_alloc(size_t size);
void *aizigos_realloc(void *pointer, size_t size);
void aizigos_free(void *pointer);
void aizigos_write(const char *bytes, size_t length);
void aizigos_panic(const char *message);
void aizigos_exit(int status);

#include <stdint.h>
uint64_t aizigos_surface_info(void);
uint64_t aizigos_surface_blit(const void *pixels, uint32_t w, uint32_t h, uint32_t x, uint32_t y);
int64_t aizigos_http_get(const char *host, size_t host_len, const char *path, size_t path_len, void *buf, size_t buf_len);

#endif
