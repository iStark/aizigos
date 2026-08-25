/* Walking skeleton: fetch a page, strip tags, paint text through the plotter. */

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <aizigos.h>
#include "font8x8.h"
#include "http.h"

#define PAGE_W 720
#define PAGE_H 480
#define MARGIN 16
#define LINE_H 16

static uint32_t *pixels;
static char page[8192];

static void fill(uint32_t colour) {
    size_t i;
    for (i = 0; i < PAGE_W * PAGE_H; i++) pixels[i] = colour;
}

static void put(int x, int y, uint32_t colour) {
    if (x < 0 || y < 0 || x >= PAGE_W || y >= PAGE_H) return;
    pixels[y * PAGE_W + x] = colour;
}

static void glyph(int x, int y, char ch, uint32_t colour) {
    unsigned idx = (unsigned char)ch;
    if (idx < 32 || idx > 126) idx = '?';
    const unsigned char *rows = font8x8[idx - 32];
    int row, col;
    for (row = 0; row < 8; row++) {
        unsigned char bits = rows[row];
        for (col = 0; col < 8; col++) {
            if ((bits >> (7 - col)) & 1) put(x + col, y + row, colour);
        }
    }
}

static void draw_text(int x, int y, const char *text, uint32_t colour) {
    int cx = x;
    int cy = y;
    while (*text) {
        if (*text == '\n' || cx + 8 > PAGE_W - MARGIN) {
            cx = MARGIN;
            cy += LINE_H;
            if (*text == '\n') {
                text++;
                continue;
            }
        }
        if (cy + 8 >= PAGE_H) return;
        glyph(cx, cy, *text, colour);
        cx += 8;
        text++;
    }
}

/* Pull visible text out of a cheap HTML token stream. Headings get a mark. */
static void layout_html(const char *html, char *out, size_t cap) {
    size_t o = 0;
    int in_tag = 0;
    int skip = 0;
    int heading = 0;
    while (*html && o + 2 < cap) {
        if (*html == '<') {
            in_tag = 1;
            heading = 0;
            if ((html[1] == 'h' || html[1] == 'H') && html[2] >= '1' && html[2] <= '6') heading = 1;
            if ((html[1] == 's' || html[1] == 'S') && (html[2] == 'c' || html[2] == 'C')) skip = 1;
            if ((html[1] == 's' || html[1] == 'S') && (html[2] == 't' || html[2] == 'T')) skip = 1;
            if (html[1] == '/' && skip) skip = 0;
            if ((html[1] == 'p' || html[1] == 'P' || html[1] == 'd' || html[1] == 'D' ||
                 html[1] == 'l' || html[1] == 'L' || html[1] == 't' || html[1] == 'T') &&
                o > 0 && out[o - 1] != '\n') {
                out[o++] = '\n';
            }
            html++;
            continue;
        }
        if (*html == '>') {
            in_tag = 0;
            if (heading && o + 2 < cap) {
                out[o++] = '\n';
            }
            html++;
            continue;
        }
        if (in_tag || skip) {
            html++;
            continue;
        }
        char c = *html++;
        if (c == '&') {
            while (*html && *html != ';') html++;
            if (*html == ';') html++;
            if (o + 1 < cap) out[o++] = ' ';
            continue;
        }
        if (c == '\r' || c == '\n' || c == '\t') c = ' ';
        if (c == ' ' && o > 0 && out[o - 1] == ' ') continue;
        out[o++] = c;
    }
    out[o] = 0;
}

/* Split "http://host/path" into its two halves. The scheme is required and
 * only http:// exists so far: there is no TLS yet, and pretending otherwise
 * would fail later and less clearly. */
static int split_url(const char *url, char *host, size_t host_cap, char *path, size_t path_cap) {
    const char *rest = url;
    if (strncmp(rest, "http://", 7) == 0) {
        rest = url + 7;
    } else if (strncmp(rest, "https://", 8) == 0) {
        return -1;
    }

    size_t i = 0;
    while (rest[i] && rest[i] != '/' && i + 1 < host_cap) {
        host[i] = rest[i];
        i++;
    }
    if (i == 0) return -1;
    host[i] = '\0';

    const char *tail = rest + i;
    if (*tail != '/') tail = "/";
    size_t j = 0;
    while (tail[j] && j + 1 < path_cap) {
        path[j] = tail[j];
        j++;
    }
    path[j] = '\0';
    return 0;
}

int main(int argc, char **argv) {
    const char *url = argc > 1 ? argv[1] : "http://example.com/";
    char host[128];
    char path[192];

    pixels = aizigos_alloc((size_t)PAGE_W * PAGE_H * 4);
    if (pixels == 0) {
        aizigos_write("view: no pixels\n", 16);
        return 1;
    }
    fill(0xF4F1EA);
    draw_text(MARGIN, MARGIN, url, 0x1A3650);

    if (split_url(url, host, sizeof(host), path, sizeof(path)) != 0) {
        draw_text(MARGIN, MARGIN + 24, "only http:// addresses, no TLS yet", 0xA11D1D);
    } else {
        int64_t n = http_get(host, path, page, sizeof(page));
        if (n < 0) {
            char why[64];
            snprintf(why, sizeof(why), "fetch failed: error %d", (int)-n);
            draw_text(MARGIN, MARGIN + 24, why, 0xA11D1D);
            aizigos_write(why, strlen(why));
            aizigos_write("\n", 1);
        } else {
            char text[4096];
            const int status = http_status(page);
            if (status != 0 && status != 200) {
                char note[64];
                snprintf(note, sizeof(note), "the server answered %d", status);
                draw_text(MARGIN, MARGIN + 24, note, 0xA11D1D);
            } else {
                layout_html(http_body(page), text, sizeof(text));
                draw_text(MARGIN, MARGIN + 24, text, 0x1B1B1B);
            }
        }
    }

    uint64_t info = aizigos_surface_info();
    uint32_t sw = (uint32_t)info;
    uint32_t sh = (uint32_t)(info >> 32);
    uint32_t x = sw > PAGE_W ? (sw - PAGE_W) / 2 : 0;
    uint32_t y = sh > PAGE_H + 40 ? 40 : 0;
    aizigos_surface_blit(pixels, PAGE_W, PAGE_H, x, y);
    aizigos_write("view: painted ", 14);
    aizigos_write(url, strlen(url));
    aizigos_write("\n", 1);
    return 0;
}
