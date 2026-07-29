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
#define MMIO_KEY      (*(volatile uint32_t *)0x0002FFDCu)

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
    /* One event per call, as doomgeneric expects -- it calls until we say there
     * is nothing left. Bit 31 distinguishes "queue empty" from "release of key
     * code zero", which a bare zero could not. */
    uint32_t e = MMIO_KEY;
    if (!(e & 0x80000000u))
        return 0;
    *pressed = (e >> 8) & 1;
    *key     = (unsigned char)(e & 0xFF);
    return 1;
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

    /* Read the WAD back through the same stdio path Doom uses and compare with
     * the bytes we know are in memory. If this disagrees, every texture and
     * patch Doom loads is wrong and the renderer draws noise -- which is a very
     * confusing thing to debug from the picture alone. */
    {
        FILE *f = fopen("doom1.wad", "rb");
        if (!f) {
            printf("SELFTEST: fopen failed\n");
        } else {
            unsigned char buf[16];
            const unsigned char *ref = (const unsigned char *)wad_data;
            int bad = 0;

            if (fread(buf, 1, 12, f) != 12) { printf("SELFTEST: short read\n"); bad++; }
            for (int i = 0; i < 12; i++) if (buf[i] != ref[i]) bad++;
            printf("SELFTEST head: %02x%02x%02x%02x expect %02x%02x%02x%02x\n",
                   buf[0], buf[1], buf[2], buf[3], ref[0], ref[1], ref[2], ref[3]);

            /* A seek to somewhere well past the first buffer, which is where a
             * wrong buffer size shows up. */
            long probe = 1000000;
            fseek(f, probe, SEEK_SET);
            if (fread(buf, 1, 16, f) != 16) { printf("SELFTEST: short read 2\n"); bad++; }
            for (int i = 0; i < 16; i++) if (buf[i] != ref[probe + i]) bad++;
            printf("SELFTEST @%ld: %02x%02x%02x%02x expect %02x%02x%02x%02x -> %s\n",
                   probe, buf[0], buf[1], buf[2], buf[3],
                   ref[probe], ref[probe+1], ref[probe+2], ref[probe+3],
                   bad ? "MISMATCH" : "ok");
            fclose(f);
        }
    }

    static char  arg0[] = "doom";
    static char  arg1[] = "-iwad";
    static char  arg2[] = "doom1.wad";
    static char *args[] = { arg0, arg1, arg2 };

    doomgeneric_Create(3, args);

    for (;;)
        doomgeneric_Tick();

    return 0;
}
