/* Minimal replacement for riscv-tests' util.h / encoding.h: just the two
   things Dhrystone actually uses. */
#ifndef _RV_ENV_H
#define _RV_ENV_H

#define read_csr(reg) ({ unsigned long __v; \
    asm volatile ("csrr %0, " #reg : "=r"(__v)); __v; })

extern void setStats(int enable);

#endif
