/* Formatted output.
 *
 * One formatter does all the work and everything else feeds it: printf writes
 * through the kernel console, snprintf into a caller's buffer. There is no
 * file behind stdout yet, and pretending otherwise would only hide that.
 */

#include <stdio.h>
#include <string.h>
#include <aizigos.h>

struct _AIZIGOS_FILE {
    int handle;
};

static FILE console_out = {1};
static FILE console_err = {2};

FILE *stdout = &console_out;
FILE *stderr = &console_err;

/* Where a formatted string goes: a buffer, or the console when `out` is NULL. */
typedef struct {
    char *out;
    size_t limit;
    size_t written;
} Sink;

static void emit(Sink *sink, char c) {
    if (sink->out != NULL) {
        if (sink->written + 1 < sink->limit) sink->out[sink->written] = c;
    } else {
        aizigos_write(&c, 1);
    }
    sink->written++;
}

static void emitText(Sink *sink, const char *text, size_t length) {
    for (size_t index = 0; index < length; index++) emit(sink, text[index]);
}

static void emitPadding(Sink *sink, char pad, int count) {
    while (count-- > 0) emit(sink, pad);
}

static const char lower_digits[] = "0123456789abcdef";
static const char upper_digits[] = "0123456789ABCDEF";

static int formatUnsigned(char *buffer, unsigned long long value, unsigned base, int upper) {
    const char *digits = upper ? upper_digits : lower_digits;
    int length = 0;
    if (value == 0) {
        buffer[length++] = '0';
    } else {
        while (value != 0) {
            buffer[length++] = digits[value % base];
            value /= base;
        }
    }
    /* The digits came out backwards. */
    for (int index = 0; index < length / 2; index++) {
        char scratch = buffer[index];
        buffer[index] = buffer[length - 1 - index];
        buffer[length - 1 - index] = scratch;
    }
    return length;
}

int vsnprintf(char *out, size_t limit, const char *format, va_list arguments) {
    Sink sink = {out, limit, 0};

    for (const char *cursor = format; *cursor != '\0'; cursor++) {
        if (*cursor != '%') {
            emit(&sink, *cursor);
            continue;
        }
        cursor++;
        if (*cursor == '\0') break;

        int left_align = 0;
        char pad = ' ';
        while (*cursor == '-' || *cursor == '0') {
            if (*cursor == '-') left_align = 1;
            if (*cursor == '0') pad = '0';
            cursor++;
        }

        int width = 0;
        while (*cursor >= '0' && *cursor <= '9') {
            width = width * 10 + (*cursor - '0');
            cursor++;
        }

        int precision = -1;
        if (*cursor == '.') {
            cursor++;
            precision = 0;
            while (*cursor >= '0' && *cursor <= '9') {
                precision = precision * 10 + (*cursor - '0');
                cursor++;
            }
        }

        /* Length modifiers change the type read from the argument list, and
           reading the wrong width off a varargs list is silent corruption. */
        int long_count = 0;
        int size_modifier = 0;
        while (*cursor == 'l' || *cursor == 'z' || *cursor == 'h') {
            if (*cursor == 'l') long_count++;
            if (*cursor == 'z') size_modifier = 1;
            cursor++;
        }

        char digits[32];
        int length = 0;
        const char *text = digits;

        switch (*cursor) {
            case 'd':
            case 'i': {
                long long value;
                if (size_modifier) {
                    value = (long long)va_arg(arguments, size_t);
                } else if (long_count >= 2) {
                    value = va_arg(arguments, long long);
                } else if (long_count == 1) {
                    value = va_arg(arguments, long);
                } else {
                    value = va_arg(arguments, int);
                }
                int negative = value < 0;
                unsigned long long magnitude =
                    negative ? (unsigned long long)(-(value + 1)) + 1 : (unsigned long long)value;
                length = formatUnsigned(digits + 1, magnitude, 10, 0);
                if (negative) {
                    digits[0] = '-';
                    text = digits;
                    length += 1;
                } else {
                    text = digits + 1;
                }
                break;
            }
            case 'u':
            case 'x':
            case 'X': {
                unsigned long long value;
                if (size_modifier) {
                    value = va_arg(arguments, size_t);
                } else if (long_count >= 2) {
                    value = va_arg(arguments, unsigned long long);
                } else if (long_count == 1) {
                    value = va_arg(arguments, unsigned long);
                } else {
                    value = va_arg(arguments, unsigned int);
                }
                unsigned base = (*cursor == 'u') ? 10 : 16;
                length = formatUnsigned(digits, value, base, *cursor == 'X');
                text = digits;
                break;
            }
            case 'p': {
                unsigned long long value = (unsigned long long)(size_t)va_arg(arguments, void *);
                digits[0] = '0';
                digits[1] = 'x';
                length = 2 + formatUnsigned(digits + 2, value, 16, 0);
                text = digits;
                break;
            }
            case 'c': {
                digits[0] = (char)va_arg(arguments, int);
                length = 1;
                text = digits;
                break;
            }
            case 's': {
                const char *value = va_arg(arguments, const char *);
                if (value == NULL) value = "(null)";
                length = (int)(precision >= 0 ? strnlen(value, (size_t)precision) : strlen(value));
                text = value;
                break;
            }
            case '%': {
                digits[0] = '%';
                length = 1;
                text = digits;
                break;
            }
            default: {
                digits[0] = '%';
                digits[1] = *cursor;
                length = 2;
                text = digits;
                break;
            }
        }

        int padding = width - length;
        if (!left_align) emitPadding(&sink, pad, padding);
        emitText(&sink, text, (size_t)length);
        if (left_align) emitPadding(&sink, ' ', padding);
    }

    if (out != NULL && limit > 0) {
        size_t terminator = sink.written < limit ? sink.written : limit - 1;
        out[terminator] = '\0';
    }
    return (int)sink.written;
}

int snprintf(char *out, size_t limit, const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    int written = vsnprintf(out, limit, format, arguments);
    va_end(arguments);
    return written;
}

int vprintf(const char *format, va_list arguments) {
    return vsnprintf(NULL, 0, format, arguments);
}

int printf(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    int written = vsnprintf(NULL, 0, format, arguments);
    va_end(arguments);
    return written;
}

int fprintf(FILE *stream, const char *format, ...) {
    (void)stream; /* Both streams are the same console for now. */
    va_list arguments;
    va_start(arguments, format);
    int written = vsnprintf(NULL, 0, format, arguments);
    va_end(arguments);
    return written;
}

int fputs(const char *text, FILE *stream) {
    (void)stream;
    aizigos_write(text, strlen(text));
    return 0;
}

int puts(const char *text) {
    aizigos_write(text, strlen(text));
    aizigos_write("\n", 1);
    return 0;
}

int putchar(int c) {
    char byte = (char)c;
    aizigos_write(&byte, 1);
    return c;
}
