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
static uint8_t *font_file;

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
static bool load_font(const char *path) {
    const int64_t handle = aizigos_open(path, strlen(path));
    if (handle < 0) return false;

    const int64_t size = aizigos_file_size(handle);
    if (size <= 0 || size > 8 * 1024 * 1024) {
        aizigos_file_close(handle);
        return false;
    }

    font_file = aizigos_alloc((size_t)size);
    if (font_file == NULL) {
        aizigos_file_close(handle);
        return false;
    }

    size_t filled = 0;
    while (filled < (size_t)size) {
        const int64_t got = aizigos_read(handle, font_file + filled, (size_t)size - filled);
        if (got <= 0) break;
        filled += (size_t)got;
    }
    aizigos_file_close(handle);
    if (filled != (size_t)size) return false;
    return font_load(font_file, filled) == 0;
}

/* --- text out of HTML --------------------------------------------------- */

/* Compare the leading name of a tag, ignoring case and whatever attributes
 * follow it: `<style type="text/css">` is a style tag like any other. */
static bool tag_named(const char *tag, size_t length, const char *name) {
    size_t i = 0;
    while (i < length && name[i] != '\0') {
        if ((char)(tag[i] | 0x20) != name[i]) return false;
        i++;
    }
    if (name[i] != '\0') return false;
    if (i == length) return true;
    const char after = tag[i];
    return after == ' ' || after == '/' || after == '\t';
}

static bool tag_breaks(const char *tag, size_t length) {
    static const char *breakers[] = { "p",  "br", "div", "li", "tr", "h1", "h2",
                                      "h3", "h4", "h5",  "h6", "ul", "ol", "table" };
    if (length > 0 && tag[0] == '/') {
        tag++;
        length--;
    }
    for (size_t i = 0; i < sizeof(breakers) / sizeof(breakers[0]); i++) {
        const size_t n = strlen(breakers[i]);
        if (n != length) continue;
        size_t j = 0;
        while (j < n && (tag[j] | 0x20) == breakers[i][j]) j++;
        if (j == n) return true;
    }
    return false;
}

/* Tags out, entities in, and a newline wherever a block element ended: it is
 * not a box tree, but it is the difference between a page and a paragraph. */
static void extract_text(const char *html, char *out, size_t cap) {
    size_t written = 0;
    bool in_tag = false;
    bool skipping = false; /* inside <script> or <style> */
    const char *tag_start = NULL;

    while (*html && written + 1 < cap) {
        const char c = *html;
        if (c == '<') {
            in_tag = true;
            tag_start = html + 1;
            html++;
            continue;
        }
        if (c == '>') {
            if (in_tag && tag_start != NULL) {
                const size_t length = (size_t)(html - tag_start);
                if (tag_named(tag_start, length, "script") ||
                    tag_named(tag_start, length, "style") ||
                    tag_named(tag_start, length, "head")) {
                    skipping = true;
                } else if (tag_named(tag_start, length, "/script") ||
                           tag_named(tag_start, length, "/style") ||
                           tag_named(tag_start, length, "/head")) {
                    skipping = false;
                } else if (tag_breaks(tag_start, length)) {
                    if (written > 0 && out[written - 1] != '\n') out[written++] = '\n';
                }
            }
            in_tag = false;
            tag_start = NULL;
            html++;
            continue;
        }
        if (in_tag || skipping) {
            html++;
            continue;
        }

        if (c == '&') {
            /* The handful that appear in running text. */
            if (strncmp(html, "&amp;", 5) == 0) {
                out[written++] = '&';
                html += 5;
                continue;
            }
            if (strncmp(html, "&lt;", 4) == 0) {
                out[written++] = '<';
                html += 4;
                continue;
            }
            if (strncmp(html, "&gt;", 4) == 0) {
                out[written++] = '>';
                html += 4;
                continue;
            }
            if (strncmp(html, "&quot;", 6) == 0) {
                out[written++] = '"';
                html += 6;
                continue;
            }
            if (strncmp(html, "&nbsp;", 6) == 0) {
                out[written++] = ' ';
                html += 6;
                continue;
            }
        }

        char ch = c;
        if (ch == '\r' || ch == '\t') ch = ' ';
        if (ch == '\n') ch = ' ';
        if (ch == ' ' && written > 0 && (out[written - 1] == ' ' || out[written - 1] == '\n')) {
            html++;
            continue;
        }
        out[written++] = ch;
        html++;
    }
    out[written] = '\0';
}

/* --- laying it out ------------------------------------------------------ */

static float text_width(const char *from, size_t length, float size) {
    float width = 0;
    for (size_t i = 0; i < length; i++) width += font_advance((unsigned char)from[i], size);
    return width;
}

/* Break the text into lines that fit the column, at word boundaries where
 * there are any. Measurement is the font's, which is the whole reason for
 * having one: a proportional face laid out on a fixed grid looks like neither.
 */
static void wrap(const char *body, float column) {
    line_count = 0;
    size_t at = 0;
    const size_t length = strlen(body);

    while (at < length && line_count < LINES_MAX) {
        while (at < length && body[at] == ' ') at++;
        if (at >= length) break;

        size_t end = at;
        size_t last_space = 0;
        float width = 0;

        while (end < length && body[end] != '\n') {
            const float advance = font_advance((unsigned char)body[end], TEXT_SIZE);
            if (width + advance > column && end > at) break;
            if (body[end] == ' ') last_space = end;
            width += advance;
            end++;
        }

        size_t stop = end;
        if (end < length && body[end] != '\n' && last_space > at) stop = last_space;

        lines[line_count].start = (uint32_t)at;
        lines[line_count].length = (uint32_t)(stop - at);
        lines[line_count].paragraph_end = (stop < length && body[stop] == '\n');
        line_count++;

        at = stop;
        if (at < length && (body[at] == ' ' || body[at] == '\n')) at++;
    }
}

/* --- painting ------------------------------------------------------------ */

static void draw_string(int x, int y, const char *from, size_t length, float size,
                        uint32_t colour) {
    float pen = (float)x;
    for (size_t i = 0; i < length; i++) {
        const unsigned char c = (unsigned char)from[i];
        struct glyph_bitmap glyph;
        if (font_render(c, size, &glyph) && glyph.width > 0) {
            plot_coverage(&screen, glyph.pixels, glyph.width, glyph.height,
                          (int)(pen + (float)glyph.left), y - glyph.top, colour);
        }
        pen += font_advance(c, size);
    }
}

static void draw_page(const char *body, const char *url, const char *note, uint32_t note_colour,
                      size_t scroll) {
    plot_clear(&screen, 0xF7F5EF);

    /* A header strip, and the page below it. The clip keeps a long line from
     * writing over the chrome. */
    plot_fill(&screen, 0, 0, screen.width, 34, 0x1A2B44, 255);
    const float ascent = font_ascent(HEAD_SIZE);
    draw_string(MARGIN, 10 + (int)ascent, url, strlen(url), HEAD_SIZE, 0xE8EEF7);
    if (note != NULL) {
        const float used = text_width(url, strlen(url), HEAD_SIZE);
        draw_string(MARGIN + (int)used + 16, 10 + (int)ascent, note, strlen(note), HEAD_SIZE,
                    note_colour);
    }

    const struct clip previous = plot_push_clip(&screen, 0, 34, screen.width, screen.height - 34);
    const float line_height = font_line_height(TEXT_SIZE);
    const float body_ascent = font_ascent(TEXT_SIZE);
    int y = 34 + MARGIN + (int)body_ascent;

    if (showing_picture) {
        /* Centred, and scaled down if it does not fit. A page will place its
         * own images; this is the decoder proving itself. */
        int w = picture.width;
        int h = picture.height;
        const int room_w = screen.width - 2 * MARGIN;
        const int room_h = screen.height - 34 - 2 * MARGIN - 40;
        if (w > room_w) {
            h = h * room_w / w;
            w = room_w;
        }
        if (h > room_h) {
            w = w * room_h / h;
            h = room_h;
        }
        plot_bitmap(&screen, picture.pixels, picture.width, picture.height,
                    (screen.width - w) / 2, y + 8, w, h);
        y += h + 24;
    }

    for (size_t i = scroll; i < line_count; i++) {
        if (y > screen.height + 40) break;
        draw_string(MARGIN, y, body + lines[i].start, lines[i].length, TEXT_SIZE, 0x1B1B1B);
        y += (int)line_height;
        if (lines[i].paragraph_end) y += (int)(line_height / 2);
    }
    plot_pop_clip(&screen, previous);

    /* A scroll bar, when there is more page than window. */
    const size_t visible = (size_t)((screen.height - 34 - MARGIN) / (int)line_height);
    if (line_count > visible) {
        const int track = screen.height - 40;
        const int thumb = (int)((float)track * (float)visible / (float)line_count);
        const int at = (int)((float)track * (float)scroll / (float)line_count);
        plot_fill(&screen, screen.width - 10, 36, 6, track, 0x000000, 24);
        plot_fill(&screen, screen.width - 10, 36 + at, 6, thumb < 12 ? 12 : thumb, 0x51637E, 220);
    }
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

int main(int argc, char **argv) {
    const char *url = argc > 1 ? argv[1] : "https://example.com/";
    char host[128];
    char path[192];

    page = aizigos_alloc(PAGE_MAX);
    text = aizigos_alloc(TEXT_MAX);
    screen.pixels = (uint32_t *)aizigos_alloc((size_t)SURFACE_W * SURFACE_H * 4);
    if (page == NULL || text == NULL || screen.pixels == NULL) {
        aizigos_write("view: not enough memory\n", 24);
        return 1;
    }
    screen.width = SURFACE_W;
    screen.height = SURFACE_H;
    plot_reset_clip(&screen);

    if (!load_font("/NOTOSANS.TTF")) {
        aizigos_write("view: no font on the volume; text will be plain\n", 47);
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

    const char *note = NULL;
    uint32_t note_colour = 0xB06A12;

    /* A path rather than an address is a file on this volume. It is how the
     * image decoder gets proved without depending on a server being up, and it
     * is what a page will need anyway once it can refer to its own pictures. */
    if (url[0] == '/') {
        size_t length = 0;
        uint8_t *file = read_file(url, &length);
        if (file == NULL) {
            snprintf(text, TEXT_MAX, "Could not read %s off the volume.", url);
        } else if (ends_with_png(url)) {
            if (png_decode(file, length, &picture) == 0) {
                showing_picture = true;
                note = "decoded here";
                note_colour = 0x9BE8A8;
                snprintf(text, TEXT_MAX, "%d by %d pixels, %d bytes on the volume.",
                         (int)picture.width, (int)picture.height, (int)length);
            } else {
                snprintf(text, TEXT_MAX, "That is not a PNG this decoder reads.");
            }
        } else {
            const size_t take = length < TEXT_MAX - 1 ? length : TEXT_MAX - 1;
            memcpy(text, file, take);
            text[take] = '\0';
        }
        wrap(text, (float)(SURFACE_W - 2 * MARGIN - 16));
        goto interactive;
    }

    const int scheme = split_url(url, host, sizeof(host), path, sizeof(path));
    if (scheme < 0) {
        strcpy(text, "That is not an address I can read.");
    } else {
        int64_t n = scheme == 1 ? https_get(host, path, page, PAGE_MAX)
                                : http_get(host, path, page, PAGE_MAX);
        if (scheme == 1) {
            note = https_verified() ? "encrypted, server verified"
                                    : "encrypted, server NOT verified";
            if (https_verified()) note_colour = 0x9BE8A8;
        }
        if (n < 0) {
            snprintf(text, TEXT_MAX, "The fetch failed: error %d.", (int)-n);
        } else {
            const int status = http_status(page);
            if (status != 0 && status != 200) {
                snprintf(text, TEXT_MAX, "The server answered %d.", status);
            } else {
                size_t body_length = 0;
                const char *body = http_content(page, (size_t)n, &body_length);
                extract_text(body, text, TEXT_MAX);
            }
        }
    }

    wrap(text, (float)(SURFACE_W - 2 * MARGIN - 16));

interactive:;
    size_t scroll = 0;
    bool running = true;
    bool dirty = true;
    const size_t page_lines = 20;

    while (running) {
        uint64_t event;
        while ((event = aizigos_surface_event()) != 0) {
            const int kind = AIZIGOS_EVENT_KIND(event);
            if (kind == AIZIGOS_EVENT_KEY) {
                const int key = AIZIGOS_EVENT_KEY_BYTE(event);
                if (key == 'q') running = false;
                if (key == ' ' || key == 'j') {
                    scroll += key == ' ' ? page_lines : 1;
                    dirty = true;
                }
                if (key == 'b' || key == 'k') {
                    const size_t back = key == 'b' ? page_lines : 1;
                    scroll = scroll > back ? scroll - back : 0;
                    dirty = true;
                }
                if (key == 'g') {
                    scroll = 0;
                    dirty = true;
                }
            } else if (kind == AIZIGOS_EVENT_PRESS) {
                /* A click in the lower half pages down, the upper half up:
                 * crude, and it means the pointer does something until links
                 * exist to click on. */
                scroll = AIZIGOS_EVENT_Y(event) > SURFACE_H / 2
                             ? scroll + page_lines
                             : (scroll > page_lines ? scroll - page_lines : 0);
                dirty = true;
            } else if (kind == AIZIGOS_EVENT_CLOSED) {
                running = false;
            }
        }

        if (scroll >= line_count) scroll = line_count > 0 ? line_count - 1 : 0;

        if (dirty) {
            draw_page(text, url, note, note_colour, scroll);
            plot_present(&screen, origin_x, origin_y);
            dirty = false;
        }
        aizigos_sleep_ms(20);
    }

    aizigos_surface_release();
    aizigos_write("view: done\n", 11);
    return 0;
}
