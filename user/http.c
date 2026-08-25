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
