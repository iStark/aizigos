/* String handling.
 *
 * The block operations (memcpy and friends) are not here: the Zig toolchain
 * emits them for a freestanding target already.
 */

#include <string.h>
#include <stdlib.h>

size_t strlen(const char *text) {
    size_t length = 0;
    while (text[length] != '\0') length++;
    return length;
}

size_t strnlen(const char *text, size_t limit) {
    size_t length = 0;
    while (length < limit && text[length] != '\0') length++;
    return length;
}

char *strcpy(char *destination, const char *source) {
    char *out = destination;
    while ((*out++ = *source++) != '\0') {}
    return destination;
}

char *strncpy(char *destination, const char *source, size_t limit) {
    size_t index = 0;
    while (index < limit && source[index] != '\0') {
        destination[index] = source[index];
        index++;
    }
    /* The standard pads the rest with zeroes, and code in the wild relies on
       it more often than it relies on the truncation. */
    while (index < limit) destination[index++] = '\0';
    return destination;
}

char *strcat(char *destination, const char *source) {
    strcpy(destination + strlen(destination), source);
    return destination;
}

char *strncat(char *destination, const char *source, size_t limit) {
    char *end = destination + strlen(destination);
    size_t index = 0;
    while (index < limit && source[index] != '\0') {
        end[index] = source[index];
        index++;
    }
    end[index] = '\0';
    return destination;
}

int strcmp(const char *left, const char *right) {
    while (*left != '\0' && *left == *right) {
        left++;
        right++;
    }
    return (int)(unsigned char)*left - (int)(unsigned char)*right;
}

int strncmp(const char *left, const char *right, size_t limit) {
    size_t index = 0;
    while (index < limit) {
        unsigned char a = (unsigned char)left[index];
        unsigned char b = (unsigned char)right[index];
        if (a != b) return (int)a - (int)b;
        if (a == '\0') return 0;
        index++;
    }
    return 0;
}

static char foldCase(char c) {
    return (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
}

int strcasecmp(const char *left, const char *right) {
    while (*left != '\0' && foldCase(*left) == foldCase(*right)) {
        left++;
        right++;
    }
    return (int)(unsigned char)foldCase(*left) - (int)(unsigned char)foldCase(*right);
}

char *strchr(const char *text, int c) {
    const char wanted = (char)c;
    while (*text != '\0') {
        if (*text == wanted) return (char *)text;
        text++;
    }
    return wanted == '\0' ? (char *)text : NULL;
}

char *strrchr(const char *text, int c) {
    const char wanted = (char)c;
    const char *found = NULL;
    while (*text != '\0') {
        if (*text == wanted) found = text;
        text++;
    }
    if (wanted == '\0') return (char *)text;
    return (char *)found;
}

char *strstr(const char *haystack, const char *needle) {
    if (*needle == '\0') return (char *)haystack;
    for (; *haystack != '\0'; haystack++) {
        const char *a = haystack;
        const char *b = needle;
        while (*a != '\0' && *a == *b) {
            a++;
            b++;
        }
        if (*b == '\0') return (char *)haystack;
    }
    return NULL;
}

size_t strspn(const char *text, const char *accept) {
    size_t length = 0;
    while (text[length] != '\0' && strchr(accept, text[length]) != NULL) length++;
    return length;
}

size_t strcspn(const char *text, const char *reject) {
    size_t length = 0;
    while (text[length] != '\0' && strchr(reject, text[length]) == NULL) length++;
    return length;
}

char *strdup(const char *text) {
    size_t length = strlen(text);
    char *copy = (char *)malloc(length + 1);
    if (copy == NULL) return NULL;
    memcpy(copy, text, length + 1);
    return copy;
}
