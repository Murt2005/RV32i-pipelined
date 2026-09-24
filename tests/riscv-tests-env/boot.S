// Reset stub for riscv-tests run from SDRAM: the core resets into on-chip
// instruction memory, so jump from there to the test's _start

    .section .boot, "ax"
    .globl _boot
_boot:
    la      t0, _start
    jr      t0
