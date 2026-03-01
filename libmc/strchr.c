#include "libmc.h"

const char *strchr(const char *s, int ch) {
    if (!s)
        return NULL;
    while (*s) {
        if (*s == ch)
            return s;
        ++s;
    }
    return NULL;
}

