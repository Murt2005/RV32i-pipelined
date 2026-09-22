// Verilator harness for running Doom on the core and capturing what it draws.
//
//   build/doom/Vtop <doom.sdram.bin> <doom1.wad> <doom.boot.bin> [max-frames]

#include <verilated.h>
#include <verilated_save.h>
#include "Vtop.h"
#include "Vtop___024root.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <deque>
#include <ctime>
#include <termios.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <csignal>

// Must match bus/memory_map.sv
static const uint32_t SDRAM_BASE = 0x80000000u;
static const uint32_t FB_BASE    = 0x10000000u;
static const uint32_t WAD_ADDR   = 0x82000000u;
static const uint32_t WAD_MAGIC  = 0x57414421u;

static const int FB_W = 320, FB_H = 200;

static Vtop *top;
static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

static double wall_now()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

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

// Live keyboard input.
static struct termios tty_saved;
static bool           tty_raw = false;

static void tty_restore(void)
{
    if (tty_raw) {
        tcsetattr(STDIN_FILENO, TCSANOW, &tty_saved);
        tty_raw = false;
    }
}

static bool tty_make_raw(void)
{
    if (!isatty(STDIN_FILENO)) return false;
    if (tcgetattr(STDIN_FILENO, &tty_saved) != 0) return false;

    struct termios t = tty_saved;
    t.c_lflag &= ~(ICANON | ECHO);
    t.c_cc[VMIN]  = 0;
    t.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSANOW, &t) != 0) return false;

    fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL, 0) | O_NONBLOCK);
    tty_raw = true;
    atexit(tty_restore);
    return true;
}

// Drawing the framebuffer in the terminal
static FILE *tty_out    = nullptr;
static bool  tty_altscr = false;

static void tty_leave_altscreen(void)
{
    if (tty_altscr && tty_out) {
        fputs("\033[?1006l\033[?1002l", tty_out);
        fputs("\033[?25h\033[?1049l", tty_out);
        fflush(tty_out);
        tty_altscr = false;
    }
}

static bool tui_open(void)
{
    tty_out = fopen("/dev/tty", "w");
    if (!tty_out) return false;
    fputs("\033[?1049h\033[?25l\033[2J", tty_out);
    fputs("\033[?1002h\033[?1006h", tty_out);
    fflush(tty_out);
    tty_altscr = true;
    atexit(tty_leave_altscreen);
    return true;
}

static bool tui_truecolor(void)
{
    const char *ct = getenv("COLORTERM");
    if (ct && (strstr(ct, "truecolor") || strstr(ct, "24bit"))) return true;
    const char *t = getenv("TERM");
    return t && strstr(t, "direct");
}

static int rgb_to_256(int r, int g, int b)
{
    if (abs(r - g) < 12 && abs(g - b) < 12) {
        if (r < 8)   return 16;
        if (r > 248) return 231;
        return 232 + (r - 8) * 24 / 240;
    }
    return 16 + 36 * (r * 5 / 255) + 6 * (g * 5 / 255) + (b * 5 / 255);
}

static void tui_draw(const uint8_t *fb, const uint32_t *palette,
                     int frames, uint64_t cyc_delta, double secs)
{
    if (!tty_out) return;

    struct winsize ws;
    if (ioctl(fileno(tty_out), TIOCGWINSZ, &ws) != 0 || ws.ws_col == 0) {
        ws.ws_col = 80;
        ws.ws_row = 24;
    }

    int avail_w = ws.ws_col;
    int avail_h = (ws.ws_row - 1) * 2;
    if (avail_w < 8 || avail_h < 8) return;

    double s = (double)avail_w / FB_W;
    if ((double)avail_h / FB_H < s) s = (double)avail_h / FB_H;
    int out_w = (int)(FB_W * s);
    int out_h = (int)(FB_H * s) & ~1;
    if (out_w < 2 || out_h < 2) return;

    const bool tc = tui_truecolor();

    static std::string buf;
    buf.clear();
    buf.reserve((size_t)out_w * out_h * 20);
    buf += "\033[H";

    char tmp[64];
    for (int cy = 0; cy < out_h / 2; cy++) {
        int last_fg = -1, last_bg = -1;
        for (int cx = 0; cx < out_w; cx++) {
            int sx = cx * FB_W / out_w;
            int sy0 = (cy * 2)     * FB_H / out_h;
            int sy1 = (cy * 2 + 1) * FB_H / out_h;
            uint32_t top = palette[fb[sy0 * FB_W + sx]];
            uint32_t bot = palette[fb[sy1 * FB_W + sx]];

            int fg, bg;
            if (tc) {
                fg = (int)(top & 0xFFFFFF);
                bg = (int)(bot & 0xFFFFFF);
            } else {
                fg = rgb_to_256((top >> 16) & 0xFF, (top >> 8) & 0xFF, top & 0xFF);
                bg = rgb_to_256((bot >> 16) & 0xFF, (bot >> 8) & 0xFF, bot & 0xFF);
            }

            if (fg != last_fg) {
                if (tc) snprintf(tmp, sizeof tmp, "\033[38;2;%d;%d;%dm",
                                 (fg >> 16) & 0xFF, (fg >> 8) & 0xFF, fg & 0xFF);
                else    snprintf(tmp, sizeof tmp, "\033[38;5;%dm", fg);
                buf += tmp;
                last_fg = fg;
            }
            if (bg != last_bg) {
                if (tc) snprintf(tmp, sizeof tmp, "\033[48;2;%d;%d;%dm",
                                 (bg >> 16) & 0xFF, (bg >> 8) & 0xFF, bg & 0xFF);
                else    snprintf(tmp, sizeof tmp, "\033[48;5;%dm", bg);
                buf += tmp;
                last_bg = bg;
            }
            buf += "\xE2\x96\x80";
        }
        buf += "\033[0m\033[K\n";
    }

    snprintf(tmp, sizeof tmp,
             "frame %d   %.1f fps here (%.2f s/frame)   %.1f fps projected@50MHz   ",
             frames,
             secs > 0 ? 1.0 / secs : 0.0, secs,
             cyc_delta ? 50e6 / (double)cyc_delta : 0.0);
    buf += "\033[0m";
    buf += tmp;
    buf += "[q quit]\033[K";

    fwrite(buf.data(), 1, buf.size(), tty_out);
    fflush(tty_out);
}

static void fatal_signal(int sig)
{
    tty_leave_altscreen();
    tty_restore();
    signal(sig, SIG_DFL);
    raise(sig);
}

static void install_signal_handlers(void)
{
    for (int s : {SIGINT, SIGTERM, SIGHUP, SIGQUIT})
        signal(s, fatal_signal);
}

enum {
    DK_RIGHT = 0xae, DK_LEFT = 0xac, DK_UP = 0xad, DK_DOWN = 0xaf,
    DK_STRAFEL = 0xa0, DK_STRAFER = 0xa1, DK_USE = 0xa2, DK_FIRE = 0xa3,
    DK_ESCAPE = 27, DK_ENTER = 13, DK_TAB = 9,
};

static const char *live_help =
    "\n"
    "  live input:  arrows or WASD move    , . strafe    space use\n"
    "               f or ctrl fire         enter select  esc menu\n"
    "               tab map                y yes         q quit\n\n";

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

    // Snapshot and restore.
    const char *save_path = getenv("DOOM_SAVE");
    const char *load_path = getenv("DOOM_LOAD");
    int save_at_frame = 1;
    if (const char *e = getenv("DOOM_SAVE_FRAME")) save_at_frame = atoi(e);

    top->clk = 0;
    top->reset = 1;
    top->stall_rate = 0;
    top->mem_delay  = 0;
    if (const char *e = getenv("RV32_MEM_LATENCY")) top->mem_delay  = (uint8_t)atoi(e);
    if (const char *e = getenv("RV32_STALL_RATE"))  top->stall_rate = (uint8_t)atoi(e);
    printf("mem_delay=%u stall_rate=%u\n", top->mem_delay, top->stall_rate);
    top->eval();

    if (load_path) {
        double t0 = wall_now();
        VerilatedRestore rs;
        rs.open(load_path);
        if (!rs.isOpen()) {
            fprintf(stderr, "cannot open snapshot %s\n", load_path);
            return 2;
        }
        rs >> *top;
        rs.close();
        std::string sidecar = std::string(load_path) + ".meta";
        if (FILE *mf = fopen(sidecar.c_str(), "rb")) {
            if (fread(&main_time, sizeof main_time, 1, mf) != 1) main_time = 0;
            fclose(mf);
        }
        printf("restored snapshot %s at %llu cycles in %.2f s\n",
               load_path, (unsigned long long)main_time, wall_now() - t0);
    } else {
        mem_write(LANES(code_mem), 0, boot.data(), boot.size());

        mem_write(LANES(sdram), 0, prog.data(), prog.size());

        uint32_t hdr[2] = { WAD_MAGIC, (uint32_t)wad.size() };
        uint32_t wad_off = WAD_ADDR - SDRAM_BASE;
        mem_write(LANES(sdram), wad_off, (uint8_t *)hdr, sizeof hdr);
        mem_write(LANES(sdram), wad_off + 8, wad.data(), wad.size());

        printf("loaded %zu byte boot stub, %zu byte program, %zu byte WAD at 0x%08x\n",
               boot.size(), prog.size(), wad.size(), WAD_ADDR);
    }

    uint32_t palette[256];
    for (int i = 0; i < 256; i++) palette[i] = 0;

    struct KeyEvent { int frame; int pressed; int code; };
    std::vector<KeyEvent> script;
    if (const char *sp = getenv("DOOM_KEYS")) {
        FILE *kf = fopen(sp, "r");
        if (kf) {
            char line[256];
            while (fgets(line, sizeof line, kf)) {
                char *p = line;
                while (*p == ' ' || *p == '\t') p++;
                if (*p == '#' || *p == '\n' || *p == '\0') continue;
                char what[16]; int fr, code;
                if (sscanf(p, "%d %15s %i", &fr, what, &code) == 3)
                    script.push_back({fr, strcmp(what, "up") != 0, code});
            }
            fclose(kf);
            printf("loaded %zu key events from %s\n", script.size(), sp);
        } else {
            fprintf(stderr, "cannot open key script %s\n", sp);
        }
    }
    size_t next_key = 0;

    bool live = getenv("DOOM_LIVE") && atoi(getenv("DOOM_LIVE")) != 0;
    install_signal_handlers();
    if (live && !tty_make_raw()) {
        fprintf(stderr, "DOOM_LIVE set but stdin is not a terminal; ignoring\n");
        live = false;
    }
    int hold_frames = 2;
    if (const char *e = getenv("DOOM_HOLD")) hold_frames = atoi(e);

    const bool trace_input = getenv("DOOM_TRACE_INPUT")
                          && atoi(getenv("DOOM_TRACE_INPUT")) != 0;

    std::deque<KeyEvent> pending;
    int held[256];
    for (int i = 0; i < 256; i++) held[i] = 0;
    bool quit = false;

    bool tui = live;
    if (const char *e = getenv("DOOM_TUI")) tui = atoi(e) != 0;
    if (tui && !tui_open()) {
        fprintf(stderr, "cannot open /dev/tty for display\n");
        tui = false;
    }

    bool capture = true;
    if (const char *e = getenv("DOOM_CAPTURE")) capture = atoi(e) != 0;

    if (live && !tui) printf("%s", live_help);

    auto map_key = [](unsigned char c, bool arrow) -> int {
        if (arrow) {
            switch (c) {
                case 'A': return DK_UP;
                case 'B': return DK_DOWN;
                case 'C': return DK_RIGHT;
                case 'D': return DK_LEFT;
                default:  return 0;
            }
        }
        switch (c) {
            case 'w': case 'W': return DK_UP;
            case 's': case 'S': return DK_DOWN;
            case 'a': case 'A': return DK_LEFT;
            case 'd': case 'D': return DK_RIGHT;
            case ',':           return DK_STRAFEL;
            case '.':           return DK_STRAFER;
            case ' ':           return DK_USE;
            case 'f': case 'F':
            case 0x00:                        /* ctrl-space, some terminals */
            case 0x06:          return DK_FIRE;   /* ctrl-f */
            case '\r': case '\n': return DK_ENTER;
            case 0x1b:          return DK_ESCAPE;
            case '\t':          return DK_TAB;
            case 'y': case 'Y': return 'y';
            default:            return 0;
        }
    };

    // PC sampling profiler.
    const char *prof_path = getenv("DOOM_PROFILE");
    int prof_from = 0;
    if (const char *e = getenv("DOOM_PROFILE_FROM")) prof_from = atoi(e);
    static const uint32_t PROF_BASE  = SDRAM_BASE;
    static const size_t   PROF_WORDS = 1u << 20;      // 4 MiB of text
    std::vector<uint32_t> prof;
    uint64_t prof_other = 0, prof_samples = 0;
    if (prof_path) prof.assign(PROF_WORDS, 0);

    vluint64_t max_cycles = 0;
    if (const char *e = getenv("RV32_MAX_CYCLES"))
        max_cycles = strtoull(e, nullptr, 0);

    std::vector<uint8_t> frame(FB_W * FB_H);
    int frames = 0;
    vluint64_t last_report = 0;
    const double  t_start   = wall_now();
    double        t_report  = t_start;
    double        t_frame   = t_start;
    vluint64_t    cyc_frame = 0;

    while (!Verilated::gotFinish()) {
        if (main_time > 20) top->reset = 0;

        if (live && (main_time & 0x3FFF) == 0) {
            unsigned char buf[64];
            ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
            for (ssize_t i = 0; i < n; i++) {
                if (buf[i] == 'q') { quit = true; break; }

                if (buf[i] == 0x1b && i + 3 < n
                    && buf[i + 1] == '[' && buf[i + 2] == '<') {
                    ssize_t j = i + 3;
                    int btn = 0, field = 0;
                    while (j < n && buf[j] != 'M' && buf[j] != 'm') {
                        if (buf[j] == ';')      field++;
                        else if (field == 0 && buf[j] >= '0' && buf[j] <= '9')
                            btn = btn * 10 + (buf[j] - '0');
                        j++;
                    }
                    if (j >= n) break;
                    bool down = (buf[j] == 'M');
                    int which = btn & 3;
                    if (!(btn & 64) && which != 3) {
                        int code = (which == 0) ? DK_FIRE
                                 : (which == 2) ? DK_USE : 0;
                        printf("  mouse btn=%d %s -> code 0x%02x at frame %d\n",
                               which, down ? "down" : "up", code, frames);
                        fflush(stdout);
                        if (code) {
                            if (down) {
                                if (held[code] == 0)
                                    pending.push_back({0, 1, code});
                                else if (trace_input)
                                    printf("  (press dropped, held=%d)\n", held[code]);
                                held[code] = hold_frames;
                            }
                        }
                    }
                    i = j;
                    continue;
                }

                bool arrow = false;
                if (buf[i] == 0x1b && i + 2 < n && buf[i + 1] == '[') {
                    arrow = true;
                    i += 2;
                }
                int code = map_key(buf[i], arrow);
                if (!code) continue;

                if (held[code] == 0)
                    pending.push_back({0, 1, code});
                held[code] = hold_frames;
            }
        }

        top->key_strobe = 0;
        if (!pending.empty()) {
            KeyEvent e = pending.front(); pending.pop_front();
            top->key_strobe = 1;
            top->key_event  = (uint16_t)((e.pressed << 8) | (e.code & 0xFF));
            if (trace_input) {
                printf("  inject %s 0x%02x at frame %d cycle %llu\n",
                       e.pressed ? "down" : "up", e.code, frames,
                       (unsigned long long)main_time);
                fflush(stdout);
            }
        } else if (next_key < script.size() && script[next_key].frame <= frames) {
            top->key_strobe = 1;
            top->key_event  = (uint16_t)((script[next_key].pressed << 8)
                                       | (script[next_key].code & 0xFF));
            printf("  key %s 0x%02x at frame %d\n",
                   script[next_key].pressed ? "down" : "up",
                   script[next_key].code, frames);
            next_key++;
        }
        top->clk = 1; top->eval();
        top->clk = 0; top->eval();

        if (!prof.empty() && frames >= prof_from && (main_time & 0x3F) == 0) {
            uint32_t pc = root->top__DOT__the_core__DOT__fetch_m__DOT__fetch_pc;
            uint32_t off = (pc - PROF_BASE) >> 2;
            if (pc >= PROF_BASE && off < PROF_WORDS) prof[off]++;
            else                                     prof_other++;
            prof_samples++;
        }

        if (top->frame_done) {
            for (int i = 0; i < 256; i++)
                palette[i] = root->top__DOT__palette[i];
            for (int i = 0; i < FB_W * FB_H; i++)
                frame[i] = mem_read8(LANES(fb_mem), (uint32_t)i);

            int nonzero_pal = 0;
            for (int i = 0; i < 256; i++) if (palette[i]) nonzero_pal++;

            char path[256];
            if (capture) {
                snprintf(path, sizeof path, "build/doom/frame%03d.idx", frames);
                FILE *rf = fopen(path, "wb");
                if (rf) { fwrite(frame.data(), 1, frame.size(), rf); fclose(rf); }

                int nonzero_idx = 0;
                for (size_t i = 0; i < frame.size(); i++) if (frame[i]) nonzero_idx++;
                printf("  indices non-zero: %d/%zu, palette entries set: %d/256\n",
                       nonzero_idx, frame.size(), nonzero_pal);

                snprintf(path, sizeof path, "build/doom/frame%03d.ppm", frames);
                write_ppm(path, frame.data(), palette);
            }

            double now = wall_now();
            vluint64_t dc = main_time - cyc_frame;
            printf("frame %d captured at %llu cycles"
                   " (+%llu cyc, %.2f s wall, %.2f fps @50MHz)\n",
                   frames, (unsigned long long)main_time,
                   (unsigned long long)dc, now - t_frame,
                   dc ? 50e6 / (double)dc : 0.0);

            if (tui)
                tui_draw(frame.data(), palette, frames, dc, now - t_frame);

            t_frame = now;
            cyc_frame = main_time;
            frames++;

            for (int c = 0; c < 256; c++) {
                if (held[c] && --held[c] == 0)
                    pending.push_back({0, 0, c});
            }

            if (save_path && frames == save_at_frame) {
                double t0 = wall_now();

                if (nonzero_pal == 0)
                    fprintf(stderr,
                            "warning: snapshot at frame %d has an empty palette;"
                            " restored runs will render black until Doom next"
                            " sets it. Snapshot a later frame"
                            " (DOOM_SAVE_FRAME >= 110).\n", frames);

                VerilatedSave os;
                os.open(save_path);
                if (!os.isOpen()) {
                    fprintf(stderr, "cannot write snapshot %s\n", save_path);
                    return 2;
                }
                os << *top;
                os.close();
                std::string sidecar = std::string(save_path) + ".meta";
                if (FILE *mf = fopen(sidecar.c_str(), "wb")) {
                    vluint64_t resume_at = main_time + 1;
                    fwrite(&resume_at, sizeof resume_at, 1, mf);
                    fclose(mf);
                }
                printf("saved snapshot %s at %llu cycles in %.2f s\n",
                       save_path, (unsigned long long)main_time,
                       wall_now() - t0);
                break;
            }

            if (max_frames && frames >= max_frames) break;
        }

        if (top->halt) { printf("halted at %llu cycles\n",
                                (unsigned long long)main_time); break; }

        if (quit) { printf("quit\n"); break; }

        if (max_cycles && main_time >= max_cycles) {
            printf("cycle budget %llu reached\n",
                   (unsigned long long)max_cycles);
            break;
        }

        if (main_time - last_report > 20000000ull) {
            double now = wall_now();
            printf("  ... %llu cycles, %d frames, %.2f Mcyc/s\n",
                   (unsigned long long)main_time, frames,
                   (double)(main_time - last_report) / (now - t_report) / 1e6);
            last_report = main_time;
            t_report = now;
            fflush(stdout);
        }
        main_time++;
    }

    if (!prof.empty()) {
        FILE *pf = fopen(prof_path, "w");
        if (pf) {
            fprintf(pf, "# pc-samples total=%llu outside=%llu\n",
                    (unsigned long long)prof_samples,
                    (unsigned long long)prof_other);
            for (size_t i = 0; i < PROF_WORDS; i++)
                if (prof[i])
                    fprintf(pf, "%08x %u\n",
                            (unsigned)(PROF_BASE + (i << 2)), prof[i]);
            fclose(pf);
            printf("profile: %llu samples from frame %d onward -> %s\n",
                   (unsigned long long)prof_samples, prof_from, prof_path);
        }
    }

    top->final();
    double elapsed = wall_now() - t_start;
    printf("stopped after %llu cycles, %d frames"
           " in %.1f s wall (%.2f Mcyc/s)\n",
           (unsigned long long)main_time, frames, elapsed,
           (double)main_time / elapsed / 1e6);
    delete top;
    return frames > 0 ? 0 : 1;
}
