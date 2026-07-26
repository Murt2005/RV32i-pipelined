# Workload for measuring IPC on hardware.
#
# The counters are zeroed when the core is released, so the values read at the
# end cover the whole program. Both are stored to RESULT_ADDR where the host
# picks them up with the loader's read command.

.include "tests/common/test_macros.s"

.set RESULT_ADDR, 0x00021800
.set ITERS, 2000

.text

_start:
    call    init_stack

    li      s0, ITERS
    li      s1, 0x00021000          # scratch base
    li      s2, 0

loop:
    # a deliberately mixed body: alu, a load-use pair, a taken branch and a
    # store, so the figure reflects stalls and flushes rather than a best case
    addi    s2, s2, 3
    xor     s3, s2, s0
    sw      s3, 0(s1)
    lw      s4, 0(s1)               # load-use stall against the next add
    add     s5, s4, s2
    slli    s6, s5, 3
    srli    s7, s6, 2
    beq     zero, zero, cont        # always taken -> flush
    addi    s2, s2, 100             # skipped
cont:
    addi    s0, s0, -1
    bne     s0, zero, loop

    li      t0, CYCLE_ADDR
    lw      a1, 0(t0)
    li      t0, RETIRED_ADDR
    lw      a2, 0(t0)

    li      t1, RESULT_ADDR
    sw      a1, 0(t1)
    sw      a2, 4(t1)

    HALT

.include "tests/common/test_runtime.s"
