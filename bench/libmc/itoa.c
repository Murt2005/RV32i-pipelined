#include "libmc.h"

// not a real C lib function, but really useful
char *itoa(native_t v, char *s) {
    char *r = s;
    int is_negative;
    native_t m;

    if (v < 0) {
        (*s) = '-';
        v = -1 * v;
        ++s;
        is_negative = 1;
    } else
        is_negative = 0;

    if (v == 0) {
        (*s) = '0';
        ++s;
        (*s) = '\0';
        return r;
    }

    while (v != 0) {
        m = v % 10;
        (*s) = numtoascii(m);
        ++s;
        v = v - m;
        v = v / 10;
    }

    (*s) = '\0';
    if (is_negative)
        reverse_string(&r[1]);
    else
        reverse_string(r);

    return r;
}

