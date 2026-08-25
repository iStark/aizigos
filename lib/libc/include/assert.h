/* assert.h — an assertion that fails stops the kernel, loudly. */
#ifndef AIZIGOS_ASSERT_H
#define AIZIGOS_ASSERT_H

void aizigos_assert_failed(const char *expression, const char *file, int line);

#ifdef NDEBUG
#define assert(expression) ((void)0)
#else
#define assert(expression) \
    ((expression) ? (void)0 : aizigos_assert_failed(#expression, __FILE__, __LINE__))
#endif

#endif
