#include "libmc.h"

native_t hex(char ch) {
    if (isnumber(ch))
        return (native_t) (ch - '0');
    if (ch >= 'A' && ch <= 'F')
        return (native_t) (ch - 'A') + 10;
    if (ch >= 'a' && ch <= 'f')
        return (native_t) (ch - 'a') + 10;
    return 0;
}
