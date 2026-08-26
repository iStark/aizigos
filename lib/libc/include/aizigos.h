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

/* Files on the boot volume, read only, each opening checked against the
 * capability the process holds. Negative results are kernel error codes. */
int64_t aizigos_open(const char *path, size_t length);
int64_t aizigos_read(int64_t handle, void *buf, size_t length);
int64_t aizigos_seek(int64_t handle, int64_t offset, int whence);
int64_t aizigos_file_size(int64_t handle);
void aizigos_file_close(int64_t handle);

#define AIZIGOS_SEEK_SET 0
#define AIZIGOS_SEEK_CUR 1
#define AIZIGOS_SEEK_END 2

/* A rectangle of the screen, and the input that lands in it. The shell hands
 * it over and takes it back when the program ends or the user presses Escape.
 */
/* Give up the processor for a while. A program with an event loop that never
 * sleeps is a program that starves everything else on the machine. */
void aizigos_sleep_ms(uint64_t ms);

int64_t aizigos_surface_grab(uint32_t x, uint32_t y, uint32_t w, uint32_t h);
void aizigos_surface_release(void);

/* The next event, or zero when nothing is waiting. */
uint64_t aizigos_surface_event(void);

#define AIZIGOS_EVENT_NONE 0
#define AIZIGOS_EVENT_KEY 1
#define AIZIGOS_EVENT_MOVE 2
#define AIZIGOS_EVENT_PRESS 3
#define AIZIGOS_EVENT_RELEASE 4
#define AIZIGOS_EVENT_CLOSED 5
#define AIZIGOS_EVENT_MOVED 6
#define AIZIGOS_EVENT_HIDDEN 7
#define AIZIGOS_EVENT_SHOWN 8

#define AIZIGOS_EVENT_KIND(e) ((int)((e) & 0xFF))
#define AIZIGOS_EVENT_KEY_BYTE(e) ((int)(((e) >> 8) & 0xFF))
#define AIZIGOS_EVENT_BUTTONS(e) ((int)(((e) >> 16) & 0xFF))
#define AIZIGOS_EVENT_X(e) ((int)(((e) >> 32) & 0xFFFF))
#define AIZIGOS_EVENT_Y(e) ((int)(((e) >> 48) & 0xFFFF))

/* The command line the program was started with, copied into `buf`. Returns
 * its true length, which may be more than was copied. */
int64_t aizigos_args(char *buf, size_t length);

#endif
