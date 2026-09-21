/*
 * Bare-metal support for Dhrystone on this core.
 *
 * The riscv-tests copy of the benchmark targets a spike-like environment with
 * a full libc and a tohost channel. Everything it needs that this machine does
 * not already provide is here, and the benchmark sources themselves are
 * unmodified -- which matters, because a Dhrystone number is only comparable
 * if the benchmark is.
 *
 * Timing comes from mcycle, which dhrystone.h already selects for __riscv.
 */

#include "libmc.h"

/* Matches NUMBER_OF_RUNS in dhrystone.h. Not included here: that header pulls
   in the system stdio/stdint, which conflict with libmc's declarations. */
#define DHRY_RUNS 500

#define UART_ADDR  0x0002FFF8
#define HALT_ADDR  0x0002FFFC

/* ---- what the benchmark expects from its environment ---- */

void setStats(int enable) { (void)enable; }   /* riscv-tests counter dump */

char *strcpy(char *dst, const char *src) {
    char *d = dst;
    while ((*d++ = *src++)) { }
    return dst;
}

/* Dhrystone compares only for equality/ordering of its own literals. */
int strcmp_(const char *a, const char *b) {
    while (*a && (*a == *b)) { a++; b++; }
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

void *memcpy(void *dst, const void *src, unsigned n) {
    char *d = dst; const char *s = src;
    while (n--) *d++ = *s++;
    return dst;
}

int putchar(int c) { return putc((char)c); }

/* debug_printf is provided by dhrystone.c itself; it calls putchar. */

/* ---- entry and exit ---- */

extern int dhrystone_main(void);

void halt_machine(void) {
    volatile unsigned *h = (volatile unsigned *)HALT_ADDR;
    for (;;) *h = 0;
}

/* Defined in dhrystone_main.c; reported here in raw form as well, because the
   benchmark's own report depends on printf's %ld support and on HZ being the
   real clock rate. User_Time is in mcycle ticks. */
extern long User_Time;

static void print_u32(const char *label, unsigned long v) {
    char buf[16];
    int n = 0;
    for (char *p = (char *)label; *p; ++p) putc(*p);
    if (v == 0) buf[n++] = '0';
    while (v) { buf[n++] = '0' + (v % 10); v /= 10; }
    while (n--) putc(buf[n]);
    putc('\n');
}

int main(void) {
    dhrystone_main();
    print_u32("CYCLES=", (unsigned long)User_Time);
    print_u32("RUNS=", (unsigned long)DHRY_RUNS);
    halt_machine();
    return 0;
}
