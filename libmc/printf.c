#include "libmc.h"

#define MAX_PRINTF_STRING   1023

static char *__append_at(char *dest, const char *src) {
    while (*src) {
        *dest = *src;
        ++dest;
        ++src;
    }
    return dest;
}

int vsprintf(char *dest, const char *fmt, va_list args) {
    int     length = 0;
    while (*fmt) {
        //putc(*fmt);
        //putc('\n');
        if (*fmt == '%') {
            int first_num = -1, second_num = -1;
            char *s;
            native_t i;
            char    i_as_string[128];

            ++fmt;      // advance past the %
            // parse X[.X] length specifiers.  Not used for now.
            if (isnumber(*fmt)) {
                first_num = atoi(fmt);
                while (isnumber(*fmt))
                    ++fmt; 
            }
            if (*fmt == '.') {
                ++fmt;
                second_num = atoi(fmt);
                while (isnumber(*fmt))
                    ++fmt;
            }
            // Lie to the compiler about the use of these variables
            use(first_num);
            use(second_num);
            while (*fmt == 'l') // Skip any thing like %lld and treat as %d
                ++fmt;
            switch (*fmt) {
                case    'c':
                    ++fmt;
                    i = va_arg(args, int);
                    i_as_string[0] = (char)i;
                    i_as_string[1] = '\0';
                    dest = __append_at(dest, i_as_string);
                    break;
                case    's':
                    ++fmt;
                    s = va_arg(args, char *);
                    dest = __append_at(dest, s);
                    break;
                case    'd':
                    ++fmt;
                    i = va_arg(args, snative_t);
                    itoa(i, i_as_string);
                    dest = __append_at(dest, i_as_string);
                    break;
                case    'x':
                    ++fmt;
                    i = va_arg(args, native_t);
                    htoa(i, i_as_string);
                    i = strlen(i_as_string);
                    if (first_num >= 0)
                        i_as_string[first_num] = '\0';
                    if (second_num >= 0) {
                        while (i < second_num) {
                            dest = __append_at(dest, "0");
                            ++i;
                        }
                    }
                    dest = __append_at(dest, i_as_string);
                    break;
                case    'b':
                    ++fmt;
                    i = va_arg(args, native_t);
                    btoa(i, i_as_string);
                    i = strlen(i_as_string);
                    if (first_num >= 0)
                        i_as_string[first_num] = '\0';
                    if (second_num >= 0) {
                        while (i < second_num) {
                            dest = __append_at(dest, "0");
                            ++i;
                        }
                    }
                    dest = __append_at(dest, i_as_string);
                    break;
            }
        } else {
            *dest = *fmt;
            ++dest;
            ++fmt;
            ++length;
        }
    }
    *dest = '\0';

    return length;
}

void printf(char *fmt, ...) {
    char    s[MAX_PRINTF_STRING + 1];
    int i;
    va_list args;
    va_start(args, fmt);
    vsprintf(s, fmt, args);
    i = 0;
    while (s[i]) {
        putc(s[i]);
        ++i;
    } 
    va_end(args);
}

int sprintf(char *s, char *fmt, ...) {
    int ret;
    va_list args;
    va_start(args, fmt);
    ret = vsprintf(s, fmt, args);
    va_end(args);
    return ret;
}
