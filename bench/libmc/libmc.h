#ifndef _libmc_h
#define _libmc_h

#include "base.h"

typedef __builtin_va_list __gnuc_va_list;
typedef __gnuc_va_list va_list;
#define va_start(v,l)   __builtin_va_start(v,l)
#define va_end(v)       __builtin_va_end(v)
#define va_arg(v,l)     __builtin_va_arg(v,l)
#if !defined(__STRICT_ANSI__) || __STDC_VERSION__ + 0 >= 199900L \
    || __cplusplus + 0 >= 201103L
#define va_copy(d,s)    __builtin_va_copy(d,s)
#endif
#define __va_copy(d,s)  __builtin_va_copy(d,s)

void use(int);
void use_ptr(void *);
void mmio_write32(void *addr, uint32_t data);
uint32_t mmio_read32(void *addr);
void mmio_write8(void *addr, uint8_t data);
uint8_t mmio_read8(void *addr);
#ifdef _64bit
void mmio_write64(void *addr, uint64_t data);
uint64_t mmio_read64(void *addr);
uint64_t amoswap64(uint64_t *addr, uint64_t value);

#define mmio_write_native mmio_write64
#define mmio_read_native mmio_read64
#else
#define mmio_write_native mmio_write32
#define mmio_read_native mmio_read32
#endif
void pause();

int isnumber(char ch);
int isalpha(char ch);
int ishex(char ch);
native_t hex(char ch);
snative_t atoi(const char *s);

static inline char numtoascii(native_t v) {
    return v + '0';
}

static inline char hextoascii(native_t v) {
    if (v < 10)
        return v + '0';
    return v - 10 + 'a';
}

char *btoa(native_t v, char *s);
char *htoa(native_t v, char *s);
char *itoa(native_t v, char *s);

void *memset(void *p, int c, native_t len);

const char *strchr(const char *s, int ch);
char *strtok(char *s, const char *delim);
int strlen(const char *s);
char *reverse_string(char *s);
int strcmp(const char *s1, const char *s2);


int sprintf(char *s, char *fmt, ...);
void printf(char *fmt, ...);
int vsprintf(char *dest, const char *fmt, va_list args);


void async_memcpy_push(void *dest, void *src, int len);
static inline void memcpy_pull(void *dest, void *src, int len) {
	async_memcpy_push(dest, src, len);
}
void long_pause(int amount);
void pause();

void puts(char *);
int putc(char);

#define assert(x)	{ if (!x) { printf("Failure of assert in %s(%d) %s\n", __FILE__, __LINE__, #x); } }
#define static_assert(x)	char sa__##__LINE__[(x)?1:-1]

#endif
