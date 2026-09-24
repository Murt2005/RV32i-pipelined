#include "libmc.h"

int halt() {
    mmio_write32((void *)0x0002FFFC, 0);
}

