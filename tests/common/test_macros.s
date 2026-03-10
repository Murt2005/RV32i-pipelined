# ================================================================
# Common test harness for RV32I pipeline tests
#
# UART output: write byte/word to 0x0002FFF8
# HALT:        write any value to 0x0002FFFC
#
# Conventions:
# - Macros clobber: a0, t0, t1, s10, s11 (ASSERT/print helpers use s10/s11).
# - Each test file should define its own `_start` and include this file.
# ================================================================

.set UART_ADDR, 0x0002FFF8
.set HALT_ADDR, 0x0002FFFC
# FPGA build uses 4KiB data RAM (see fpga/hardware_top.v `HW_MEM_SIZE=4096`).
# Place the stack at the top of the 4KiB data window: 0x20000 + 0x1000.
.set STACK_TOP, 0x00021000

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

