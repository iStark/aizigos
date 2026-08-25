/* The seam between C and the kernel.
 *
 * Everything the C library cannot do for itself — memory, output, dying —
 * goes through these four calls, which the kernel exports from Zig. A C
 * library that needs a fifth one is a C library that needs a conversation.
 */
#ifndef AIZIGOS_H
#define AIZIGOS_H

#include <stddef.h>

void *aizigos_alloc(size_t size);
void *aizigos_realloc(void *pointer, size_t size);
void aizigos_free(void *pointer);
void aizigos_write(const char *bytes, size_t length);
void aizigos_panic(const char *message);

#endif
