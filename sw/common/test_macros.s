# ================================================================
# Common test harness for RV32I pipeline tests
#
# UART output: write byte/word to 0x0002FFF8
# HALT:        write any value to 0x0002FFFC
# CYCLES:      read 0x0002FFF0   (free-running while the core runs)
# RETIRED:     read 0x0002FFF4   (instructions committed)
#
# Data memory map, top end:
#   0x0002FFF0..FFFF  MMIO above
#   0x0002FFC0..FFCF  tohost/fromhost, for the riscv-tests `p` environment;
#                     a store there halts the machine
#   0x0002FFB0        STACK_TOP, growing DOWN
#
# The stack must start *below* tohost. It used to start above it, which meant
# the first function with a stack frame bigger than 32 bytes stored into the
# halt address and stopped the machine.
#
# Conventions:
# - Macros clobber: a0, t0, t1, s10, s11 (ASSERT/print helpers use s10/s11).
# - Each test file should define its own `_start` and include this file.
# ================================================================

.set UART_ADDR, 0x0002FFF8
.set HALT_ADDR, 0x0002FFFC
.set CYCLE_ADDR, 0x0002FFF0
.set RETIRED_ADDR, 0x0002FFF4
.set STACK_TOP, 0x0002FFB0

.macro TEST_FILE_HEADER header_label
    la      a0, \header_label
    call    print_str
.endm

.macro TEST_BEGIN name_label
    la      a0, \name_label
    call    print_str
.endm

.macro TEST_PASS next_label
    la      a0, msg_pass
    call    print_str
    j       \next_label
.endm

.macro TEST_FAIL next_label
    la      a0, msg_fail
    call    print_str
    j       \next_label
.endm

.macro ASSERT_EQ_REG_IMM reg, imm, fail_label
    li      s10, \imm
    bne     \reg, s10, \fail_label
.endm

.macro ASSERT_NE_REG_IMM reg, imm, fail_label
    li      s10, \imm
    beq     \reg, s10, \fail_label
.endm

.macro ASSERT_EQ_REG_REG r1, r2, fail_label
    bne     \r1, \r2, \fail_label
.endm

.macro ASSERT_EQ_MEM32_IMM addr_reg, imm, fail_label
    lw      s11, 0(\addr_reg)
    li      s10, \imm
    bne     s11, s10, \fail_label
.endm

.macro HALT
    call    halt
.endm
.section .rodata

msg_pass: .asciz " --> PASS\n"
msg_fail: .asciz " --> FAIL ***\n"

