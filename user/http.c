/* HTTP/1.1, in user space, over the kernel's sockets.
 *
 * This used to be a system call: the kernel opened the connection, wrote the
 * request, read the reply and handed back a page. That put a text format
 * inside a microkernel, where it had no business being. The kernel's job is
 * the socket and the capability in front of it; parsing what comes back is
 * work like any other, and it belongs on this side of the gate.
 *
 * Deliberately small: GET, one request per connection, no chunked transfer and
 * no redirects. Those come with the engine that needs them.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <ctype.h>
#include <string.h>

#include "aizigos.h"
#include "http.h"

int64_t http_get(const char *host, const char *path, char *body, size_t cap) {
    const int64_t socket = aizigos_connect(host, strlen(host), 80);
    if (socket < 0) return socket;

    char request[512];
    const int n = snprintf(request, sizeof(request),
                           "GET %s HTTP/1.1\r\n"
                           "Host: %s\r\n"
                           "User-Agent: AIZigOS/0.2\r\n"
                           "Accept: text/html\r\n"
                           "Connection: close\r\n"
                           "\r\n",
                           path, host);
    if (n <= 0 || (size_t)n >= sizeof(request)) {
        aizigos_close(socket);
        return HTTP_TOO_LONG;
    }

    size_t sent = 0;
    while (sent < (size_t)n) {
        const int64_t wrote = aizigos_send(socket, request + sent, (size_t)n - sent);
        if (wrote < 0) {
            aizigos_close(socket);
            return wrote;
        }
        if (wrote == 0) break;
        sent += (size_t)wrote;
    }

    /* Read until the server closes. "Connection: close" is what makes that a
     * complete answer rather than a guess about where the body ends. */
    size_t filled = 0;
    while (filled + 1 < cap) {
        const int64_t got = aizigos_recv(socket, body + filled, cap - filled - 1);
        if (got < 0) {
            aizigos_close(socket);
            if (filled > 0) break; /* something arrived; keep it */
            return got;
        }
        if (got == 0) break;
        filled += (size_t)got;
    }
    body[filled] = '\0';
    aizigos_close(socket);
    return (int64_t)filled;
}

/* Declared by user/tls.zig, which is where the handshake lives. */
extern int64_t aizigos_tls_get(const char *host, const char *path, char *buf, size_t len);
extern bool aizigos_tls_verified(void);

int64_t https_get(const char *host, const char *path, char *body, size_t cap) {
    return aizigos_tls_get(host, path, body, cap);
}

bool https_verified(void) {
    return aizigos_tls_verified();
}

/* Header names are case insensitive, and this libc has no strncasecmp. */
static bool same_ignoring_case(const char *a, const char *b, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (tolower((unsigned char)a[i]) != tolower((unsigned char)b[i])) return false;
    }
    return true;
}

/* Does this reply arrive in chunks? HTTP/1.1 servers do this whenever they do
 * not know the length in advance, which for a compressed or generated page is
 * most of the time. A reader that ignores it shows the reader its chunk sizes.
 */
static bool is_chunked(const char *reply, const char *body) {
    const size_t headers = (size_t)(body - reply);
    for (size_t i = 0; i + 26 <= headers; i++) {
        if (!same_ignoring_case(reply + i, "Transfer-Encoding:", 18)) continue;
        const char *value = reply + i + 18;
        while (*value == ' ') value++;
        return same_ignoring_case(value, "chunked", 7);
    }
    return false;
}

/* Rewrite a chunked body in place as the bytes it stands for. Returns the new
 * length. Chunk extensions after a semicolon are skipped and trailers are
 * ignored: this decodes a body, it does not interpret one. */
static size_t dechunk(char *body, size_t length) {
    size_t read = 0;
    size_t write = 0;
    while (read < length) {
        char *end = NULL;
        const long size = strtol(body + read, &end, 16);
        if (end == body + read || size < 0) break;
        read = (size_t)(end - body);
        while (read < length && body[read] != '\n') read++;
        read++; /* past the newline that ends the size line */
        if (size == 0) break;
        if (read + (size_t)size > length) break;
        memmove(body + write, body + read, (size_t)size);
        write += (size_t)size;
        read += (size_t)size;
        while (read < length && (body[read] == '\r' || body[read] == '\n')) read++;
    }
    body[write] = '\0';
    return write;
}

char *http_content(char *reply, size_t length, size_t *out_length) {
    char *body = (char *)http_body(reply);
    size_t body_length = length - (size_t)(body - reply);
    if (is_chunked(reply, body)) body_length = dechunk(body, body_length);
    if (out_length) *out_length = body_length;
    return body;
}

const char *http_body(const char *reply) {
    const char *p = strstr(reply, "\r\n\r\n");
    if (p) return p + 4;
    p = strstr(reply, "\n\n");
    if (p) return p + 2;
    return reply;
}

int http_status(const char *reply) {
    if (strncmp(reply, "HTTP/1.", 7) != 0) return 0;
    const char *space = strchr(reply, ' ');
    if (space == NULL) return 0;
    return (int)strtol(space + 1, NULL, 10);
}
