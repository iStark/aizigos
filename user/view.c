/* Walking skeleton: fetch a page, strip tags, paint text through the plotter. */

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <aizigos.h>
#include "font8x8.h"

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

static const char *skip_headers(const char *body) {
    const char *p = strstr(body, "\r\n\r\n");
    if (p) return p + 4;
    p = strstr(body, "\n\n");
    if (p) return p + 2;
    return body;
}

int main(void) {
    const char *host = "example.com";
    const char *path = "/";
    pixels = aizigos_alloc((size_t)PAGE_W * PAGE_H * 4);
    if (pixels == 0) {
        aizigos_write("view: no pixels\n", 16);
        return 1;
    }
    fill(0xF4F1EA);
    draw_text(MARGIN, MARGIN, "AIZigOS viewer", 0x1A3650);

    int64_t n = aizigos_http_get(host, 11, path, 1, page, sizeof(page) - 1);
    if (n < 0 || (uint64_t)n & ((uint64_t)1 << 63)) {
        draw_text(MARGIN, MARGIN + 24, "fetch failed", 0xA11D1D);
    } else {
        page[n < (int64_t)sizeof(page) ? (size_t)n : sizeof(page) - 1] = 0;
        char text[4096];
        layout_html(skip_headers(page), text, sizeof(text));
        draw_text(MARGIN, MARGIN + 24, text, 0x1B1B1B);
    }

    uint64_t info = aizigos_surface_info();
    uint32_t sw = (uint32_t)info;
    uint32_t sh = (uint32_t)(info >> 32);
    uint32_t x = sw > PAGE_W ? (sw - PAGE_W) / 2 : 0;
    uint32_t y = sh > PAGE_H + 40 ? 40 : 0;
    aizigos_surface_blit(pixels, PAGE_W, PAGE_H, x, y);
    aizigos_write("view: painted example.com\n", 26);
    return 0;
}
