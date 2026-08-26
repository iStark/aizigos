/* HTML into positioned, styled text.
 *
 * This is a layout engine in the way a rowing boat is a vessel: it has the
 * parts that matter and none of the ones that make the real thing hard. There
 * is a tag stack, a style for each element on it, block boxes stacked down the
 * page with margins, inline text wrapped inside them at the font's own
 * measurements, and enough CSS to make a document look like a document —
 * colour, size, weight, alignment, background, and the display property when
 * it says none.
 *
 * What it is not: a box tree with floats and positioning, a cascade with
 * specificity, a selector engine beyond tag, class and id. Those are what an
 * engine is for, and this file's job is to prove the interfaces underneath it
 * — the fetch, the font, the plotter, the surface — while they are still cheap
 * to change. When NetSurf arrives it replaces this file and keeps the rest.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "render.h"

/* --- small helpers ------------------------------------------------------ */

static bool same_fold(const char *a, const char *b, size_t n) {
    for (size_t i = 0; i < n; i++) {
        char x = a[i];
        char y = b[i];
        if (x >= 'A' && x <= 'Z') x = (char)(x + 32);
        if (y >= 'A' && y <= 'Z') y = (char)(y + 32);
        if (x != y) return false;
    }
    return true;
}

static bool name_is(const char *tag, size_t length, const char *name) {
    const size_t n = strlen(name);
    return length == n && same_fold(tag, name, n);
}

static bool is_space(char c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

/* --- style -------------------------------------------------------------- */

#define ALIGN_LEFT 0
#define ALIGN_CENTRE 1
#define ALIGN_RIGHT 2

struct style {
    float size;
    uint32_t colour;
    uint32_t background;
    uint8_t face;
    uint8_t align;
    bool underline;
    bool hidden;
    int16_t indent;
    int16_t space_before;
    int16_t space_after;
    bool block;
    bool preformatted;
    bool list_item;
    /* Which fill this block reserved, so its height can be filled in when the
     * block ends: a background is as tall as what it contains, and guessing at
     * that draws a stripe across the middle of a paragraph. */
    int16_t fill_index;
    int32_t fill_top;
};

static struct style base_style(void) {
    struct style s;
    s.size = 15.0f;
    s.colour = 0x1B1B1B;
    s.background = 0;
    s.face = FACE_REGULAR;
    s.align = ALIGN_LEFT;
    s.underline = false;
    s.hidden = false;
    s.indent = 0;
    s.space_before = 0;
    s.space_after = 0;
    s.block = false;
    s.preformatted = false;
    s.list_item = false;
    s.fill_index = -1;
    s.fill_top = 0;
    return s;
}

/* The default stylesheet: what a browser believes about tags before the page
 * says anything. Every one of these is a decision someone made in 1996 and
 * everybody has copied since, which is why a page with no CSS still reads. */
static void apply_tag(struct style *s, const char *tag, size_t length) {
    s->block = false;
    s->space_before = 0;
    s->space_after = 0;
    s->list_item = false;
    s->fill_index = -1;

    if (name_is(tag, length, "h1")) {
        s->size = 30;
        s->face = FACE_BOLD;
        s->block = true;
        s->space_before = 20;
        s->space_after = 12;
    } else if (name_is(tag, length, "h2")) {
        s->size = 24;
        s->face = FACE_BOLD;
        s->block = true;
        s->space_before = 18;
        s->space_after = 10;
    } else if (name_is(tag, length, "h3")) {
        s->size = 20;
        s->face = FACE_BOLD;
        s->block = true;
        s->space_before = 16;
        s->space_after = 8;
    } else if (name_is(tag, length, "h4") || name_is(tag, length, "h5") ||
               name_is(tag, length, "h6")) {
        s->size = 17;
        s->face = FACE_BOLD;
        s->block = true;
        s->space_before = 14;
        s->space_after = 6;
    } else if (name_is(tag, length, "p")) {
        s->block = true;
        s->space_before = 8;
        s->space_after = 8;
    } else if (name_is(tag, length, "div") || name_is(tag, length, "section") ||
               name_is(tag, length, "article") || name_is(tag, length, "header") ||
               name_is(tag, length, "footer") || name_is(tag, length, "main") ||
               name_is(tag, length, "nav") || name_is(tag, length, "table") ||
               name_is(tag, length, "tr") || name_is(tag, length, "form")) {
        s->block = true;
    } else if (name_is(tag, length, "ul") || name_is(tag, length, "ol")) {
        s->block = true;
        s->indent = (int16_t)(s->indent + 24);
        s->space_before = 6;
        s->space_after = 6;
    } else if (name_is(tag, length, "li")) {
        s->block = true;
        s->list_item = true;
    } else if (name_is(tag, length, "blockquote")) {
        s->block = true;
        s->indent = (int16_t)(s->indent + 24);
        s->colour = 0x4A4A4A;
        s->space_before = 8;
        s->space_after = 8;
    } else if (name_is(tag, length, "b") || name_is(tag, length, "strong")) {
        s->face = (s->face == FACE_ITALIC) ? FACE_BOLD : FACE_BOLD;
    } else if (name_is(tag, length, "i") || name_is(tag, length, "em")) {
        s->face = FACE_ITALIC;
    } else if (name_is(tag, length, "code") || name_is(tag, length, "kbd") ||
               name_is(tag, length, "samp")) {
        s->face = FACE_MONO;
        s->size = s->size * 0.95f;
    } else if (name_is(tag, length, "pre")) {
        s->face = FACE_MONO;
        s->block = true;
        s->preformatted = true;
        s->space_before = 10;
        s->space_after = 10;
    } else if (name_is(tag, length, "a")) {
        s->colour = 0x1A4FA0;
        s->underline = true;
    } else if (name_is(tag, length, "small")) {
        s->size = s->size * 0.85f;
    } else if (name_is(tag, length, "big")) {
        s->size = s->size * 1.2f;
    } else if (name_is(tag, length, "hr")) {
        s->block = true;
        s->space_before = 10;
        s->space_after = 10;
    }
}

/* --- the page's own CSS -------------------------------------------------- */

/* One declaration block, keyed by a selector this understands: a tag name, a
 * .class or an #id. Anything more elaborate is skipped rather than guessed at,
 * because a rule applied to the wrong element is worse than no rule. */
#define MAX_RULES 96

struct rule {
    char selector[48];
    char body[192];
};

static struct rule rules[MAX_RULES];
static size_t rule_count;

static void copy_into(char *out, size_t cap, const char *from, size_t length) {
    const size_t take = length < cap - 1 ? length : cap - 1;
    memcpy(out, from, take);
    out[take] = '\0';
}

/* Pull the declarations out of a stylesheet. Comments and at-rules are
 * skipped; a selector list keeps only its first name, which covers the common
 * "h1, h2 { ... }" without pretending to implement grouping properly. */
static void collect_rules(const char *css, size_t length) {
    size_t at = 0;
    while (at < length && rule_count < MAX_RULES) {
        while (at < length && is_space(css[at])) at++;
        if (at + 1 < length && css[at] == '/' && css[at + 1] == '*') {
            at += 2;
            while (at + 1 < length && !(css[at] == '*' && css[at + 1] == '/')) at++;
            at += 2;
            continue;
        }
        if (at < length && css[at] == '@') {
            /* An at-rule: skip its prelude and, if it has one, its block. */
            int depth = 0;
            while (at < length) {
                if (css[at] == '{') depth++;
                if (css[at] == '}') {
                    depth--;
                    if (depth <= 0) {
                        at++;
                        break;
                    }
                }
                if (css[at] == ';' && depth == 0) {
                    at++;
                    break;
                }
                at++;
            }
            continue;
        }

        const size_t selector_start = at;
        while (at < length && css[at] != '{') at++;
        if (at >= length) break;
        size_t selector_end = at;
        at++;

        const size_t body_start = at;
        while (at < length && css[at] != '}') at++;
        const size_t body_end = at;
        if (at < length) at++;

        /* Keep the first selector in a list, and only if it is simple. */
        size_t first_end = selector_start;
        while (first_end < selector_end && css[first_end] != ',') first_end++;
        while (first_end > selector_start && is_space(css[first_end - 1])) first_end--;
        size_t first_start = selector_start;
        while (first_start < first_end && is_space(css[first_start])) first_start++;

        bool simple = first_end > first_start;
        for (size_t i = first_start; i < first_end; i++) {
            const char c = css[i];
            const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                            (c >= '0' && c <= '9') || c == '.' || c == '#' || c == '-' || c == '_';
            if (!ok) {
                simple = false;
                break;
            }
        }
        if (!simple) continue;

        copy_into(rules[rule_count].selector, sizeof(rules[0].selector), css + first_start,
                  first_end - first_start);
        copy_into(rules[rule_count].body, sizeof(rules[0].body), css + body_start,
                  body_end - body_start);
        rule_count++;
    }
}

/* --- properties ---------------------------------------------------------- */

static uint32_t parse_hex(const char *from, size_t length) {
    uint32_t value = 0;
    for (size_t i = 0; i < length; i++) {
        const char c = from[i];
        uint32_t digit;
        if (c >= '0' && c <= '9') {
            digit = (uint32_t)(c - '0');
        } else if (c >= 'a' && c <= 'f') {
            digit = (uint32_t)(c - 'a' + 10);
        } else if (c >= 'A' && c <= 'F') {
            digit = (uint32_t)(c - 'A' + 10);
        } else {
            return value;
        }
        value = value * 16 + digit;
    }
    return value;
}

struct named_colour {
    const char *name;
    uint32_t value;
};

static const struct named_colour named_colours[] = {
    { "black", 0x000000 },  { "white", 0xFFFFFF },   { "red", 0xCC0000 },
    { "green", 0x108040 },  { "blue", 0x1A4FA0 },    { "grey", 0x808080 },
    { "gray", 0x808080 },   { "silver", 0xC0C0C0 },  { "navy", 0x102A54 },
    { "teal", 0x0E7C86 },   { "orange", 0xD97706 },  { "yellow", 0xE6C200 },
    { "purple", 0x6B21A8 }, { "maroon", 0x7F1D1D },  { "eee", 0xEEEEEE },
};

/* "#3366cc", "#36c", or one of a handful of names. Anything else — rgb(),
 * hsl(), a gradient — leaves the colour alone, which is the right answer when
 * the alternative is a guess. */
static bool parse_colour(const char *value, size_t length, uint32_t *out) {
    while (length > 0 && is_space(*value)) {
        value++;
        length--;
    }
    if (length == 0) return false;

    if (value[0] == '#') {
        if (length >= 7) {
            *out = parse_hex(value + 1, 6);
            return true;
        }
        if (length >= 4) {
            const uint32_t r = parse_hex(value + 1, 1);
            const uint32_t g = parse_hex(value + 2, 1);
            const uint32_t b = parse_hex(value + 3, 1);
            *out = (r * 17 << 16) | (g * 17 << 8) | (b * 17);
            return true;
        }
        return false;
    }
    for (size_t i = 0; i < sizeof(named_colours) / sizeof(named_colours[0]); i++) {
        const size_t n = strlen(named_colours[i].name);
        if (length >= n && same_fold(value, named_colours[i].name, n)) {
            *out = named_colours[i].value;
            return true;
        }
    }
    return false;
}

/* A length in pixels. em and rem are taken against the current size, which is
 * what makes headings inside a styled body come out the right size; per cent
 * and viewport units are refused rather than approximated. */
static bool parse_length(const char *value, size_t length, float current, float *out) {
    while (length > 0 && is_space(*value)) {
        value++;
        length--;
    }
    if (length == 0) return false;

    char buffer[32];
    copy_into(buffer, sizeof(buffer), value, length);
    char *end = NULL;
    const double number = strtod(buffer, &end);
    if (end == buffer) return false;
    while (*end == ' ') end++;

    if (end[0] == 'p' && end[1] == 'x') {
        *out = (float)number;
        return true;
    }
    if ((end[0] == 'e' && end[1] == 'm') || (end[0] == 'r' && end[1] == 'e' && end[2] == 'm')) {
        *out = (float)number * current;
        return true;
    }
    if (end[0] == 'p' && end[1] == 't') {
        *out = (float)number * 4.0f / 3.0f;
        return true;
    }
    if (*end == '\0') {
        *out = (float)number;
        return true;
    }
    return false;
}

/* Apply one "name: value" pair. */
static void apply_declaration(struct style *s, const char *name, size_t name_len,
                              const char *value, size_t value_len) {
    if (name_is(name, name_len, "color")) {
        (void)parse_colour(value, value_len, &s->colour);
    } else if (name_is(name, name_len, "background-color") ||
               name_is(name, name_len, "background")) {
        (void)parse_colour(value, value_len, &s->background);
    } else if (name_is(name, name_len, "font-size")) {
        float size = s->size;
        if (parse_length(value, value_len, s->size, &size) && size > 4 && size < 96) {
            s->size = size;
        }
    } else if (name_is(name, name_len, "font-weight")) {
        if (value_len >= 4 && same_fold(value, "bold", 4)) s->face = FACE_BOLD;
        if (value_len >= 3 && same_fold(value, "700", 3)) s->face = FACE_BOLD;
        if (value_len >= 3 && same_fold(value, "800", 3)) s->face = FACE_BOLD;
        if (value_len >= 3 && same_fold(value, "900", 3)) s->face = FACE_BOLD;
    } else if (name_is(name, name_len, "font-style")) {
        if (value_len >= 6 && same_fold(value, "italic", 6)) s->face = FACE_ITALIC;
    } else if (name_is(name, name_len, "font-family")) {
        if (value_len >= 9 && same_fold(value, "monospace", 9)) s->face = FACE_MONO;
    } else if (name_is(name, name_len, "text-align")) {
        if (value_len >= 6 && same_fold(value, "center", 6)) s->align = ALIGN_CENTRE;
        if (value_len >= 5 && same_fold(value, "right", 5)) s->align = ALIGN_RIGHT;
        if (value_len >= 4 && same_fold(value, "left", 4)) s->align = ALIGN_LEFT;
    } else if (name_is(name, name_len, "text-decoration")) {
        if (value_len >= 4 && same_fold(value, "none", 4)) s->underline = false;
        if (value_len >= 9 && same_fold(value, "underline", 9)) s->underline = true;
    } else if (name_is(name, name_len, "display")) {
        if (value_len >= 4 && same_fold(value, "none", 4)) s->hidden = true;
        if (value_len >= 5 && same_fold(value, "block", 5)) s->block = true;
    } else if (name_is(name, name_len, "margin-left") || name_is(name, name_len, "padding-left")) {
        float indent = 0;
        if (parse_length(value, value_len, s->size, &indent) && indent > 0 && indent < 400) {
            s->indent = (int16_t)(s->indent + (int16_t)indent);
        }
    }
}

static void apply_declarations(struct style *s, const char *body, size_t length) {
    size_t at = 0;
    while (at < length) {
        while (at < length && (is_space(body[at]) || body[at] == ';')) at++;
        const size_t name_start = at;
        while (at < length && body[at] != ':' && body[at] != ';' && body[at] != '}') at++;
        if (at >= length || body[at] != ':') break;
        size_t name_end = at;
        while (name_end > name_start && is_space(body[name_end - 1])) name_end--;
        at++;

        const size_t value_start = at;
        while (at < length && body[at] != ';' && body[at] != '}') at++;
        size_t value_end = at;
        while (value_end > value_start && is_space(body[value_end - 1])) value_end--;

        apply_declaration(s, body + name_start, name_end - name_start, body + value_start,
                          value_end - value_start);
    }
}

/* Rules whose selector matches this element, in the order they were written:
 * later wins, which is the part of the cascade that matters most often. */
static void apply_rules(struct style *s, const char *tag, size_t tag_len, const char *class_name,
                        size_t class_len, const char *id, size_t id_len) {
    for (size_t i = 0; i < rule_count; i++) {
        const char *selector = rules[i].selector;
        const size_t n = strlen(selector);
        bool matched = false;
        if (selector[0] == '.') {
            matched = class_len > 0 && name_is(class_name, class_len, selector + 1);
        } else if (selector[0] == '#') {
            matched = id_len > 0 && name_is(id, id_len, selector + 1);
        } else {
            matched = name_is(tag, tag_len, selector);
        }
        (void)n;
        if (matched) apply_declarations(s, rules[i].body, strlen(rules[i].body));
    }
}

/* --- laying out ---------------------------------------------------------- */

#define MAX_DEPTH 32

struct layout {
    struct page *page;
    int width;

    struct style stack[MAX_DEPTH];
    size_t depth;

    /* The line being filled. */
    int pen;
    int32_t baseline;
    float line_ascent;
    float line_height;
    size_t line_first_run;
    bool line_has_text;
    int line_indent;
};

static struct style *top(struct layout *l) {
    return &l->stack[l->depth];
}

static float advance_of(unsigned char c, uint8_t face, float size) {
    font_select(face);
    return font_advance(c, size);
}

/* Finish the line: apply the alignment, then start the next one. */
static void end_line(struct layout *l) {
    if (!l->line_has_text) {
        l->pen = l->line_indent;
        return;
    }

    struct page *p = l->page;
    const struct style *s = top(l);
    if (s->align != ALIGN_LEFT) {
        const int used = l->pen - l->line_indent;
        const int room = l->width - l->line_indent - used;
        const int shift = s->align == ALIGN_CENTRE ? room / 2 : room;
        if (shift > 0) {
            for (size_t i = l->line_first_run; i < p->run_count; i++) {
                p->runs[i].x = (int16_t)(p->runs[i].x + shift);
            }
        }
    }

    l->baseline += (int32_t)l->line_height;
    l->pen = l->line_indent;
    l->line_first_run = p->run_count;
    l->line_has_text = false;
    l->line_ascent = 0;
    l->line_height = 0;
}

/* Leave vertical space, collapsing with whatever was left before it — two
 * paragraphs in a row should not be twice as far apart as one. */
static void space_down(struct layout *l, int pixels) {
    static int pending = 0;
    if (pixels > pending) pending = pixels;
    if (pixels == 0 && pending > 0) {
        l->baseline += pending;
        pending = 0;
    }
}

static void begin_block(struct layout *l) {
    end_line(l);
    const struct style *s = top(l);
    space_down(l, s->space_before);
    space_down(l, 0);
    l->line_indent = s->indent;
    l->pen = l->line_indent;
}

static void end_block(struct layout *l) {
    end_line(l);
    space_down(l, top(l)->space_after);
}

static int push_fill(struct layout *l, int32_t y, int16_t h, uint32_t colour) {
    struct page *p = l->page;
    if (p->fill_count == p->fill_max) return -1;
    p->fills[p->fill_count].x = 0;
    p->fills[p->fill_count].w = (int16_t)l->width;
    p->fills[p->fill_count].y = y;
    p->fills[p->fill_count].h = h;
    p->fills[p->fill_count].colour = colour;
    p->fill_count++;
    return (int)p->fill_count - 1;
}

/* Put one word on the line, wrapping first if it does not fit. */
static void place_word(struct layout *l, const char *word, size_t length, int link) {
    if (length == 0) return;
    struct page *p = l->page;
    const struct style *s = top(l);
    if (s->hidden) return;

    float word_width = 0;
    for (size_t i = 0; i < length; i++) {
        word_width += advance_of((unsigned char)word[i], s->face, s->size);
    }

    if (l->line_has_text && l->pen + (int)word_width > l->width) end_line(l);

    font_select(s->face);
    const float ascent = font_ascent(s->size);
    const float height = font_line_height(s->size);
    if (ascent > l->line_ascent) l->line_ascent = ascent;
    if (height > l->line_height) l->line_height = height;

    if (p->run_count == p->run_max) return;
    if (p->text_used + length + 1 > p->text_max) return;

    char *stored = p->text + p->text_used;
    memcpy(stored, word, length);
    stored[length] = '\0';
    p->text_used += length + 1;

    struct run *r = &p->runs[p->run_count++];
    r->text = stored;
    r->length = (uint16_t)length;
    r->x = (int16_t)l->pen;
    r->y = l->baseline;
    r->size = s->size;
    r->colour = s->colour;
    r->face = s->face;
    r->underline = s->underline;
    r->link = (int16_t)link;

    if (link >= 0 && (size_t)link < p->link_count) {
        struct link *k = &p->links[link];
        if (k->w == 0) {
            k->x = (int16_t)l->pen;
            k->y = l->baseline;
        }
        k->w = (int16_t)(l->pen + (int)word_width - k->x);
        k->h = (int16_t)height;
    }

    l->pen += (int)word_width;
    l->line_has_text = true;
}

/* The baseline is where the run says it is, but a line's height is only known
 * once it is full; so runs are placed on a provisional baseline and lifted by
 * the line's ascent when the line ends. Doing it the other way round means
 * measuring twice. */
static void lift_line(struct layout *l, size_t from) {
    struct page *p = l->page;
    for (size_t i = from; i < p->run_count; i++) {
        p->runs[i].y += (int32_t)l->line_ascent;
    }
}

/* --- the parser ---------------------------------------------------------- */

struct attributes {
    const char *class_name;
    size_t class_len;
    const char *id;
    size_t id_len;
    const char *href;
    size_t href_len;
    const char *style;
    size_t style_len;
};

/* Pull the four attributes this understands out of a tag's text. */
static void read_attributes(const char *tag, size_t length, struct attributes *out) {
    memset(out, 0, sizeof(*out));
    size_t at = 0;
    while (at < length && !is_space(tag[at])) at++;

    while (at < length) {
        while (at < length && is_space(tag[at])) at++;
        const size_t name_start = at;
        while (at < length && !is_space(tag[at]) && tag[at] != '=') at++;
        const size_t name_len = at - name_start;
        if (name_len == 0) break;

        while (at < length && is_space(tag[at])) at++;
        if (at >= length || tag[at] != '=') continue;
        at++;
        while (at < length && is_space(tag[at])) at++;

        char quote = 0;
        if (at < length && (tag[at] == '"' || tag[at] == '\'')) {
            quote = tag[at];
            at++;
        }
        const size_t value_start = at;
        while (at < length) {
            if (quote != 0 && tag[at] == quote) break;
            if (quote == 0 && is_space(tag[at])) break;
            at++;
        }
        const size_t value_len = at - value_start;
        if (at < length && quote != 0) at++;

        if (name_is(tag + name_start, name_len, "class")) {
            out->class_name = tag + value_start;
            out->class_len = value_len;
        } else if (name_is(tag + name_start, name_len, "id")) {
            out->id = tag + value_start;
            out->id_len = value_len;
        } else if (name_is(tag + name_start, name_len, "href")) {
            out->href = tag + value_start;
            out->href_len = value_len;
        } else if (name_is(tag + name_start, name_len, "style")) {
            out->style = tag + value_start;
            out->style_len = value_len;
        }
    }
}

/* The entities that turn up in running text. */
static int entity(const char *from, size_t length, char *out) {
    struct { const char *name; char ch; } table[] = {
        { "amp;", '&' },   { "lt;", '<' },     { "gt;", '>' },   { "quot;", '"' },
        { "apos;", '\'' }, { "nbsp;", ' ' },   { "mdash;", '-' }, { "ndash;", '-' },
        { "hellip;", '.' },
    };
    for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); i++) {
        const size_t n = strlen(table[i].name);
        if (length >= n && same_fold(from, table[i].name, n)) {
            *out = table[i].ch;
            return (int)n;
        }
    }
    return 0;
}

void render_page(struct page *page, const char *html, int width) {
    rule_count = 0;
    page->run_count = 0;
    page->fill_count = 0;
    page->link_count = 0;
    page->text_used = 0;
    page->height = 0;
    page->background = 0xF7F5EF;
    page->title[0] = '\0';

    struct layout l;
    memset(&l, 0, sizeof(l));
    l.page = page;
    l.width = width;
    l.depth = 0;
    l.stack[0] = base_style();
    l.baseline = 0;
    l.pen = 0;

    int current_link = -1;
    bool in_title = false;
    size_t title_used = 0;

    const char *at = html;
    size_t line_start_run = 0;

    while (*at) {
        if (*at == '<') {
            const char *tag_start = at + 1;
            const char *tag_end = tag_start;
            while (*tag_end && *tag_end != '>') tag_end++;
            const size_t tag_length = (size_t)(tag_end - tag_start);
            at = *tag_end ? tag_end + 1 : tag_end;

            if (tag_length == 0) continue;
            if (tag_start[0] == '!') continue; /* a comment or a doctype */

            const bool closing = tag_start[0] == '/';
            const char *name = closing ? tag_start + 1 : tag_start;
            size_t name_len = 0;
            while (name_len < tag_length && !is_space(name[name_len]) && name[name_len] != '/' &&
                   name[name_len] != '>') {
                name_len++;
            }

            /* <style> and <script>: one is read, the other is skipped. */
            if (!closing && name_is(name, name_len, "style")) {
                const char *css = at;
                const char *end = css;
                while (*end && !(end[0] == '<' && end[1] == '/')) end++;
                collect_rules(css, (size_t)(end - css));
                at = end;
                continue;
            }
            if (!closing && (name_is(name, name_len, "script") || name_is(name, name_len, "svg"))) {
                const char *end = at;
                while (*end && !(end[0] == '<' && end[1] == '/')) end++;
                at = end;
                continue;
            }
            if (name_is(name, name_len, "title")) {
                in_title = !closing;
                continue;
            }
            if (!closing && name_is(name, name_len, "br")) {
                end_line(&l);
                lift_line(&l, line_start_run);
                line_start_run = page->run_count;
                continue;
            }

            if (closing) {
                struct style *s = top(&l);
                const bool was_block = s->block;
                const int after = s->space_after;
                if (name_is(name, name_len, "a")) current_link = -1;
                if (was_block) {
                    end_line(&l);
                    lift_line(&l, line_start_run);
                    line_start_run = page->run_count;
                    l.baseline += after;
                    if (s->fill_index >= 0 && (size_t)s->fill_index < page->fill_count) {
                        const int32_t tall = l.baseline - s->fill_top;
                        page->fills[s->fill_index].h = (int16_t)(tall > 0 ? tall : 0);
                    }
                }
                if (l.depth > 0) l.depth--;
                l.line_indent = top(&l)->indent;
                continue;
            }

            /* An opening tag: inherit, then apply the defaults, then the
             * page's rules, then whatever the element says about itself. */
            if (l.depth + 1 >= MAX_DEPTH) continue;
            struct attributes attributes;
            read_attributes(tag_start, tag_length, &attributes);

            l.depth++;
            l.stack[l.depth] = l.stack[l.depth - 1];
            struct style *s = top(&l);
            apply_tag(s, name, name_len);
            apply_rules(s, name, name_len, attributes.class_name, attributes.class_len,
                        attributes.id, attributes.id_len);
            if (attributes.style_len > 0) {
                apply_declarations(s, attributes.style, attributes.style_len);
            }

            if (name_is(name, name_len, "a") && attributes.href_len > 0 &&
                page->link_count < page->link_max) {
                struct link *k = &page->links[page->link_count];
                copy_into(k->href, sizeof(k->href), attributes.href, attributes.href_len);
                k->x = 0;
                k->w = 0;
                k->y = 0;
                k->h = 0;
                current_link = (int)page->link_count;
                page->link_count++;
            }

            if (s->block) {
                end_line(&l);
                lift_line(&l, line_start_run);
                line_start_run = page->run_count;
                l.baseline += s->space_before;
                l.line_indent = s->indent;
                l.pen = l.line_indent;
                if (s->background != 0 && s->background != page->background) {
                    /* Reserved now, measured when the block ends. */
                    s->fill_index = (int16_t)push_fill(&l, l.baseline - (int32_t)s->size,
                                                       0, s->background);
                    s->fill_top = l.baseline - (int32_t)s->size;
                }
                if (s->list_item) place_word(&l, "\xe2\x80\xa2", 3, -1);
            }
            if (name_is(name, name_len, "hr")) {
                (void)push_fill(&l, l.baseline, 1, 0xC9C4B8);
                l.baseline += 6;
            }

            /* Void elements never close, so they must not stay on the stack. */
            if (name_is(name, name_len, "br") || name_is(name, name_len, "img") ||
                name_is(name, name_len, "hr") || name_is(name, name_len, "meta") ||
                name_is(name, name_len, "link") || name_is(name, name_len, "input") ||
                (tag_length > 0 && tag_start[tag_length - 1] == '/')) {
                if (l.depth > 0) l.depth--;
            }
            continue;
        }

        /* Text: split into words, with entities turned back into characters. */
        char word[128];
        size_t used = 0;
        while (*at && *at != '<') {
            char c = *at;
            if (c == '&') {
                char decoded = 0;
                const int taken = entity(at + 1, strlen(at + 1), &decoded);
                if (taken > 0) {
                    at += taken + 1;
                    if (used + 1 < sizeof(word)) word[used++] = decoded;
                    continue;
                }
            }
            if (is_space(c)) {
                if (top(&l)->preformatted && c == '\n') {
                    if (used > 0) {
                        place_word(&l, word, used, current_link);
                        used = 0;
                    }
                    end_line(&l);
                    lift_line(&l, line_start_run);
                    line_start_run = page->run_count;
                    at++;
                    continue;
                }
                if (used > 0) {
                    place_word(&l, word, used, current_link);
                    used = 0;
                    /* One space between words, and only if the line has room. */
                    const struct style *s = top(&l);
                    l.pen += (int)advance_of(' ', s->face, s->size);
                }
                at++;
                continue;
            }
            if (in_title) {
                if (title_used + 1 < sizeof(page->title)) page->title[title_used++] = c;
                at++;
                continue;
            }
            if (used + 1 < sizeof(word)) word[used++] = c;
            at++;
        }
        if (used > 0) place_word(&l, word, used, current_link);
    }

    end_line(&l);
    lift_line(&l, line_start_run);
    page->title[title_used] = '\0';
    page->height = l.baseline + 40;
}
