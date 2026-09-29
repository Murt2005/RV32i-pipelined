/* CoreMark port for this core: bare metal, no libc, timed with mcycle */
#include "coremark.h"
#include "core_portme.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

// Ticks are cycles; the rate is nominal, since make coremark scores per MHz
#define EE_TICKS_PER_SEC 100000000

static CORETIMETYPE start_time_val, stop_time_val;

static CORETIMETYPE
read_mcycle(void)
{
    CORETIMETYPE t;
    __asm__ volatile("csrr %0, mcycle" : "=r"(t));
    return t;
}

void
start_time(void)
{
    start_time_val = read_mcycle();
}

void
stop_time(void)
{
    stop_time_val = read_mcycle();
}

CORE_TICKS
get_time(void)
{
    return (CORE_TICKS)(stop_time_val - start_time_val);
}

secs_ret
time_in_secs(CORE_TICKS ticks)
{
    return (secs_ret)ticks / (secs_ret)EE_TICKS_PER_SEC;
}

ee_u32 default_num_contexts = 1;

void
portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
        ee_printf("ERROR! Please define ee_ptr_int to a type that holds a pointer!\n");
    if (sizeof(ee_u32) != 4)
        ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");
    p->portable_id = 1;
}

void
portable_fini(core_portable *p)
{
    p->portable_id = 0;
}

// GCC may emit calls to these for struct copies and zeroing, and there is no
// libc; the attribute stops GCC turning the loops back into calls to themselves
__attribute__((optimize("no-tree-loop-distribute-patterns"))) void *
memcpy(void *dst, const void *src, size_t n)
{
    char       *d = dst;
    const char *s = src;
    while (n--)
        *d++ = *s++;
    return dst;
}

__attribute__((optimize("no-tree-loop-distribute-patterns"))) void *
memset(void *dst, int c, size_t n)
{
    char *d = dst;
    while (n--)
        *d++ = (char)c;
    return dst;
}
