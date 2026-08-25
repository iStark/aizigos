/* Drawing: a back buffer, a clip rectangle, and blending.
 *
 * Shaped deliberately like the plotter table a browser engine expects — fill a
 * rectangle, draw a line, blit a bitmap, clip everything to a region — so that
 * when an engine arrives it is handed something it already knows how to call
 * rather than something it has to be wrapped around.
 *
 * Everything draws into the program's own buffer and reaches the screen in one
 * blit. A page that repaints in front of the reader is a page that flickers,
 * and the surface call is a copy either way.
 */

#include <string.h>

#include "aizigos.h"
#include "plot.h"

static inline uint32_t blend_pixel(uint32_t dst, uint32_t src, uint8_t alpha) {
    if (alpha == 0) return dst;
    if (alpha == 255) return src;
    const uint32_t inverse = 255u - alpha;
    const uint32_t r = (((src >> 16) & 0xFF) * alpha + ((dst >> 16) & 0xFF) * inverse) / 255;
    const uint32_t g = (((src >> 8) & 0xFF) * alpha + ((dst >> 8) & 0xFF) * inverse) / 255;
    const uint32_t b = ((src & 0xFF) * alpha + (dst & 0xFF) * inverse) / 255;
    return (r << 16) | (g << 8) | b;
}

void plot_reset_clip(struct surface *s) {
    s->clip_x = 0;
    s->clip_y = 0;
    s->clip_w = s->width;
    s->clip_h = s->height;
}

/* Narrow the clip to the intersection with this rectangle, and hand back what
 * it was so a caller can put it back. Intersecting rather than replacing is
 * what makes nesting safe: a child cannot draw outside its parent. */
struct clip plot_push_clip(struct surface *s, int x, int y, int w, int h) {
    const struct clip previous = { s->clip_x, s->clip_y, s->clip_w, s->clip_h };

    int x0 = x > s->clip_x ? x : s->clip_x;
    int y0 = y > s->clip_y ? y : s->clip_y;
    int x1 = (x + w) < (s->clip_x + s->clip_w) ? (x + w) : (s->clip_x + s->clip_w);
    int y1 = (y + h) < (s->clip_y + s->clip_h) ? (y + h) : (s->clip_y + s->clip_h);
    if (x1 < x0) x1 = x0;
    if (y1 < y0) y1 = y0;

    s->clip_x = x0;
    s->clip_y = y0;
    s->clip_w = x1 - x0;
    s->clip_h = y1 - y0;
    return previous;
}

void plot_pop_clip(struct surface *s, struct clip previous) {
    s->clip_x = previous.x;
    s->clip_y = previous.y;
    s->clip_w = previous.w;
    s->clip_h = previous.h;
}

void plot_clear(struct surface *s, uint32_t colour) {
    for (int i = 0; i < s->width * s->height; i++) s->pixels[i] = colour;
}

void plot_fill(struct surface *s, int x, int y, int w, int h, uint32_t colour, uint8_t alpha) {
    int x0 = x < s->clip_x ? s->clip_x : x;
    int y0 = y < s->clip_y ? s->clip_y : y;
    int x1 = (x + w) > (s->clip_x + s->clip_w) ? (s->clip_x + s->clip_w) : (x + w);
    int y1 = (y + h) > (s->clip_y + s->clip_h) ? (s->clip_y + s->clip_h) : (y + h);

    for (int row = y0; row < y1; row++) {
        uint32_t *line = s->pixels + (size_t)row * s->width;
        for (int column = x0; column < x1; column++) {
            line[column] = blend_pixel(line[column], colour, alpha);
        }
    }
}

void plot_point(struct surface *s, int x, int y, uint32_t colour, uint8_t alpha) {
    if (x < s->clip_x || y < s->clip_y) return;
    if (x >= s->clip_x + s->clip_w || y >= s->clip_y + s->clip_h) return;
    uint32_t *at = s->pixels + (size_t)y * s->width + x;
    *at = blend_pixel(*at, colour, alpha);
}

/* Bresenham, because a browser draws borders and rules and nothing that needs
 * better. */
void plot_line(struct surface *s, int x0, int y0, int x1, int y1, uint32_t colour) {
    int dx = x1 - x0;
    int dy = y1 - y0;
    if (dx < 0) dx = -dx;
    if (dy < 0) dy = -dy;
    const int step_x = x0 < x1 ? 1 : -1;
    const int step_y = y0 < y1 ? 1 : -1;
    int error = dx - dy;

    for (;;) {
        plot_point(s, x0, y0, colour, 255);
        if (x0 == x1 && y0 == y1) break;
        const int twice = error * 2;
        if (twice > -dy) {
            error -= dy;
            x0 += step_x;
        }
        if (twice < dx) {
            error += dx;
            y0 += step_y;
        }
    }
}

/* A coverage bitmap in one colour: what a rasterised glyph is. */
void plot_coverage(struct surface *s, const uint8_t *coverage, int cw, int ch, int x, int y,
                   uint32_t colour) {
    for (int row = 0; row < ch; row++) {
        const int py = y + row;
        if (py < s->clip_y || py >= s->clip_y + s->clip_h) continue;
        uint32_t *line = s->pixels + (size_t)py * s->width;
        const uint8_t *source = coverage + (size_t)row * cw;
        for (int column = 0; column < cw; column++) {
            const int px = x + column;
            if (px < s->clip_x || px >= s->clip_x + s->clip_w) continue;
            const uint8_t alpha = source[column];
            if (alpha == 0) continue;
            line[px] = blend_pixel(line[px], colour, alpha);
        }
    }
}

/* Scale by nearest neighbour. An image on a page is usually shown at its own
 * size or a little smaller, and something better belongs with the engine that
 * knows what quality it wants. */
void plot_bitmap(struct surface *s, const uint32_t *pixels, int iw, int ih, int x, int y, int w,
                 int h) {
    if (iw <= 0 || ih <= 0 || w <= 0 || h <= 0) return;

    for (int row = 0; row < h; row++) {
        const int py = y + row;
        if (py < s->clip_y || py >= s->clip_y + s->clip_h) continue;
        const int source_row = row * ih / h;
        uint32_t *line = s->pixels + (size_t)py * s->width;
        const uint32_t *source = pixels + (size_t)source_row * iw;
        for (int column = 0; column < w; column++) {
            const int px = x + column;
            if (px < s->clip_x || px >= s->clip_x + s->clip_w) continue;
            const uint32_t argb = source[column * iw / w];
            line[px] = blend_pixel(line[px], argb & 0xFFFFFF, (uint8_t)(argb >> 24));
        }
    }
}

void plot_present(struct surface *s, uint32_t x, uint32_t y) {
    aizigos_surface_blit(s->pixels, (uint32_t)s->width, (uint32_t)s->height, x, y);
}
