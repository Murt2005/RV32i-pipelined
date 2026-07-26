// Environment for running the official riscv-tests rv32ui suite on this core.
//
// The suite's own `p` environment is not used: it reports results through an
// ECALL trap handler and a `tohost` location that a host simulator polls,
// neither of which fits this board. This environment reports through the same
// MMIO putchar/halt registers the rest of the test suite uses instead.
//
// (The core does now implement mtvec/mepc/mcause and ECALL, so moving to the
// stock `p` environment is possible -- see tests/isa/traps.s for coverage of
// that machinery.)
//
// A test prints exactly one line:
//     PASS
//     FAIL <4 hex digits of the failing test number>
//
// Only RV32I instructions are used here, so the environment itself cannot mask
// a gap in the core.

#ifndef _ENV_RV32I_MMIO_H
#define _ENV_RV32I_MMIO_H

#define MMIO_PUTCHAR 0x0002FFF8
#define MMIO_HALT    0x0002FFFC
#define STACK_TOP    0x0002FFA0

#define TESTNUM gp

#define RVTEST_RV32U
#define RVTEST_RV64U    RVTEST_RV32U
#define RVTEST_RV32M
#define RVTEST_RV64M    RVTEST_RV32M
#define RVTEST_RV32S
#define RVTEST_RV64S    RVTEST_RV32S
#define RVTEST_FP_ENABLE
#define RVTEST_VEC_ENABLE

#define RVTEST_CODE_BEGIN                                               \
        .section .text;                                                 \
        .align 2;                                                       \
        .globl _start;                                                  \
_start:                                                                 \
        li sp, STACK_TOP;

#define RVTEST_CODE_END

// Stop the core. The store is repeated inside the loop rather than done once,
// matching tests/common/test_runtime.s: the simulation top drives its halt
// output as a single-cycle pulse, so storing once leaves termination dependent
// on exactly when the testbench samples it.
#define RVTEST_HALT                                                     \
        li   t0, MMIO_HALT;                                             \
1:      sw   x0, 0(t0);                                                 \
        j    1b;

#define RVTEST_PASS                                                     \
        li   t0, MMIO_PUTCHAR;                                          \
        li   t1, 'P'; sw t1, 0(t0);                                     \
        li   t1, 'A'; sw t1, 0(t0);                                     \
        li   t1, 'S'; sw t1, 0(t0);                                     \
        li   t1, 'S'; sw t1, 0(t0);                                     \
        li   t1, 10;  sw t1, 0(t0);                                     \
        RVTEST_HALT

// gp still holds the number of the test that failed, so print it. Labels are
// named rather than numeric because this macro expands once per file and the
// tests use the numeric locals heavily.
#define RVTEST_FAIL                                                     \
        li   t0, MMIO_PUTCHAR;                                          \
        li   t1, 'F'; sw t1, 0(t0);                                     \
        li   t1, 'A'; sw t1, 0(t0);                                     \
        li   t1, 'I'; sw t1, 0(t0);                                     \
        li   t1, 'L'; sw t1, 0(t0);                                     \
        li   t1, ' '; sw t1, 0(t0);                                     \
        li   t2, 12;                                                    \
rvtest_fail_nibble:                                                     \
        srl  t1, TESTNUM, t2;                                           \
        andi t1, t1, 0xF;                                               \
        li   t3, 10;                                                    \
        blt  t1, t3, rvtest_fail_digit;                                 \
        addi t1, t1, 'a'-10-'0';                                        \
rvtest_fail_digit:                                                      \
        addi t1, t1, '0';                                               \
        sw   t1, 0(t0);                                                 \
        addi t2, t2, -4;                                                \
        bgez t2, rvtest_fail_nibble;                                    \
        li   t1, 10;  sw t1, 0(t0);                                     \
        RVTEST_HALT

#define RVTEST_DATA_BEGIN                                               \
        .align 4;                                                       \
        .globl begin_signature;                                         \
begin_signature:

#define RVTEST_DATA_END                                                 \
        .align 4;                                                       \
        .globl end_signature;                                           \
end_signature:

#endif
