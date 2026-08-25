/* Proof that C code compiled by this build, linked into this kernel, running
 * on this heap, actually works. Called from the shell as `libc`.
 */

#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <ctype.h>

static int failures = 0;

static void check(int condition, const char *what) {
    if (condition) return;
    failures++;
    printf("  FAILED: %s\n", what);
}

static int compareInts(const void *left, const void *right) {
    int a = *(const int *)left;
    int b = *(const int *)right;
    return (a > b) - (a < b);
}

int aizigos_libc_selftest(void) {
    failures = 0;

    /* Strings. */
    check(strlen("aizigos") == 7, "strlen");
    check(strcmp("abc", "abc") == 0, "strcmp equal");
    check(strcmp("abc", "abd") < 0, "strcmp order");
    check(strncmp("abcdef", "abcxyz", 3) == 0, "strncmp");
    check(strcasecmp("AIZigOS", "aizigos") == 0, "strcasecmp");

    char buffer[32];
    strcpy(buffer, "hello");
    strcat(buffer, ", world");
    check(strcmp(buffer, "hello, world") == 0, "strcpy and strcat");
    check(strchr(buffer, 'w') == buffer + 7, "strchr");
    check(strstr(buffer, "world") == buffer + 7, "strstr");
    check(strstr(buffer, "worlds") == NULL, "strstr missing");

    /* Numbers. */
    check(atoi("  -42xyz") == -42, "atoi");
    check(strtol("0x1f", NULL, 0) == 31, "strtol hex");
    check(strtoul("755", NULL, 8) == 493, "strtol octal");
    check(abs(-7) == 7, "abs");

    /* Character classes. */
    check(isdigit('7') && !isdigit('x'), "isdigit");
    check(toupper('q') == 'Q' && tolower('Q') == 'q', "case folding");

    /* Formatting. */
    char formatted[64];
    int written = snprintf(formatted, sizeof formatted, "%s=%d %05u %x %c%%", "n", -3, 42, 255, 'z');
    check(strcmp(formatted, "n=-3 00042 ff z%") == 0, "snprintf");
    check(written == 16, "snprintf return value");
    snprintf(formatted, sizeof formatted, "%-6s|", "ab");
    check(strcmp(formatted, "ab    |") == 0, "snprintf padding");
    /* A buffer that is too small truncates and still terminates. */
    char tiny[5];
    snprintf(tiny, sizeof tiny, "abcdefgh");
    check(strcmp(tiny, "abcd") == 0, "snprintf truncation");

    /* The heap. */
    char *block = (char *)malloc(64);
    check(block != NULL, "malloc");
    if (block != NULL) {
        memset(block, 'x', 63);
        block[63] = '\0';
        check(strlen(block) == 63, "malloc block is writable");
        char *grown = (char *)realloc(block, 512);
        check(grown != NULL && strlen(grown) == 63, "realloc keeps contents");
        free(grown);
    }
    int *zeroed = (int *)calloc(16, sizeof(int));
    check(zeroed != NULL && zeroed[15] == 0, "calloc zeroes");
    free(zeroed);

    char *copy = strdup("duplicated");
    check(copy != NULL && strcmp(copy, "duplicated") == 0, "strdup");
    free(copy);

    /* Sorting and searching. */
    int values[] = {9, 3, 7, 1, 8, 2, 5, 4, 6, 0, 11, 10, 13, 12};
    size_t count = sizeof values / sizeof values[0];
    qsort(values, count, sizeof(int), compareInts);
    int sorted = 1;
    for (size_t index = 1; index < count; index++) {
        if (values[index - 1] > values[index]) sorted = 0;
    }
    check(sorted, "qsort");
    int wanted = 7;
    check(bsearch(&wanted, values, count, sizeof(int), compareInts) != NULL, "bsearch");

    printf("libc self test: %d check(s) failed\n", failures);
    return failures;
}
