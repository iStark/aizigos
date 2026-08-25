/* stdio.h — formatted output only.
 *
 * There is no filesystem behind this yet, so there are no files: stdout and
 * stderr both reach the kernel console, and anything else is absent rather
 * than stubbed out to fail quietly.
 */
#ifndef AIZIGOS_STDIO_H
#define AIZIGOS_STDIO_H

#include <stddef.h>
#include <stdarg.h>

typedef struct _AIZIGOS_FILE FILE;

extern FILE *stdout;
extern FILE *stderr;

int printf(const char *format, ...);
int vprintf(const char *format, va_list arguments);
int fprintf(FILE *stream, const char *format, ...);
int snprintf(char *out, size_t limit, const char *format, ...);
int vsnprintf(char *out, size_t limit, const char *format, va_list arguments);
int puts(const char *text);
int fputs(const char *text, FILE *stream);
int putchar(int c);

#endif
