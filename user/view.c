/* A page viewer: fetch, strip, lay out, paint, scroll.
 *
 * Still a walking skeleton rather than an engine — it knows nothing of CSS,
 * boxes or images — but it is the shape of one, and everything under it is now
 * real: a surface handed over by the shell, keyboard and pointer events, a
 * TrueType face rasterised from a file on the volume, and a plotter that
 * clips and blends. When an engine arrives it replaces the middle of this
 * file and keeps everything else.
 */

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <aizigos.h>

#include "http.h"
#include "plot.h"
#include "render.h"

#define SURFACE_W 900
#define SURFACE_H 640
#define MARGIN 24
#define TEXT_SIZE 15.0f
#define HEAD_SIZE 12.0f

#define PAGE_MAX (256 * 1024)
#define TEXT_MAX (128 * 1024)
#define LINES_MAX 4096

static struct surface screen;
static char *page;
static char *text;

struct line {
    uint32_t start;
    uint32_t length;
    bool paragraph_end;
};

static struct line lines[LINES_MAX];
static size_t line_count;

static struct image picture;
static bool showing_picture;

/* --- the font ---------------------------------------------------------- */

/* Read the face off the boot volume. Without it there is still a page, drawn
 * in the fallback the shell uses; a viewer that refuses to start because it
 * cannot find a font is worse than one that looks plain. */
static uint8_t *face_files[4];

static bool load_face(uint32_t face, const char *path) {
    const int64_t handle = aizigos_open(path, strlen(path));
    if (handle < 0) return false;

    const int64_t size = aizigos_file_size(handle);
    if (size <= 0 || size > 8 * 1024 * 1024) {
        aizigos_file_close(handle);
        return false;
    }

    uint8_t *block = aizigos_alloc((size_t)size);
    if (block == NULL) {
        aizigos_file_close(handle);
        return false;
    }
    face_files[face] = block;

    size_t filled = 0;
    while (filled < (size_t)size) {
        const int64_t got = aizigos_read(handle, face_files[face] + filled, (size_t)size - filled);
        if (got <= 0) break;
        filled += (size_t)got;
    }
    aizigos_file_close(handle);
    if (filled != (size_t)size) return false;
    return font_load_face(face, face_files[face], filled) == 0;
}

/* Four faces off the volume: an upright, a bold, an italic and a fixed-width.
 * The upright is required — without it there is nothing to draw with — and the
 * others are what a page's <b> and <code> ask for. */
static bool load_fonts(void) {
    const bool regular = load_face(FACE_REGULAR, "/SANS.TTF");
    (void)load_face(FACE_BOLD, "/SANSB.TTF");
    (void)load_face(FACE_ITALIC, "/SANSI.TTF");
    (void)load_face(FACE_MONO, "/MONO.TTF");
    font_select(FACE_REGULAR);
    return regular;
}

/* Read a whole file off the volume into freshly allocated memory. */
static uint8_t *read_file(const char *path, size_t *out_length) {
    const int64_t handle = aizigos_open(path, strlen(path));
    if (handle < 0) return NULL;
    const int64_t size = aizigos_file_size(handle);
    if (size <= 0) {
        aizigos_file_close(handle);
        return NULL;
    }
    uint8_t *block = aizigos_alloc((size_t)size);
    if (block == NULL) {
        aizigos_file_close(handle);
        return NULL;
    }
    size_t filled = 0;
    while (filled < (size_t)size) {
        const int64_t got = aizigos_read(handle, block + filled, (size_t)size - filled);
        if (got <= 0) break;
        filled += (size_t)got;
    }
    aizigos_file_close(handle);
    if (filled != (size_t)size) return NULL;
    if (out_length) *out_length = filled;
    return block;
}

static bool ends_with_png(const char *path) {
    const size_t n = strlen(path);
    if (n < 4) return false;
    const char *tail = path + n - 4;
    return tail[0] == '.' && (tail[1] | 0x20) == 'p' && (tail[2] | 0x20) == 'n' &&
           (tail[3] | 0x20) == 'g';
}

/* --- the document ------------------------------------------------------- */

#define RUNS_MAX 20000
#define FILLS_MAX 512
#define LINKS_MAX 512

static struct page document;

/* A picture opened on its own, rather than one placed by a page: `<img>` is
 * not laid out yet, and losing the decoder's only proof would be worse than
 * saying which of the two this is. */
static struct image picture;
static bool showing_picture;

static void draw_run(const struct run *r, int32_t scroll) {
    const int y = (int)(r->y - scroll) + 34 + MARGIN;
    if (y < 20 || y > screen.height + 40) return;

    font_select(r->face);
    float pen = (float)(r->x + MARGIN);
    for (uint16_t i = 0; i < r->length; i++) {
        const unsigned char c = (unsigned char)r->text[i];
        struct glyph_bitmap glyph;
        if (font_render(c, r->size, &glyph) && glyph.width > 0) {
            plot_coverage(&screen, glyph.pixels, glyph.width, glyph.height,
                          (int)(pen + (float)glyph.left), y - glyph.top, r->colour);
        }
        pen += font_advance(c, r->size);
    }
    if (r->underline) {
        plot_fill(&screen, r->x + MARGIN, y + 2, (int)pen - r->x - MARGIN, 1, r->colour, 200);
    }
}

static void draw_text_at(const char *text, float pen, int baseline, float size, uint32_t colour) {
    font_select(FACE_REGULAR);
    for (const char *c = text; *c; c++) {
        struct glyph_bitmap glyph;
        if (font_render((unsigned char)*c, size, &glyph) && glyph.width > 0) {
            plot_coverage(&screen, glyph.pixels, glyph.width, glyph.height,
                          (int)(pen + (float)glyph.left), baseline - glyph.top, colour);
        }
        pen += font_advance((unsigned char)*c, size);
    }
}

static float text_width_at(const char *text, float size) {
    font_select(FACE_REGULAR);
    float width = 0;
    for (const char *c = text; *c; c++) width += font_advance((unsigned char)*c, size);
    return width;
}

/* --- painting ------------------------------------------------------------ */

static void draw_page(const char *url, const char *note, uint32_t note_colour, int32_t scroll) {
    plot_clear(&screen, document.background);

    const struct clip previous = plot_push_clip(&screen, 0, 34, screen.width, screen.height - 34);
    for (size_t i = 0; i < document.fill_count; i++) {
        const struct fill *f = &document.fills[i];
        plot_fill(&screen, f->x + MARGIN, (int)(f->y - scroll) + 34 + MARGIN, f->w, f->h,
                  f->colour, 255);
    }
    int32_t lift = 0;
    if (showing_picture) {
        int w = picture.width;
        int h = picture.height;
        const int room_w = screen.width - 2 * MARGIN;
        const int room_h = screen.height - 34 - 2 * MARGIN - 60;
        if (w > room_w) {
            h = h * room_w / w;
            w = room_w;
        }
        if (h > room_h) {
            w = w * room_h / h;
            h = room_h;
        }
        plot_bitmap(&screen, picture.pixels, picture.width, picture.height,
                    (screen.width - w) / 2, 34 + MARGIN - (int)scroll, w, h);
        lift = h + 16;
    }
    for (size_t i = 0; i < document.run_count; i++) draw_run(&document.runs[i], scroll - lift);
    plot_pop_clip(&screen, previous);

    /* The address bar last, over anything a long line put behind it. */
    plot_fill(&screen, 0, 0, screen.width, 34, 0x1A2B44, 255);
    font_select(FACE_REGULAR);
    const int baseline = 10 + (int)font_ascent(HEAD_SIZE);
    draw_text_at(url, MARGIN, baseline, HEAD_SIZE, 0xE8EEF7);
    if (note != NULL) {
        draw_text_at(note, MARGIN + text_width_at(url, HEAD_SIZE) + 16, baseline, HEAD_SIZE,
                     note_colour);
    }

    const int32_t room = screen.height - 34;
    if (document.height > room) {
        const int track = screen.height - 40;
        const int thumb = (int)((float)track * (float)room / (float)document.height);
        const int at = (int)((float)track * (float)scroll / (float)document.height);
        plot_fill(&screen, screen.width - 10, 36, 6, track, 0x000000, 24);
        plot_fill(&screen, screen.width - 10, 36 + at, 6, thumb < 12 ? 12 : thumb, 0x51637E, 220);
    }
}

/* --- the program --------------------------------------------------------- */

static int split_url(const char *url, char *host, size_t host_cap, char *path, size_t path_cap) {
    const char *rest = url;
    int secure = 0;
    if (strncmp(rest, "http://", 7) == 0) {
        rest = url + 7;
    } else if (strncmp(rest, "https://", 8) == 0) {
        rest = url + 8;
        secure = 1;
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
    return secure;
}

/* Resolve a link against the page it was found on: an absolute address is
 * taken as it is, a path keeps the host, and anything else hangs off the
 * directory the page came from. */
static void resolve_link(const char *base, const char *href, char *out, size_t cap) {
    if (strncmp(href, "http://", 7) == 0 || strncmp(href, "https://", 8) == 0) {
        snprintf(out, cap, "%s", href);
        return;
    }
    char host[128];
    char path[192];
    const int secure = split_url(base, host, sizeof(host), path, sizeof(path));
    const char *scheme = secure == 1 ? "https://" : "http://";

    if (href[0] == '/') {
        snprintf(out, cap, "%s%s%s", scheme, host, href);
        return;
    }
    /* Relative: keep everything up to the last slash of the current path. */
    size_t cut = 0;
    for (size_t i = 0; path[i]; i++) {
        if (path[i] == '/') cut = i + 1;
    }
    path[cut] = '\0';
    snprintf(out, cap, "%s%s%s%s", scheme, host, path, href);
}

/* Fetch one address, following redirects, and lay the answer out. Returns the
 * address it ended up at. */
static void load(const char *url, char *final_url, size_t cap, const char **note,
                 uint32_t *note_colour) {
    char current[512];
    snprintf(current, sizeof(current), "%s", url);
    char host[128];
    char path[192];
    int hops = 0;
    *note = NULL;
    *note_colour = 0xB06A12;

    /* A path rather than an address is a file on this volume. */
    if (current[0] == '/') {
        size_t length = 0;
        uint8_t *file = read_file(current, &length);
        if (file == NULL) {
            snprintf(page, PAGE_MAX, "<p>Could not read %s off the volume.</p>", current);
        } else if (ends_with_png(current)) {
            if (png_decode(file, length, &picture) == 0) {
                showing_picture = true;
                snprintf(page, PAGE_MAX, "<p>%d by %d pixels, %d bytes on the volume.</p>",
                         (int)picture.width, (int)picture.height, (int)length);
            } else {
                snprintf(page, PAGE_MAX, "<p>That is not a PNG this decoder reads.</p>");
            }
        } else {
            const size_t take = length < PAGE_MAX - 1 ? length : PAGE_MAX - 1;
            memcpy(page, file, take);
            page[take] = '\0';
        }
        snprintf(final_url, cap, "%s", current);
        render_page(&document, page, SURFACE_W - 2 * MARGIN - 16);
        return;
    }

    for (;;) {
        const int scheme = split_url(current, host, sizeof(host), path, sizeof(path));
        if (scheme < 0) {
            snprintf(page, PAGE_MAX, "<p>That is not an address I can read.</p>");
            break;
        }

        const int64_t n = scheme == 1 ? https_get(host, path, page, PAGE_MAX)
                                      : http_get(host, path, page, PAGE_MAX);
        if (scheme == 1) {
            *note = https_verified() ? "encrypted, server verified"
                                     : "encrypted, server NOT verified";
            if (https_verified()) *note_colour = 0x9BE8A8;
        }
        if (n < 0) {
            snprintf(page, PAGE_MAX, "<h2>The fetch failed</h2><p>Error %d.</p>", (int)-n);
            break;
        }

        char next[512];
        if (hops < 5 && http_redirect(page, host, scheme == 1, next, sizeof(next))) {
            hops++;
            snprintf(current, sizeof(current), "%s", next);
            continue;
        }

        const int status = http_status(page);
        if (status != 0 && status != 200) {
            char body[PAGE_MAX > 4096 ? 4096 : 256];
            snprintf(body, sizeof(body), "<h2>The server answered %d</h2>", status);
            memmove(page, body, strlen(body) + 1);
            break;
        }

        size_t body_length = 0;
        char *body = http_content(page, (size_t)n, &body_length);
        memmove(page, body, body_length + 1);
        break;
    }

    snprintf(final_url, cap, "%s", current);
    render_page(&document, page, SURFACE_W - 2 * MARGIN - 16);
}

int main(int argc, char **argv) {
    const char *start = argc > 1 ? argv[1] : "https://example.com/";

    page = aizigos_alloc(PAGE_MAX);
    screen.pixels = (uint32_t *)aizigos_alloc((size_t)SURFACE_W * SURFACE_H * 4);
    document.runs = aizigos_alloc(RUNS_MAX * sizeof(struct run));
    document.fills = aizigos_alloc(FILLS_MAX * sizeof(struct fill));
    document.links = aizigos_alloc(LINKS_MAX * sizeof(struct link));
    document.text = aizigos_alloc(TEXT_MAX);
    if (page == NULL || screen.pixels == NULL || document.runs == NULL ||
        document.fills == NULL || document.links == NULL || document.text == NULL) {
        aizigos_write("view: not enough memory\n", 24);
        return 1;
    }
    document.run_max = RUNS_MAX;
    document.fill_max = FILLS_MAX;
    document.link_max = LINKS_MAX;
    document.text_max = TEXT_MAX;

    screen.width = SURFACE_W;
    screen.height = SURFACE_H;
    plot_reset_clip(&screen);

    if (!load_fonts()) {
        aizigos_write("view: no faces on the volume\n", 29);
        return 1;
    }

    const uint64_t info = aizigos_surface_info();
    const uint32_t screen_w = (uint32_t)info;
    const uint32_t screen_h = (uint32_t)(info >> 32);
    const uint32_t origin_x = screen_w > SURFACE_W ? (screen_w - SURFACE_W) / 2 : 0;
    const uint32_t origin_y = screen_h > SURFACE_H + 60 ? 46 : 0;
    if (aizigos_surface_grab(origin_x, origin_y, SURFACE_W, SURFACE_H) < 0) {
        aizigos_write("view: the shell would not hand over a surface\n", 45);
        return 1;
    }

    char here[512];
    const char *note = NULL;
    uint32_t note_colour = 0xB06A12;
    load(start, here, sizeof(here), &note, &note_colour);

    /* Where we have been, so a reader can go back. */
    char history[8][512];
    int history_depth = 0;

    int32_t scroll = 0;
    bool running = true;
    bool dirty = true;
    bool on_screen = true;
    uint32_t at_x = origin_x;
    uint32_t at_y = origin_y;
    const int32_t step = 60;
    const int32_t page_step = SURFACE_H - 80;

    while (running) {
        uint64_t event;
        while ((event = aizigos_surface_event()) != 0) {
            const int kind = AIZIGOS_EVENT_KIND(event);
            if (kind == AIZIGOS_EVENT_KEY) {
                const int key = AIZIGOS_EVENT_KEY_BYTE(event);
                if (key == 'q') running = false;
                if (key == ' ') {
                    scroll += page_step;
                    dirty = true;
                }
                if (key == 'j') {
                    scroll += step;
                    dirty = true;
                }
                if (key == 'b') {
                    scroll -= page_step;
                    dirty = true;
                }
                if (key == 'k') {
                    scroll -= step;
                    dirty = true;
                }
                if (key == 'g') {
                    scroll = 0;
                    dirty = true;
                }
                if (key == 8 && history_depth > 0) {
                    history_depth--;
                    load(history[history_depth], here, sizeof(here), &note, &note_colour);
                    scroll = 0;
                    dirty = true;
                }
            } else if (kind == AIZIGOS_EVENT_PRESS) {
                const int px = AIZIGOS_EVENT_X(event) - MARGIN;
                const int32_t py = AIZIGOS_EVENT_Y(event) - 34 - MARGIN + scroll;
                bool followed = false;
                for (size_t i = 0; i < document.link_count; i++) {
                    const struct link *k = &document.links[i];
                    if (k->w == 0) continue;
                    if (px < k->x || px > k->x + k->w) continue;
                    if (py < k->y - k->h || py > k->y + 4) continue;

                    char target[512];
                    resolve_link(here, k->href, target, sizeof(target));
                    if (history_depth < 8) {
                        snprintf(history[history_depth], 512, "%s", here);
                        history_depth++;
                    }
                    load(target, here, sizeof(here), &note, &note_colour);
                    scroll = 0;
                    followed = true;
                    break;
                }
                if (!followed) {
                    scroll += AIZIGOS_EVENT_Y(event) > SURFACE_H / 2 ? page_step : -page_step;
                }
                dirty = true;
            } else if (kind == AIZIGOS_EVENT_CLOSED) {
                running = false;
            } else if (kind == AIZIGOS_EVENT_HIDDEN) {
                on_screen = false;
            } else if (kind == AIZIGOS_EVENT_SHOWN) {
                on_screen = true;
                dirty = true;
            } else if (kind == AIZIGOS_EVENT_MOVED) {
                at_x = (uint32_t)AIZIGOS_EVENT_X(event);
                at_y = (uint32_t)AIZIGOS_EVENT_Y(event);
                dirty = true;
            }
        }

        const int32_t limit = document.height - (SURFACE_H - 34) / 2;
        if (scroll > limit) scroll = limit > 0 ? limit : 0;
        if (scroll < 0) scroll = 0;

        if (dirty && on_screen) {
            draw_page(here, note, note_colour, scroll);
            plot_present(&screen, at_x, at_y);
            dirty = false;
        }
        aizigos_sleep_ms(20);
    }

    aizigos_surface_release();
    aizigos_write("view: done\n", 11);
    return 0;
}
