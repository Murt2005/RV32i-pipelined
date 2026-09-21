#include "libmc.h"

static int is_char_in_string(char ch, const char *delim) {
    if (strchr(delim, ch))
        return 1;
    return 0;
}

static char *saved_strtok_s;
static const char *saved_strtok_delim;
char *strtok(char *s, const char *delim) {
    char *result;
    if (s) {
        saved_strtok_s = s;
        saved_strtok_delim = delim;
    }
    while (*saved_strtok_s &&
        is_char_in_string(*saved_strtok_s, saved_strtok_delim))
        ++saved_strtok_s;
    if (!*saved_strtok_s)
        return NULL;
    // Look ahead and nullify the ending spot
    result = saved_strtok_s;
    char *end = saved_strtok_s;
    while(*end && !is_char_in_string(*end, saved_strtok_delim))
        ++end;

    if (*end) {
        *end = '\0';
        ++end;
    }
    saved_strtok_s = end;
    
    return result;
}

