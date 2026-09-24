# Reset entry for the Dhrystone image: set up a stack, run main, halt.
#
# In .text.init so link.ld places it first, at the reset PC 0x00010000,
# whatever order the objects are linked in.

.globl _start

.section .text.init

_start:
    li      sp, (0x0002FFB0 - 16)
    call    main
    li      t0, 0x0002FFFC
halt:
    sw      zero, 0(t0)
    j       halt
