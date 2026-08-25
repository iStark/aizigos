/* stdlib.h — memory, numbers and sorting. */
#ifndef AIZIGOS_STDLIB_H
#define AIZIGOS_STDLIB_H

#include <stddef.h>

void *malloc(size_t size);
void *calloc(size_t count, size_t size);
void *realloc(void *pointer, size_t size);
void free(void *pointer);

int abs(int value);
long labs(long value);
int atoi(const char *text);
long atol(const char *text);
long strtol(const char *text, char **end, int base);
unsigned long strtoul(const char *text, char **end, int base);

void qsort(void *base, size_t count, size_t size, int (*compare)(const void *, const void *));
void *bsearch(const void *key, const void *base, size_t count, size_t size,
              int (*compare)(const void *, const void *));

int rand(void);
void srand(unsigned int seed);

void abort(void);
void exit(int status);

#define RAND_MAX 32767

#endif
