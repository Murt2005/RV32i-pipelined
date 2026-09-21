#include "libmc.h"

int isalpha(char ch) {
    if (ch >= 'A' && ch <= 'Z')
        return 1;
    if (ch >= 'a' && ch <= 'z')
        return 1;
    return 0;
}
