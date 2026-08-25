/* Memory, numbers and sorting.
 *
 * Allocation is the kernel's heap, reached through the four-call seam in
 * aizigos.h; nothing here keeps its own free lists.
 */

#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <aizigos.h>

void *malloc(size_t size) {
    void *block = aizigos_alloc(size);
    if (block == NULL) errno = ENOMEM;
    return block;
}

void *calloc(size_t count, size_t size) {
    /* Overflow here would hand back a block smaller than the caller believes,
       which is how a heap corruption starts. */
    if (count != 0 && size > (size_t)-1 / count) {
        errno = ENOMEM;
        return NULL;
    }
    size_t total = count * size;
    void *block = aizigos_alloc(total);
    if (block == NULL) {
        errno = ENOMEM;
        return NULL;
    }
    memset(block, 0, total);
    return block;
}

void *realloc(void *pointer, size_t size) {
    void *block = aizigos_realloc(pointer, size);
    if (block == NULL) errno = ENOMEM;
    return block;
}

void free(void *pointer) {
    if (pointer != NULL) aizigos_free(pointer);
}

int abs(int value) {
    return value < 0 ? -value : value;
}

long labs(long value) {
    return value < 0 ? -value : value;
}

static int digitValue(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'z') return c - 'a' + 10;
    if (c >= 'A' && c <= 'Z') return c - 'A' + 10;
    return -1;
}

long strtol(const char *text, char **end, int base) {
    const char *cursor = text;
    while (isspace((unsigned char)*cursor)) cursor++;

    int negative = 0;
    if (*cursor == '+' || *cursor == '-') {
        negative = (*cursor == '-');
        cursor++;
    }

    if ((base == 0 || base == 16) && cursor[0] == '0' &&
        (cursor[1] == 'x' || cursor[1] == 'X') && digitValue(cursor[2]) >= 0) {
        cursor += 2;
        base = 16;
    } else if (base == 0) {
        base = (cursor[0] == '0') ? 8 : 10;
    }

    long value = 0;
    int any = 0;
    for (;;) {
        int digit = digitValue(*cursor);
        if (digit < 0 || digit >= base) break;
        value = value * base + digit;
        cursor++;
        any = 1;
    }

    if (end != NULL) *end = (char *)(any ? cursor : text);
    return negative ? -value : value;
}

unsigned long strtoul(const char *text, char **end, int base) {
    return (unsigned long)strtol(text, end, base);
}

int atoi(const char *text) {
    return (int)strtol(text, NULL, 10);
}

long atol(const char *text) {
    return strtol(text, NULL, 10);
}

static void swapBytes(char *a, char *b, size_t size) {
    for (size_t i = 0; i < size; i++) {
        char scratch = a[i];
        a[i] = b[i];
        b[i] = scratch;
    }
}

/* Insertion sort below this many elements: the recursion is not worth its own
   overhead, and the arrays a parser sorts are usually short. */
#define QSORT_SMALL 12

static void sortRange(char *base, size_t count, size_t size,
                      int (*compare)(const void *, const void *)) {
    while (count > QSORT_SMALL) {
        char *pivot = base + (count / 2) * size;
        swapBytes(pivot, base, size);

        size_t boundary = 0;
        for (size_t index = 1; index < count; index++) {
            if (compare(base + index * size, base) < 0) {
                boundary++;
                swapBytes(base + index * size, base + boundary * size, size);
            }
        }
        swapBytes(base, base + boundary * size, size);

        /* Recurse into the smaller side and loop on the larger one, so the
           stack depth stays logarithmic even on sorted input. */
        if (boundary < count - boundary - 1) {
            sortRange(base, boundary, size, compare);
            base += (boundary + 1) * size;
            count -= boundary + 1;
        } else {
            sortRange(base + (boundary + 1) * size, count - boundary - 1, size, compare);
            count = boundary;
        }
    }

    for (size_t index = 1; index < count; index++) {
        for (size_t back = index; back > 0; back--) {
            if (compare(base + back * size, base + (back - 1) * size) >= 0) break;
            swapBytes(base + back * size, base + (back - 1) * size, size);
        }
    }
}

void qsort(void *base, size_t count, size_t size,
           int (*compare)(const void *, const void *)) {
    if (count > 1 && size > 0) sortRange((char *)base, count, size, compare);
}

void *bsearch(const void *key, const void *base, size_t count, size_t size,
              int (*compare)(const void *, const void *)) {
    const char *bytes = (const char *)base;
    size_t low = 0;
    size_t high = count;
    while (low < high) {
        size_t middle = low + (high - low) / 2;
        int order = compare(key, bytes + middle * size);
        if (order == 0) return (void *)(bytes + middle * size);
        if (order < 0) {
            high = middle;
        } else {
            low = middle + 1;
        }
    }
    return NULL;
}

static unsigned long random_state = 1;

int rand(void) {
    /* The constants are the ones the standard suggests; this is for shuffling
       and jitter, not for anything that matters. */
    random_state = random_state * 1103515245 + 12345;
    return (int)((random_state >> 16) & RAND_MAX);
}

void srand(unsigned int seed) {
    random_state = seed;
}

void abort(void) {
    aizigos_panic("abort() was called");
}

void exit(int status) {
    aizigos_exit(status);
}
