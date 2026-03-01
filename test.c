#include "libmc.h"

char dummy_string[128] = "This is just here to reassure you elftohex is working";

// This is just here to make the linker happy for lab2/3
int main() {
    printf("Hi there %d\n", atoi("-55"));
}

