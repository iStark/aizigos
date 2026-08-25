/* A failed assertion in a kernel is not recoverable, so it stops there. */

#include <assert.h>
#include <stdio.h>
#include <aizigos.h>

void aizigos_assert_failed(const char *expression, const char *file, int line) {
    char message[160];
    snprintf(message, sizeof message, "assertion failed: %s at %s:%d", expression, file, line);
    aizigos_panic(message);
}
