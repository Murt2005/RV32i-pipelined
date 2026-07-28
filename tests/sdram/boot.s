# Reset stub for a program linked into SDRAM.
#
# The core resets to 0x00010000 -- on-chip instruction memory -- and this is the
# only thing that lives there. It sets up a stack, clears .bss, and jumps to the
# real entry point in SDRAM.
#
# Clearing .bss matters here in a way it never did before. Every earlier program
# in this tree relied on the memories being zero: the simulator zeroes its arrays
# in an `initial` block, and the hardware loader issues a `Z` command before each
# run. Neither is true of a C program's .bss in SDRAM once anything has run
# before it, and newlib's malloc will hand out memory on the assumption that its
# own bookkeeping started at zero.

    .section .boot, "ax"
    .globl _start
_start:
    # Stack below the MMIO block at 0x0002FFC0, growing down through the on-chip
    # data memory. Kept there rather than in SDRAM so a runaway stack hits the
    # bottom of a small memory instead of quietly eating the heap.
    li      sp, 0x0002FF80

    # Clear .bss.
    la      t0, __bss_start
    la      t1, __bss_end
    bgeu    t0, t1, bss_done
bss_loop:
    sw      zero, 0(t0)
    addi    t0, t0, 4
    bltu    t0, t1, bss_loop
bss_done:

    # Into SDRAM. `call` would be a pc-relative jump from the boot region, which
    # cannot reach 0x80000000; load the address and jump indirectly.
    la      t0, main
    jalr    ra, t0, 0

    # main returned: stop the machine.
    li      t0, 0x0002FFFC
    sw      a0, 0(t0)
1:  j       1b
