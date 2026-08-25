/* First real user program: libc, a heap, arguments, a system call, a clean
 * exit. Everything it prints, it prints from user mode through the gate. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    char *block = malloc(64);
    if (block == NULL) {
        puts("malloc failed");
        return 1;
    }
    strcpy(block, "ok");
    puts("hello from /HELLO.ELF");
    puts(block);
    free(block);

    /* The arguments, printed back, so that "it was told something" and "it
     * received it" are not the same claim taken on trust. */
    printf("argc %d\n", argc);
    for (int i = 0; i < argc; i++) printf("  argv[%d] = %s\n", i, argv[i]);
    return 0;
}
