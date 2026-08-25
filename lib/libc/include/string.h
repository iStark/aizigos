/* string.h — the subset a C library needs to be worth having.
 *
 * memcpy, memset, memmove and memcmp are not declared here as ours: the Zig
 * toolchain already emits them for a freestanding target, and defining them
 * twice is a link error rather than a kindness.
 */
#ifndef AIZIGOS_STRING_H
#define AIZIGOS_STRING_H

#include <stddef.h>

void *memcpy(void *destination, const void *source, size_t length);
void *memmove(void *destination, const void *source, size_t length);
void *memset(void *destination, int value, size_t length);
int memcmp(const void *left, const void *right, size_t length);
void *memchr(const void *haystack, int needle, size_t length);

size_t strlen(const char *text);
size_t strnlen(const char *text, size_t limit);
char *strcpy(char *destination, const char *source);
char *strncpy(char *destination, const char *source, size_t limit);
char *strcat(char *destination, const char *source);
char *strncat(char *destination, const char *source, size_t limit);
int strcmp(const char *left, const char *right);
int strncmp(const char *left, const char *right, size_t limit);
int strcasecmp(const char *left, const char *right);
char *strchr(const char *text, int c);
char *strrchr(const char *text, int c);
char *strstr(const char *haystack, const char *needle);
size_t strspn(const char *text, const char *accept);
size_t strcspn(const char *text, const char *reject);
char *strdup(const char *text);

#endif
