/*
 * doomgeneric platform layer for this core.
 *
 * doomgeneric isolates the platform to six functions. The interesting choices
 * here are about where the pixels go and where the WAD comes from; everything
 * else is a stub.
 *
 * Pixels: built with CMAP256, so doomgeneric keeps Doom's native 8-bit paletted
 * output instead of expanding it to 32-bit ARGB. That matters. The ARGB path
 * would mean a 256 KiB screen buffer and a palette lookup per pixel on the CPU
 * -- 64000 lookups a frame on a machine that has a hardware palette sitting
 * idle. DG_ScreenBuffer is pointed straight at the framebuffer, so
 * I_FinishUpdate's blit writes into the display and there is no second copy at
 * all.
 *
 * The WAD: this machine has no filesystem. The image is placed in SDRAM by the
 * loader (or by the simulation harness) and registered with the syscalls layer,
 * which serves open/read/lseek out of it. Doom is unmodified and still thinks it
 * is reading a file.
 *
 * Timing: mcycle, divided down. No timer hardware was added -- the counter
 * already existed for benchmarking and the core has a hardware divider now.
 */

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "doomgeneric.h"
#include "doomkeys.h"

/* Hardware, as laid out in bus/memory_map.sv. */
#define FRAMEBUFFER   ((uint8_t *)0x10000000u)
#define MMIO_FRAME    (*(volatile uint32_t *)0x0002FFD4u)
#define MMIO_PALETTE  (*(volatile uint32_t *)0x0002FFD8u)

/* Where the harness leaves the WAD, and a header describing it. Kept at a fixed
 * address rather than passed in argv because the loader writes it there before
 * the core is released and has no other way to tell the program about it.
 *
 * 32 MiB in, which leaves the heap the whole first half of SDRAM to grow into.
 * Doom's zone allocator takes as much as it is given, so the WAD has to sit
 * above it, not in the middle. */
#define WAD_HEADER    ((volatile uint32_t *)0x82000000u)
#define WAD_MAGIC     0x57414421u        /* "WAD!" */

extern void ramfile_register(const char *name, void *data, long size);

/* doomgeneric's CMAP256 path exports these so a platform layer can push the
 * palette to hardware rather than doing the lookup itself. */
extern int palette_changed;
struct color { uint8_t b, g, r, a; };
extern struct color colors[256];

#define CPU_HZ 50000000u

static uint32_t read_mcycle(void)
{
    uint32_t v;
    __asm__ volatile ("csrr %0, mcycle" : "=r"(v));
    return v;
}

void DG_Init(void)
{
    /* Draw straight into the framebuffer. doomgeneric allocates a buffer of its
     * own in doomgeneric_Create; overwriting the pointer here means that buffer
     * is simply never used, which costs 64 KiB of heap and saves a full-screen
     * copy every frame. */
    DG_ScreenBuffer = (pixel_t *)FRAMEBUFFER;
}

static void push_palette(void)
{
    for (int i = 0; i < 256; i++)
        MMIO_PALETTE = ((uint32_t)i << 24)
                     | ((uint32_t)colors[i].r << 16)
                     | ((uint32_t)colors[i].g << 8)
                     |  (uint32_t)colors[i].b;
}

void DG_DrawFrame(void)
{
    /* Doom changes the palette for damage flashes, item pickups and the menu
     * fade, so this cannot be done once at startup. */
    if (palette_changed) {
        push_palette();
        palette_changed = 0;
    }

    /* Tell whoever is watching that the framebuffer now holds a whole frame.
     * On the board this is ignored; in simulation it is the only way the harness
     * can capture a complete frame rather than a half-drawn one. */
    MMIO_FRAME = 1;
}

void DG_SleepMs(uint32_t ms)
{
    /* Doom uses this to cap its frame rate. On a machine that will not reach the
     * cap, sleeping only wastes cycles -- so this returns immediately and Doom
     * runs as fast as the hardware allows. */
    (void)ms;
}

uint32_t DG_GetTicksMs(void)
{
    return read_mcycle() / (CPU_HZ / 1000u);
}

int DG_GetKey(int *pressed, unsigned char *key)
{
    /* No input yet. PS/2 arrives with the board; until then Doom runs its demo
     * loop, which is what the frame capture wants anyway. */
    (void)pressed; (void)key;
    return 0;
}

void DG_SetWindowTitle(const char *title)
{
    (void)title;
}

int main(int argc, char **argv)
{
    (void)argc; (void)argv;

    /* The WAD header the loader wrote: magic, byte count, then the data. */
    if (WAD_HEADER[0] != WAD_MAGIC) {
        printf("no WAD at %p (found %08lx)\n",
               (void *)WAD_HEADER, (unsigned long)WAD_HEADER[0]);
        return 1;
    }
    uint32_t wad_size = WAD_HEADER[1];
    void    *wad_data = (void *)&WAD_HEADER[2];
    printf("WAD: %lu bytes at %p\n", (unsigned long)wad_size, wad_data);
    ramfile_register("doom1.wad", wad_data, (long)wad_size);

    static char  arg0[] = "doom";
    static char  arg1[] = "-iwad";
    static char  arg2[] = "doom1.wad";
    static char *args[] = { arg0, arg1, arg2 };

    doomgeneric_Create(3, args);

    for (;;)
        doomgeneric_Tick();

    return 0;
}
