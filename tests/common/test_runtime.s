.text

# ------------------------------------------------
# init_stack: set SP to top of memory - 16
# ------------------------------------------------
.globl init_stack
init_stack:
    li      sp, (STACK_TOP - 16)
    ret

# ------------------------------------------------
# uart_putc: output low byte of a0
# ------------------------------------------------
.globl uart_putc
uart_putc:
    li      t0, UART_ADDR
    sw      a0, 0(t0)
    ret

# ------------------------------------------------
# print_str: print null-terminated string at a0
#
# The `addi a0, a0, 1` between `lb` and `beq` is
# a convenient gap instruction that reduces reliance
# on load-use stalling in the print loop.
# ------------------------------------------------
.globl print_str
print_str:
    li      t0, UART_ADDR
1:
    lb      t1, 0(a0)
    addi    a0, a0, 1
    beq     t1, zero, 2f
    sw      t1, 0(t0)
    j       1b
2:
    ret

# ------------------------------------------------
# halt: request simulation halt via MMIO
# ------------------------------------------------
.globl halt
halt:
    li      t0, HALT_ADDR
1:
    sw      zero, 0(t0)
    j       1b

