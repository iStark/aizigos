/* First real user program: libc, a heap, a system call, then a clean exit. */

#include <stdio.h>
#include <stdlib.h>

int main(void) {
    char *block = malloc(64);
    if (block == NULL) {
        puts("malloc failed");
        return 1;
    }
    block[0] = 'o';
    block[1] = 'k';
    block[2] = '\0';
    puts("hello from /HELLO.ELF");
    puts(block);
    free(block);
    return 0;
}
