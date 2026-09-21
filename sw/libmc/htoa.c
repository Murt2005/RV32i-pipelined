#include "libmc.h"

// not a real C lib function, but really useful
char *htoa(native_t v, char *s) {
    char *r = s;
    native_t m;

    if (v == 0) {
        (*s) = '0';
        ++s;
        (*s) = '\0';
        return r;
    }

    while (v != 0) {
        m = v % 16;
        (*s) = hextoascii(m);
        ++s;
        v = v - m;
        v = v / 16;
    }

    (*s) = '\0';
    return reverse_string(r);
}

