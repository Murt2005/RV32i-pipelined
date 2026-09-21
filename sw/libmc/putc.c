#include "libmc.h"

int putc(char ch) {
    mmio_write32((void *)0x0002FFF8, ch);
    return 0;
}

