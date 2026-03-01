#include "libmc.h"

void puts(char *s) {
    while (*s) {
        putc(*s);
        ++s;
    }
}

