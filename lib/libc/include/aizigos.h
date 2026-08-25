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
/* Sockets. `connect` returns a handle, or a negative kernel error code:
 * -3 denied by the capability, -5 no interface, -6 nothing answered,
 * -7 every connection in this kernel is in use. `recv` returns zero at the end
 * of the stream, which is how a reader knows to stop. */
int64_t aizigos_connect(const char *host, size_t host_len, uint16_t port);
int64_t aizigos_send(int64_t handle, const void *buf, size_t length);
int64_t aizigos_recv(int64_t handle, void *buf, size_t length);
void aizigos_close(int64_t handle);

/* Random bytes from the processor's generator. Returns the count, or a
 * negative error when this machine has none — which is a refusal, not a
 * suggestion to carry on with something worse. */
int64_t aizigos_random(void *buf, size_t length);

/* Seconds since the Unix epoch, or zero when the machine has no clock. */
uint64_t aizigos_realtime(void);

/* The command line the program was started with, copied into `buf`. Returns
 * its true length, which may be more than was copied. */
int64_t aizigos_args(char *buf, size_t length);

#endif
