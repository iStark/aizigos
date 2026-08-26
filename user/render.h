/* Turning HTML into positioned, styled text. See render.c for what it is and
 * what it deliberately is not. */

#ifndef AIZIGOS_RENDER_H
#define AIZIGOS_RENDER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "plot.h"

/* Which face to draw a run in. The numbers match user/font.zig. */
#define FACE_REGULAR 0
#define FACE_BOLD 1
#define FACE_ITALIC 2
#define FACE_MONO 3

/* One stretch of text on one line, in one style: what the painter draws. */
struct run {
    const char *text;
    uint16_t length;
    int16_t x;
    int32_t y; /* baseline, in document coordinates */
    float size;
    uint32_t colour;
    uint8_t face;
    bool underline;
    /* Which link this run belongs to, or -1. */
    int16_t link;
};

struct link {
    char href[192];
    /* The area to click, in document coordinates. */
    int16_t x, w;
    int32_t y, h;
};

/* A rectangle of colour behind the text: a heading's background, a block
 * quote's stripe, a table cell. */
struct fill {
    int16_t x, w;
    int32_t y;
    int16_t h;
    uint32_t colour;
};

struct page {
    struct run *runs;
    size_t run_count;
    size_t run_max;

    struct fill *fills;
    size_t fill_count;
    size_t fill_max;

    struct link *links;
    size_t link_count;
    size_t link_max;

    /* Where the text was copied to, since the source is reused. */
    char *text;
    size_t text_used;
    size_t text_max;

    /* Total height of the laid-out document. */
    int32_t height;
    uint32_t background;
    char title[128];
};

/* Lay out `html` into `into`, wrapping at `width` pixels. The page's buffers
 * must already point at memory the caller owns. */
void render_page(struct page *into, const char *html, int width);

#endif
