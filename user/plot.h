/* A drawing surface with a clip rectangle. See plot.c for what it is for. */

#ifndef AIZIGOS_PLOT_H
#define AIZIGOS_PLOT_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

struct surface {
    uint32_t *pixels;
    int width;
    int height;
    int clip_x;
    int clip_y;
    int clip_w;
    int clip_h;
};

struct clip {
    int x, y, w, h;
};

void plot_reset_clip(struct surface *s);
struct clip plot_push_clip(struct surface *s, int x, int y, int w, int h);
void plot_pop_clip(struct surface *s, struct clip previous);

void plot_clear(struct surface *s, uint32_t colour);
void plot_fill(struct surface *s, int x, int y, int w, int h, uint32_t colour, uint8_t alpha);
void plot_point(struct surface *s, int x, int y, uint32_t colour, uint8_t alpha);
void plot_line(struct surface *s, int x0, int y0, int x1, int y1, uint32_t colour);

/* One-colour coverage, which is what a rasterised glyph is. */
void plot_coverage(struct surface *s, const uint8_t *coverage, int cw, int ch, int x, int y,
                   uint32_t colour);

/* ARGB pixels, scaled to fit the destination rectangle. */
void plot_bitmap(struct surface *s, const uint32_t *pixels, int iw, int ih, int x, int y, int w,
                 int h);

void plot_present(struct surface *s, uint32_t x, uint32_t y);

/* The font, rasterised by user/font.zig. */
struct glyph_bitmap {
    const uint8_t *pixels;
    int32_t width;
    int32_t height;
    int32_t left;
    int32_t top;
    float advance;
};

int font_load(const uint8_t *bytes, size_t length);
int font_load_face(uint32_t face, const uint8_t *bytes, size_t length);
void font_select(uint32_t face);
bool font_has(uint32_t face);
bool font_ready(void);
float font_ascent(float size_px);
float font_line_height(float size_px);
float font_advance(uint32_t codepoint, float size_px);
bool font_render(uint32_t codepoint, float size_px, struct glyph_bitmap *out);

/* Images, decoded by user/image.zig. */
struct image {
    const uint32_t *pixels;
    int32_t width;
    int32_t height;
};

int png_decode(const uint8_t *bytes, size_t length, struct image *out);

#endif
