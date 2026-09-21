#include "libmc.h"

void long_pause(int amount) {
    int i;
    for (i = 0; i < amount; i++)
        use(i);
}

