/* A small HTTP client over the kernel's sockets. See http.c for what it is
 * deliberately not. */

#ifndef AIZIGOS_HTTP_H
#define AIZIGOS_HTTP_H

#include <stddef.h>
#include <stdint.h>

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

/* The status code, or zero if the reply does not begin like one. */
int http_status(const char *reply);

#endif
