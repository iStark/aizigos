/* A small libm: the functions a font rasteriser and a layout engine call. */

#include <math.h>
#include <stddef.h>
#include <stdint.h>

static const double pi = 3.14159265358979323846;
static const double ln2 = 0.69314718055994530942;

double fabs(double x) {
    return x < 0 ? -x : x;
}

double floor(double x) {
    if (x >= 0) return (double)(int64_t)x;
    double t = (double)(int64_t)x;
    return t == x ? t : t - 1.0;
}

double ceil(double x) {
    if (x <= 0) return (double)(int64_t)x;
    double t = (double)(int64_t)x;
    return t == x ? t : t + 1.0;
}

double fmod(double x, double y) {
    if (y == 0) return 0;
    double q = floor(x / y);
    return x - q * y;
}

double ldexp(double x, int exp) {
    while (exp > 0) {
        x *= 2.0;
        exp--;
    }
    while (exp < 0) {
        x *= 0.5;
        exp++;
    }
    return x;
}

double sqrt(double x) {
    if (x <= 0) return 0;
    double g = x;
    int i;
    for (i = 0; i < 12; i++) g = 0.5 * (g + x / g);
    return g;
}

double exp(double x) {
    if (x > 88) return 1e300;
    if (x < -88) return 0;
    int n = (int)floor(x / ln2);
    double r = x - n * ln2;
    double s = 1.0 + r * (1.0 + r * (1.0 / 2 + r * (1.0 / 6 + r * (1.0 / 24 + r * (1.0 / 120 + r / 720)))));
    return ldexp(s, n);
}

double log(double x) {
    if (x <= 0) return -1e300;
    int e = 0;
    while (x > 2) {
        x *= 0.5;
        e++;
    }
    while (x < 1) {
        x *= 2;
        e--;
    }
    double t = x - 1;
    double acc = 0;
    double p = t;
    int i;
    for (i = 1; i <= 16; i++) {
        acc += ((i & 1) ? 1.0 : -1.0) * p / i;
        p *= t;
    }
    return acc + e * ln2;
}

double pow(double x, double y) {
    if (x <= 0) return 0;
    return exp(y * log(x));
}

double sin(double x) {
    x = fmod(x, 2 * pi);
    if (x > pi) x -= 2 * pi;
    if (x < -pi) x += 2 * pi;
    double x2 = x * x;
    return x * (1 - x2 / 6 * (1 - x2 / 20 * (1 - x2 / 42)));
}

double cos(double x) {
    return sin(x + pi / 2);
}

double strtod(const char *text, char **end) {
    const char *cursor = text;
    while (*cursor == ' ' || *cursor == '\t' || *cursor == '\n' || *cursor == '\r') cursor++;
    int negative = 0;
    if (*cursor == '+' || *cursor == '-') {
        negative = (*cursor == '-');
        cursor++;
    }
    double value = 0;
    int any = 0;
    while (*cursor >= '0' && *cursor <= '9') {
        value = value * 10 + (*cursor - '0');
        cursor++;
        any = 1;
    }
    if (*cursor == '.') {
        cursor++;
        double place = 0.1;
        while (*cursor >= '0' && *cursor <= '9') {
            value += (*cursor - '0') * place;
            place *= 0.1;
            cursor++;
            any = 1;
        }
    }
    if (end != NULL) *end = (char *)(any ? cursor : text);
    return negative ? -value : value;
}

double atan2(double y, double x) {
    if (x == 0) return y > 0 ? pi / 2 : (y < 0 ? -pi / 2 : 0);
    double a = fabs(y / x);
    double t = a;
    if (a > 1) t = 1 / a;
    double t2 = t * t;
    double r = t * (1 - t2 * (1.0 / 3 - t2 * (1.0 / 5 - t2 / 7)));
    if (a > 1) r = pi / 2 - r;
    if (x < 0) r = pi - r;
    return y < 0 ? -r : r;
}
