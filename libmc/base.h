#ifndef _base_h
#define _base_h

typedef unsigned long long uint64_t;
typedef long long int64_t;

typedef unsigned int uint32_t;
typedef int int32_t;

typedef unsigned short uint16_t;
typedef short int16_t;

typedef unsigned char uint8_t;
typedef char int8_t;

typedef unsigned int bool;

#ifdef _64bit
typedef unsigned long long native_t;
typedef signed long long snative_t;
#define WORD_SIZE 64
#else
typedef unsigned int native_t;
typedef signed int snative_t;
#define WORD_SIZE 32
#endif

#define true 1
#define false 0
#define NULL ((void *)0)
#endif
