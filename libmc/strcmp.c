#include "libmc.h"

int strcmp(const char *s1, const char *s2) {
    while (*s1 && *s2) {
        if (*s1 < *s2)
            return -1;
        if (*s1 > *s2)
            return 1;
        ++s1;
        ++s2;
    }
    if (*s1 == *s2)
        return 0;
    if (*s1)
        return -1;
    return 1;
}