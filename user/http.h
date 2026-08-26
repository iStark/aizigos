/* A small HTTP client over the kernel's sockets. See http.c for what it is
 * deliberately not. */

#ifndef AIZIGOS_HTTP_H
#define AIZIGOS_HTTP_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

/* Errors are negative. Kernel failures come through unchanged (-3 denied, -5
 * no interface, -6 nothing answered, -7 no free connection); this one is ours.
 */
#define HTTP_TOO_LONG (-100)

/* Fetch http://host/path into `body`, NUL terminated. Returns the number of
 * bytes read, headers included, or a negative error. */
int64_t http_get(const char *host, const char *path, char *body, size_t cap);

/* The start of the body within a reply, or the whole thing if no blank line
 * separates the headers. */
const char *http_body(const char *reply);

/* The body, decoded. HTTP/1.1 servers send chunked bodies whenever they do not
 * know the length in advance, and a reader that ignores that shows its reader
 * the chunk sizes. Rewrites the reply in place and reports the body length. */
char *http_content(char *reply, size_t length, size_t *out_length);

/* The status code, or zero if the reply does not begin like one. */
int http_status(const char *reply);

/* The same over TLS, implemented in user/tls.zig with Zig's own TLS 1.3
 * client. Errors below -100 are its own: -110 no entropy, -111 no clock,
 * -112 the handshake failed, -113/-114 the stream broke, -115 the request was
 * too long for its buffer. */
int64_t https_get(const char *host, const char *path, char *body, size_t cap);

/* If the reply is a redirect, write where it points into `out` and return
 * true. Absolute addresses are taken as they are; a bare path keeps the host
 * and the scheme it came from. */
bool http_redirect(const char *reply, const char *host, bool secure, char *out, size_t cap);

/* Whether the last TLS connection authenticated the server. It does not yet:
 * the traffic is encrypted, and nothing checks the certificate belongs to the
 * host that presented it. Callers are expected to say so out loud. */
bool https_verified(void);

#endif
