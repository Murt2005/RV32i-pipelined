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

// Must match bus/memory_map.sv.
static const uint32_t SDRAM_BASE = 0x80000000u;
static const uint32_t FB_BASE    = 0x10000000u;
static const uint32_t WAD_ADDR   = 0x82000000u;   // where the port layer looks
static const uint32_t WAD_MAGIC  = 0x57414421u;   // "WAD!"

static const int FB_W = 320, FB_H = 200;

static Vtop *top;
static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

// Wall-clock seconds. The thing being optimised here is simulated cycles per
// second of real time, and it is not deducible from the cycle counts alone --
// so the harness reports it rather than leaving it to be timed from outside.
static double wall_now()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

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

// ---------------------------------------------------------------------------
// Live keyboard input.
//
// Doom is far too slow here to play in any normal sense -- a frame is a
// fraction of a second of wall clock rather than a fortieth -- but it is fast
// enough to *drive*, and typing at it beats editing a script and waiting out a
// four-minute boot to find out the sequence was wrong.
//
// Two things a terminal does not give us, and how each is handled.
//
// It reports presses, not releases. Doom needs both: a movement key that is
// never released moves forever. So every press starts a hold, and the key is
// released automatically a few frames later. Terminal auto-repeat, which fires
// far faster than frames arrive here, refreshes the hold -- so holding a key
// down really does keep walking.
//
// Arrow keys arrive as three bytes, ESC [ A..D, and bare ESC is itself a Doom
// key. They are told apart by looking at what else is already in the buffer:
// the whole sequence arrives from one read(), so an ESC with a '[' behind it is
// an arrow and an ESC alone is the menu.
// ---------------------------------------------------------------------------
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
    // Character at a time, no echo. Doom is drawing the screen; a shell echoing
    // the keys on top of the frame counter is only noise.
    t.c_lflag &= ~(ICANON | ECHO);
    t.c_cc[VMIN]  = 0;
    t.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSANOW, &t) != 0) return false;

    fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL, 0) | O_NONBLOCK);
    tty_raw = true;
    atexit(tty_restore);
    return true;
}

// ---------------------------------------------------------------------------
// Drawing the framebuffer in the terminal.
//
// The point is to see the game while playing it, in the window the keystrokes
// are already going to, with nothing installed. A window would mean SDL, and
// SDL would mean the one machine that has it.
//
// Each character cell carries two pixels: U+2580 UPPER HALF BLOCK, foreground
// for the top pixel and background for the bottom. That halves the vertical
// squash and makes the cell roughly square, since terminal cells are about
// twice as tall as they are wide.
//
// Output goes to /dev/tty rather than stdout, and that is the load-bearing
// detail. top.sv:283 does `$write("%c", ...)` for the putchar MMIO, so Doom's
// own text comes out of the RTL on stdout, underneath the harness. Rendering to
// stdout would interleave the two and shred the picture. /dev/tty is the
// controlling terminal whatever stdout has been redirected to, so the image
// goes to the screen and the text goes to a log.
// ---------------------------------------------------------------------------
static FILE *tty_out    = nullptr;
static bool  tty_altscr = false;

static void tty_leave_altscreen(void)
{
    if (tty_altscr && tty_out) {
        fputs("\033[?25h\033[?1049l", tty_out);   // show cursor, restore screen
        fflush(tty_out);
        tty_altscr = false;
    }
}

static bool tui_open(void)
{
    tty_out = fopen("/dev/tty", "w");
    if (!tty_out) return false;
    fputs("\033[?1049h\033[?25l\033[2J", tty_out);  // alt screen, hide cursor, clear
    fflush(tty_out);
    tty_altscr = true;
    atexit(tty_leave_altscreen);
    return true;
}

// Truecolor where the terminal admits to it, the 256-colour cube otherwise.
// Terminal.app is the case that matters here: it does 256 colours and silently
// makes a mess of 24-bit escapes.
static bool tui_truecolor(void)
{
    const char *ct = getenv("COLORTERM");
    if (ct && (strstr(ct, "truecolor") || strstr(ct, "24bit"))) return true;
    const char *t = getenv("TERM");
    return t && strstr(t, "direct");
}

static int rgb_to_256(int r, int g, int b)
{
    // Greys are a separate ramp and much finer than the cube's diagonal, which
    // matters for Doom -- a lot of the screen is smoke, shadow and status bar.
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

    // One row is kept for the status line. Two source pixels per cell row.
    int avail_w = ws.ws_col;
    int avail_h = (ws.ws_row - 1) * 2;
    if (avail_w < 8 || avail_h < 8) return;

    // Fit while preserving the 320x200 aspect.
    double s = (double)avail_w / FB_W;
    if ((double)avail_h / FB_H < s) s = (double)avail_h / FB_H;
    int out_w = (int)(FB_W * s);
    int out_h = (int)(FB_H * s) & ~1;          // even: cells are pixel pairs
    if (out_w < 2 || out_h < 2) return;

    const bool tc = tui_truecolor();

    // Built in one buffer and written once. A cell at a time through fprintf
    // is thousands of syscalls a frame and visibly tears.
    static std::string buf;
    buf.clear();
    buf.reserve((size_t)out_w * out_h * 20);
    buf += "\033[H";                            // home, not clear -- no flicker

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

            // Only re-state a colour when it actually changes. Doom has large
            // flat regions and this cuts the output several-fold.
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
            buf += "\xE2\x96\x80";              // U+2580
        }
        buf += "\033[0m\033[K\n";               // reset, clear to EOL
    }

    snprintf(tmp, sizeof tmp, "frame %d  %.2f s  %.1f fps@50MHz  ",
             frames, secs, cyc_delta ? 50e6 / (double)cyc_delta : 0.0);
    buf += "\033[0m";
    buf += tmp;
    buf += "[q quit]\033[K";

    fwrite(buf.data(), 1, buf.size(), tty_out);
    fflush(tty_out);
}

// Put the terminal back on the way out, however we are leaving.
//
// atexit() alone is not enough and the gap is not hypothetical: it does not run
// when the process is signalled, and ^C is the obvious way to quit something
// that has taken over the screen. Without this, quitting leaves the terminal in
// raw mode -- no echo, no line editing, no cursor, still on the alternate
// screen -- and the only fix is `reset` typed blind. Restoring is idempotent
// and the handlers only touch async-signal-safe calls before re-raising, so the
// exit status still reflects the signal.
static void fatal_signal(int sig)
{
    tty_leave_altscreen();
    tty_restore();
    signal(sig, SIG_DFL);
    raise(sig);
}

static void install_signal_handlers(void)
{
    // SIGHUP matters as much as SIGINT here: closing the terminal window, or a
    // dropped ssh session, arrives that way.
    for (int s : {SIGINT, SIGTERM, SIGHUP, SIGQUIT})
        signal(s, fatal_signal);
}

// doomkeys.h. Repeated here rather than included because the harness is host
// code and that header is built for the target.
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
    int max_frames = (argc > 4) ? atoi(argv[4]) : 3;   // 0 means run until quit

    std::vector<uint8_t> prog = read_file(argv[1]);
    std::vector<uint8_t> wad  = read_file(argv[2]);
    std::vector<uint8_t> boot = read_file(argv[3]);

    top = new Vtop;
    auto *root = top->rootp;

    // ------------------------------------------------------------------
    // Snapshot and restore.
    //
    // Doom takes 327 million cycles to reach its first frame -- over a minute
    // of wall clock -- and every one of those cycles is spent doing exactly the
    // same thing: zeroing the zone heap, reading the WAD directory, building
    // the renderer's lookup tables. Paying it again on every run is what makes
    // this thing tedious to use rather than slow to use.
    //
    // So the whole model state gets serialised once, after boot, and restored
    // in about a second thereafter. This is the difference between "start it
    // and go and do something else" and "start it and play".
    //
    // Restore happens after the first eval() deliberately: eval() is when
    // Verilator runs the RTL's `initial` blocks, and restoring before that
    // would have them overwrite the snapshot with their reset values.
    // ------------------------------------------------------------------
    const char *save_path = getenv("DOOM_SAVE");
    const char *load_path = getenv("DOOM_LOAD");
    int save_at_frame = 1;
    if (const char *e = getenv("DOOM_SAVE_FRAME")) save_at_frame = atoi(e);

    // One evaluation first, so the RTL's own `initial` blocks run before
    // anything is loaded. memory.sv zeroes its arrays and then $readmemh's
    // whatever hex files are lying around; both happen on Verilator's first
    // eval, which is *after* main() starts. Loading before this point means the
    // program is silently replaced by the last test that left hex files behind.
    top->clk = 0;
    top->reset = 1;
    // Both default to zero, which is a memory that never makes anyone wait --
    // fine for checking that Doom renders, useless for predicting what it will
    // do on a board. Real SDRAM costs tens of cycles on a miss.
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
        // main_time is the harness's own counter, not model state, so it rides
        // along in a sidecar file. Without it the resumed run reports cycle
        // numbers starting from zero and every rate is wrong.
        std::string sidecar = std::string(load_path) + ".meta";
        if (FILE *mf = fopen(sidecar.c_str(), "rb")) {
            if (fread(&main_time, sizeof main_time, 1, mf) != 1) main_time = 0;
            fclose(mf);
        }
        printf("restored snapshot %s at %llu cycles in %.2f s\n",
               load_path, (unsigned long long)main_time, wall_now() - t0);
    } else {
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
    }

    uint32_t palette[256];
    for (int i = 0; i < 256; i++) palette[i] = 0;

    // Scripted input: "<frame> <down|up> <keycode>" per line. Doom is driven
    // rather than played -- a frame costs a second or two of wall clock, so
    // real-time interaction is not on the table, but a canned sequence gets it
    // off the title screen and into the game.
    struct KeyEvent { int frame; int pressed; int code; };
    std::vector<KeyEvent> script;
    if (const char *sp = getenv("DOOM_KEYS")) {
        FILE *kf = fopen(sp, "r");
        if (kf) {
            // Line at a time, because fscanf("%d ...") stops dead on the
            // first comment and silently yields an empty script -- which looks
            // exactly like Doom ignoring the input.
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

    // Live mode. DOOM_LIVE=1, and stdin must actually be a terminal -- under a
    // pipe or in CI there is nothing to read and raw mode would be wrong.
    bool live = getenv("DOOM_LIVE") && atoi(getenv("DOOM_LIVE")) != 0;
    install_signal_handlers();
    if (live && !tty_make_raw()) {
        fprintf(stderr, "DOOM_LIVE set but stdin is not a terminal; ignoring\n");
        live = false;
    }
    // How many frames a press stays held before the automatic release. Two is
    // enough that a tap turns into visible movement without overshooting badly.
    int hold_frames = 2;
    if (const char *e = getenv("DOOM_HOLD")) hold_frames = atoi(e);

    std::deque<KeyEvent> pending;     // live events, injected as soon as possible
    int held[256];                    // frames of hold left, per keycode
    for (int i = 0; i < 256; i++) held[i] = 0;
    bool quit = false;

    // Draw in the terminal. On by default in live mode -- an interactive run
    // that shows nothing is not interactive -- and available on its own for
    // watching a scripted run go past.
    bool tui = live;
    if (const char *e = getenv("DOOM_TUI")) tui = atoi(e) != 0;
    if (tui && !tui_open()) {
        fprintf(stderr, "cannot open /dev/tty for display\n");
        tui = false;
    }

    // Writing two 64 KB files per frame is pure overhead if nobody is going to
    // look at them. It stays on by default so a session still leaves something
    // doom-gif can use.
    bool capture = true;
    if (const char *e = getenv("DOOM_CAPTURE")) capture = atoi(e) != 0;

    if (live && !tui) printf("%s", live_help);

    // One terminal byte -> one Doom keycode. Returns 0 for keys we do not map.
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

    // A cycle budget, so a benchmark run stops at a fixed amount of work rather
    // than a fixed amount of time. Comparing two builds needs the numerator
    // held still; timing "however far it got in 60 seconds" compares nothing.
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

        // Drain the terminal every so often rather than every cycle. A read()
        // syscall costs far more than a cycle of this model, and at four
        // million cycles a second this is still a poll every few milliseconds --
        // far below anything a person can perceive.
        if (live && (main_time & 0x3FFF) == 0) {
            unsigned char buf[64];
            ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
            for (ssize_t i = 0; i < n; i++) {
                if (buf[i] == 'q') { quit = true; break; }

                bool arrow = false;
                // ESC [ X, and only when the rest of the sequence is already
                // here -- otherwise this is the menu key.
                if (buf[i] == 0x1b && i + 2 < n && buf[i + 1] == '[') {
                    arrow = true;
                    i += 2;
                }
                int code = map_key(buf[i], arrow);
                if (!code) continue;

                // Re-pressing a key that is already held refreshes the hold
                // rather than emitting a second press, which is what makes
                // terminal auto-repeat read as "still holding it down".
                if (held[code] == 0)
                    pending.push_back({0, 1, code});
                held[code] = hold_frames;
            }
        }

        // Inject at most one event per cycle; the queue in the MMIO block holds
        // a few so a burst between polls is not lost.
        top->key_strobe = 0;
        if (!pending.empty()) {
            KeyEvent e = pending.front(); pending.pop_front();
            top->key_strobe = 1;
            top->key_event  = (uint16_t)((e.pressed << 8) | (e.code & 0xFF));
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

        if (top->frame_done) {
            // Palette lives in the top as a plain array; read it out with the
            // frame so the colours match what the program had set at that point.
            for (int i = 0; i < 256; i++)
                palette[i] = root->top__DOT__palette[i];
            for (int i = 0; i < FB_W * FB_H; i++)
                frame[i] = mem_read8(LANES(fb_mem), (uint32_t)i);

            int nonzero_pal = 0;
            for (int i = 0; i < 256; i++) if (palette[i]) nonzero_pal++;

            char path[256];
            if (capture) {
                // Raw palette indices alongside the colour image. An all-black
                // PPM is ambiguous -- it means either nothing was drawn or the
                // palette never arrived -- and these two tell those apart.
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

            // Two rates, and they answer different questions. Cycles per frame
            // is what the board will do; seconds per frame is what this
            // simulation does, and only the second one moves when the harness
            // is made faster.
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

            // Age the held keys and release the ones that ran out. Done on the
            // frame boundary because Doom consumes input once a tic, so a hold
            // measured in cycles would be a hold of unpredictable length.
            for (int c = 0; c < 256; c++) {
                if (held[c] && --held[c] == 0)
                    pending.push_back({0, 0, c});
            }

            // Snapshot on a frame boundary, which is a clean place to stop: the
            // framebuffer holds a whole picture and Doom is between tics.
            if (save_path && frames == save_at_frame) {
                double t0 = wall_now();

                // Doom only pushes the palette when it changes, and the first
                // change comes after the title melt -- roughly frame 100. A
                // snapshot taken before that is faithful to the hardware and
                // completely useless: every frame restored from it renders
                // black, because the palette register really is all zero, and
                // it stays that way until Doom next happens to update it.
                // Cheaper to say so here than to debug a black screen later.
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
                // main_time+1, not main_time: the snapshot is taken before the
                // increment at the bottom of the loop, and the restored run
                // resumes at the loop top. Saving the raw value leaves every
                // cycle count after a restore one short of the run it resumed,
                // which is a confusing thing to discover mid-measurement.
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

    top->final();
    double elapsed = wall_now() - t_start;
    printf("stopped after %llu cycles, %d frames"
           " in %.1f s wall (%.2f Mcyc/s)\n",
           (unsigned long long)main_time, frames, elapsed,
           (double)main_time / elapsed / 1e6);
    delete top;
    return frames > 0 ? 0 : 1;
}
