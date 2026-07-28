/*
 * Proves the C runtime works from SDRAM: newlib's printf with the `l` modifier
 * libmc silently dropped, malloc against the sbrk heap, string.h, and the
 * mcycle-based millisecond clock Doom asks for.
 *
 * Deliberately small and self-checking. If any of this is wrong, finding out
 * here costs seconds; finding out inside 30,000 lines of Doom does not.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned long read_mcycle(void)
{
    unsigned long v;
    __asm__ volatile ("csrr %0, mcycle" : "=r"(v));
    return v;
}

/* What doomgeneric's DG_GetTicksMs becomes on this machine. No timer hardware
 * is needed: mcycle already exists and the core has a hardware divider now. */
#define CPU_HZ 50000000u
static unsigned int ticks_ms(void)
{
    return (unsigned int)(read_mcycle() / (CPU_HZ / 1000u));
}

int main(void)
{
    int fails = 0;

    printf("hello from SDRAM\n");

    /* %ld: libmc's printf swallowed the l and printed the wrong thing. */
    long big = 1234567890L;
    char buf[64];
    snprintf(buf, sizeof buf, "%ld", big);
    if (strcmp(buf, "1234567890") != 0) { printf("FAIL %%ld -> %s\n", buf); fails++; }

    /* malloc, and enough of it to be sure it is really coming from SDRAM. */
    const int N = 4096;
    int *a = malloc(N * sizeof(int));
    if (!a) { printf("FAIL malloc\n"); fails++; }
    else {
        for (int i = 0; i < N; i++) a[i] = i * 3;
        long sum = 0;
        for (int i = 0; i < N; i++) sum += a[i];
        if (sum != 3L * (N - 1) * N / 2) { printf("FAIL sum %ld\n", sum); fails++; }
        free(a);
    }

    /* string.h, which libmc mostly did not have. */
    char s[32];
    strcpy(s, "doom");
    strcat(s, "1.wad");
    if (strcmp(s, "doom1.wad") != 0) { printf("FAIL strcat -> %s\n", s); fails++; }
    if (strlen(s) != 9) { printf("FAIL strlen\n"); fails++; }

    /* Hardware multiply and divide, through C rather than assembly. */
    volatile int x = 40000, y = 7;
    if (x * y != 280000) { printf("FAIL mul\n"); fails++; }
    if (x / y != 5714)   { printf("FAIL div %d\n", x / y); fails++; }
    if (x % y != 2)      { printf("FAIL mod %d\n", x % y); fails++; }

    /* The clock has to move. */
    unsigned int t0 = ticks_ms();
    volatile unsigned int spin = 0;
    for (int i = 0; i < 200000; i++) spin += i;
    unsigned int t1 = ticks_ms();
    if (t1 == t0) { printf("FAIL clock did not advance\n"); fails++; }
    printf("elapsed %u ms over %lu cycles\n", t1 - t0, read_mcycle());

    printf(fails ? "FAILURES: %d\n" : "all sdram runtime tests passed\n", fails);
    return fails;
}
