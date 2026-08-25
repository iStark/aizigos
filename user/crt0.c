/* Program start-up: collect the command line, then call main.
 *
 * The kernel keeps what the program was asked to do as one line and hands it
 * over on request, rather than writing an argv onto the stack before the
 * program runs. It is the same information with a simpler contract: nothing
 * about the stack layout is load-bearing, and a program that never asks pays
 * nothing.
 */

#include <stddef.h>
#include <stdint.h>

#include "aizigos.h"

int main(int argc, char **argv);
void exit(int status);

#define ARGS_MAX 160
#define ARGV_MAX 8

static char args_buffer[ARGS_MAX + 1];
static char *argv[ARGV_MAX + 1];

/* Split the line on spaces in place. Quoting is deliberately absent: an
 * argument with a space in it is a thing to add when something needs one. */
static int build_argv(char *line, size_t length) {
    int count = 1;
    argv[0] = "program";
    size_t at = 0;
    while (at < length && count < ARGV_MAX) {
        while (at < length && line[at] == ' ') line[at++] = '\0';
        if (at >= length) break;
        argv[count++] = &line[at];
        while (at < length && line[at] != ' ') at++;
    }
    argv[count] = NULL;
    return count;
}

void _start(void) {
    const int64_t length = aizigos_args(args_buffer, ARGS_MAX);
    size_t taken = 0;
    if (length > 0) taken = (size_t)length < ARGS_MAX ? (size_t)length : ARGS_MAX;
    args_buffer[taken] = '\0';
    const int argc = build_argv(args_buffer, taken);
    exit(main(argc, argv));
}
