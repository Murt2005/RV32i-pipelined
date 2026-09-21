#include "libmc.h"
// not a real C lib function

char *btoa(native_t v, char *s) {
    char *r = s;
    native_t m;
    int c;

    if (v == 0) {
        (*s) = '0';
        ++s;
        (*s) = '\0';
        return r;
    }

    c = 0;
    while (v != 0) {
        m = v & 0x01;
        (*s) = hextoascii(m);
        ++s;
        ++c;
        if (c == 4) {
            (*s) = '.';
            ++s;
            c = 0;
        }
        v = v >> 1; 
    }

    (*s) = '\0';
    return reverse_string(r);
}
