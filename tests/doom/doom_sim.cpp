// Verilator harness for running Doom on the core and capturing what it draws.
//
// Two things this does that the ordinary simulation top cannot.
//
// It loads memory directly rather than through $readmemh. A WAD is four
// megabytes; a hex file that size takes longer to parse than the simulation it
// precedes, and there is no reason to go through text at all when the harness
// already has the bytes.
//
// It captures frames. The program stores to the frame register when the
// framebuffer holds a complete picture, and this writes it out as a PNG-free
// binary PPM with the palette applied -- no image library, no dependencies, and
// a format anything can open.
//
//   build/doom/doom_sim <program.elf.sdram.bin> <doom1.wad> [max-frames]

#include <verilated.h>
#include "Vtop.h"
#include "Vtop___024root.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// Must match bus/memory_map.sv.
static const uint32_t SDRAM_BASE = 0x80000000u;
static const uint32_t FB_BASE    = 0x10000000u;
static const uint32_t WAD_ADDR   = 0x82000000u;   // where the port layer looks
static const uint32_t WAD_MAGIC  = 0x57414421u;   // "WAD!"

static const int FB_W = 320, FB_H = 200;

static Vtop *top;
static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

// The memories are four byte-lane arrays, one per byte of each word -- see
// memory.sv. Address bits 1:0 select the lane, the rest indexes the array.
//
// Verilator flattens the hierarchy into the root object rather than producing
// nested structs, so the arrays are passed in individually. Templated on the
// array type because each memory's is a different size and therefore a
// different VlUnpacked instantiation.
#define LANES(inst) root->top__DOT__##inst##__DOT__mem__DOT__data0, \
                    root->top__DOT__##inst##__DOT__mem__DOT__data1, \
                    root->top__DOT__##inst##__DOT__mem__DOT__data2, \
                    root->top__DOT__##inst##__DOT__mem__DOT__data3

template <typename A>
static void mem_write(A &d0, A &d1, A &d2, A &d3,
                      uint32_t offset, const uint8_t *data, size_t len)
{
    for (size_t i = 0; i < len; i++) {
        uint32_t a = offset + (uint32_t)i;
        switch (a & 3) {
            case 0: d0[a >> 2] = data[i]; break;
            case 1: d1[a >> 2] = data[i]; break;
            case 2: d2[a >> 2] = data[i]; break;
            case 3: d3[a >> 2] = data[i]; break;
        }
    }
}

template <typename A>
static uint8_t mem_read8(A &d0, A &d1, A &d2, A &d3, uint32_t offset)
{
    switch (offset & 3) {
        case 0: return d0[offset >> 2];
        case 1: return d1[offset >> 2];
        case 2: return d2[offset >> 2];
        default: return d3[offset >> 2];
    }
}

static std::vector<uint8_t> read_file(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(2); }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> v((size_t)n);
    if (fread(v.data(), 1, (size_t)n, f) != (size_t)n) {
        fprintf(stderr, "short read on %s\n", path);
        exit(2);
    }
    fclose(f);
    return v;
}

// Binary PPM: three bytes per pixel, no compression, no library. Every image
// viewer and every scripting language reads it.
static void write_ppm(const char *path, const uint8_t *indices,
                      const uint32_t *palette)
{
    FILE *f = fopen(path, "wb");
    if (!f) return;
    fprintf(f, "P6\n%d %d\n255\n", FB_W, FB_H);
    for (int i = 0; i < FB_W * FB_H; i++) {
        uint32_t c = palette[indices[i]];
        uint8_t rgb[3] = { (uint8_t)(c >> 16), (uint8_t)(c >> 8), (uint8_t)c };
        fwrite(rgb, 1, 3, f);
    }
    fclose(f);
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    if (argc < 4) {
        fprintf(stderr, "usage: %s <sdram.bin> <doom.wad> <boot.bin> [max-frames]\n",
                argv[0]);
        return 2;
    }
    int max_frames = (argc > 4) ? atoi(argv[4]) : 3;

    std::vector<uint8_t> prog = read_file(argv[1]);
    std::vector<uint8_t> wad  = read_file(argv[2]);
    std::vector<uint8_t> boot = read_file(argv[3]);

    top = new Vtop;
    auto *root = top->rootp;

    // One evaluation first, so the RTL's own `initial` blocks run before
    // anything is loaded. memory.sv zeroes its arrays and then $readmemh's
    // whatever hex files are lying around; both happen on Verilator's first
    // eval, which is *after* main() starts. Loading before this point means the
    // program is silently replaced by the last test that left hex files behind.
    top->clk = 0;
    top->reset = 1;
    top->stall_rate = 0;
    top->mem_delay = 0;
    top->eval();

    // The reset stub, into on-chip instruction memory. Without this the core
    // resets into whatever the last test left in the hex files, which is a
    // confusing way to discover the harness only loaded half the program.
    mem_write(LANES(code_mem), 0, boot.data(), boot.size());

    // Program image at the base of SDRAM.
    mem_write(LANES(sdram), 0, prog.data(), prog.size());

    // WAD, behind a small header the program checks for. Placing it at a fixed
    // address rather than passing a pointer is what a real loader would do:
    // it writes memory before the core is released and has no other channel.
    uint32_t hdr[2] = { WAD_MAGIC, (uint32_t)wad.size() };
    uint32_t wad_off = WAD_ADDR - SDRAM_BASE;
    mem_write(LANES(sdram), wad_off, (uint8_t *)hdr, sizeof hdr);
    mem_write(LANES(sdram), wad_off + 8, wad.data(), wad.size());

    printf("loaded %zu byte boot stub, %zu byte program, %zu byte WAD at 0x%08x\n",
           boot.size(), prog.size(), wad.size(), WAD_ADDR);

    uint32_t palette[256];
    for (int i = 0; i < 256; i++) palette[i] = 0;

    std::vector<uint8_t> frame(FB_W * FB_H);
    int frames = 0;
    vluint64_t last_report = 0;

    while (!Verilated::gotFinish()) {
        if (main_time > 20) top->reset = 0;
        top->clk = 1; top->eval();
        top->clk = 0; top->eval();

        if (top->frame_done) {
            // Palette lives in the top as a plain array; read it out with the
            // frame so the colours match what the program had set at that point.
            for (int i = 0; i < 256; i++)
                palette[i] = root->top__DOT__palette[i];
            for (int i = 0; i < FB_W * FB_H; i++)
                frame[i] = mem_read8(LANES(fb_mem), (uint32_t)i);

            // Raw palette indices alongside the colour image. An all-black PPM
            // is ambiguous -- it means either nothing was drawn or the palette
            // never arrived -- and these two files tell those apart at a glance.
            char path[256];
            snprintf(path, sizeof path, "build/doom/frame%03d.idx", frames);
            FILE *rf = fopen(path, "wb");
            if (rf) { fwrite(frame.data(), 1, frame.size(), rf); fclose(rf); }

            int nonzero_idx = 0, nonzero_pal = 0;
            for (size_t i = 0; i < frame.size(); i++) if (frame[i]) nonzero_idx++;
            for (int i = 0; i < 256; i++) if (palette[i]) nonzero_pal++;
            printf("  indices non-zero: %d/%zu, palette entries set: %d/256\n",
                   nonzero_idx, frame.size(), nonzero_pal);

            snprintf(path, sizeof path, "build/doom/frame%03d.ppm", frames);
            write_ppm(path, frame.data(), palette);
            printf("frame %d captured at %llu cycles -> %s\n",
                   frames, (unsigned long long)main_time, path);
            if (++frames >= max_frames) break;
        }

        if (top->halt) { printf("halted at %llu cycles\n",
                                (unsigned long long)main_time); break; }

        if (main_time - last_report > 20000000ull) {
            last_report = main_time;
            printf("  ... %llu cycles, %d frames\n",
                   (unsigned long long)main_time, frames);
            fflush(stdout);
        }
        main_time++;
    }

    top->final();
    printf("stopped after %llu cycles, %d frames\n",
           (unsigned long long)main_time, frames);
    delete top;
    return frames > 0 ? 0 : 1;
}
