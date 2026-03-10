#include "libmc/libmc.h"

#define UART_ADDR  ((void *)0x0002FFF8)  // MMIO UART TX
#define HALT_ADDR  ((void *)0x0002FFFC)  // MMIO halt

int main(void) {
    const char *msg = "OK\n";

    // Send a short message over the MMIO UART
    for (const char *p = msg; *p; ++p) {
        mmio_write8(UART_ADDR, (uint8_t)*p);
    }

    // Assert the halt MMIO location
    mmio_write32(HALT_ADDR, 1u);

    // Spin forever so the core keeps running
    while (1) {
        // no-op
    }

    return 0;
}
