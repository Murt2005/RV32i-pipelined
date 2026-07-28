/*
 * The bottom of newlib, for this machine.
 *
 * libmc was a hand-written freestanding library with no malloc, no file I/O and
 * no memcpy, and a printf that silently drops the `l` in %ld. Doom needs all of
 * those, so C programs that run from SDRAM link against newlib instead and
 * newlib calls the handful of functions below. libmc is untouched and the
 * assembly test suite still uses it.
 *
 * The whole "operating system" here is two memory-mapped words: one to print a
 * byte, one to stop the machine. Everything else is either backed by a file
 * image already in memory or is honestly a stub.
 */

#include <errno.h>
#include <stddef.h>
#include <sys/times.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define MMIO_PUTCHAR ((volatile unsigned int *)0x0002FFF8)
#define MMIO_HALT    ((volatile unsigned int *)0x0002FFFC)

/* Set by the linker script; the heap starts here and grows up through SDRAM. */
extern char _end;

/* ------------------------------------------------------------------ */
/* An in-memory file, so fopen/fread can be pointed at a WAD that was  */
/* loaded into SDRAM rather than at a filesystem this machine has not  */
/* got. Registered by the program before it opens anything.            */
/* ------------------------------------------------------------------ */
#define MAX_FILES 4

typedef struct {
    const char   *name;
    unsigned char *data;
    long          size;
    long          pos;
    int           open;
} ramfile;

static ramfile files[MAX_FILES];

void ramfile_register(const char *name, void *data, long size)
{
    for (int i = 0; i < MAX_FILES; i++) {
        if (files[i].name == 0) {
            files[i].name = name;
            files[i].data = (unsigned char *)data;
            files[i].size = size;
            files[i].pos  = 0;
            files[i].open = 0;
            return;
        }
    }
}

static int name_eq(const char *a, const char *b)
{
    /* Compare on the basename only. Doom is given a path and this machine has
     * no directories, so "/usr/share/doom1.wad" has to find "doom1.wad". */
    const char *sa = a, *sb = b, *p;
    for (p = a; *p; p++) if (*p == '/') sa = p + 1;
    for (p = b; *p; p++) if (*p == '/') sb = p + 1;
    while (*sa && *sb && *sa == *sb) { sa++; sb++; }
    return *sa == 0 && *sb == 0;
}

/* fd 0,1,2 are the standard streams; ram files start above them. */
#define FD_BASE 3

int _open(const char *name, int flags, int mode)
{
    (void)flags; (void)mode;
    for (int i = 0; i < MAX_FILES; i++) {
        if (files[i].name && name_eq(files[i].name, name)) {
            files[i].open = 1;
            files[i].pos  = 0;
            return FD_BASE + i;
        }
    }
    errno = ENOENT;
    return -1;
}

int _close(int fd)
{
    int i = fd - FD_BASE;
    if (i >= 0 && i < MAX_FILES && files[i].open) {
        files[i].open = 0;
        return 0;
    }
    return fd <= 2 ? 0 : -1;
}

int _read(int fd, char *buf, int len)
{
    int i = fd - FD_BASE;
    if (i < 0 || i >= MAX_FILES || !files[i].open)
        return -1;
    long left = files[i].size - files[i].pos;
    if (len > left) len = (int)left;
    for (int k = 0; k < len; k++)
        buf[k] = (char)files[i].data[files[i].pos + k];
    files[i].pos += len;
    return len;
}

int _write(int fd, const char *buf, int len)
{
    (void)fd;                       /* stdout and stderr both go to the console */
    for (int i = 0; i < len; i++)
        *MMIO_PUTCHAR = (unsigned char)buf[i];
    return len;
}

off_t _lseek(int fd, off_t off, int whence)
{
    int i = fd - FD_BASE;
    if (i < 0 || i >= MAX_FILES || !files[i].open)
        return 0;                   /* the standard streams are not seekable */
    long base = (whence == SEEK_CUR) ? files[i].pos
              : (whence == SEEK_END) ? files[i].size
                                     : 0;
    long p = base + off;
    if (p < 0) p = 0;
    if (p > files[i].size) p = files[i].size;
    files[i].pos = p;
    return p;
}

int _fstat(int fd, struct stat *st)
{
    int i = fd - FD_BASE;
    st->st_mode = S_IFCHR;
    if (i >= 0 && i < MAX_FILES && files[i].open) {
        st->st_mode = S_IFREG;
        st->st_size = files[i].size;
    }
    return 0;
}

int _isatty(int fd) { return fd <= 2; }

/* ------------------------------------------------------------------ */
/* Heap. Grows up from _end through SDRAM. There is no upper bound     */
/* check against the stack because the stack is in a different memory  */
/* entirely -- see tests/sdram/boot.s.                                 */
/* ------------------------------------------------------------------ */
void *_sbrk(ptrdiff_t incr)
{
    static char *brk = 0;
    if (brk == 0) brk = &_end;
    char *prev = brk;
    brk += incr;
    return prev;
}

void _exit(int code)
{
    *MMIO_HALT = (unsigned int)code;
    for (;;) { }
}

int _kill(int pid, int sig) { (void)pid; (void)sig; errno = EINVAL; return -1; }
int _getpid(void)           { return 1; }

/* Doom asks for these; nothing here has a clock or a filesystem to change. */
int _unlink(const char *name)              { (void)name; errno = ENOENT; return -1; }
int _link(const char *a, const char *b)    { (void)a; (void)b; errno = EMLINK; return -1; }
int _stat(const char *f, struct stat *st)  { (void)f; st->st_mode = S_IFCHR; return 0; }
clock_t _times(struct tms *buf)            { (void)buf; return (clock_t)-1; }

/* Doom calls this to create its save directory. There is no filesystem, and
 * saving is not part of running the game, so it succeeds and does nothing --
 * failing would send Doom down an error path for something it never uses. */
int mkdir(const char *path, mode_t mode) { (void)path; (void)mode; return 0; }
