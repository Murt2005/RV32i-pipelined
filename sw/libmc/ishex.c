#include "libmc.h"

int ishex(char ch) {
    if (isnumber(ch))
        return 1;
    if (ch >= 'A' && ch <= 'F')
        return 1;
    if (ch >= 'a' && ch <= 'f')
        return 1;
    return 0;
}

