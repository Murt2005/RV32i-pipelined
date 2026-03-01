#include "libmc.h"

char *reverse_string(char *s) {
    int len = strlen(s);
    int upto = len / 2;
//    int odd = len & 1;
    int i = 0;
    char ch;

    while (i < upto) {
        ch = s[i];
        s[i] = s[len - i - 1];
        s[len - i - 1] = ch;
        ++i;
    }
    return s;
}

