#include "libmc.h"

void *memset(void *p, int c, native_t len) {
    char *s = p;
    while (len) {
        *s = (char) c;
        ++s;
        --len;
    }
    return p;
}
