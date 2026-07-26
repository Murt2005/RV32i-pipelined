# Machine-mode CSRs and exceptions.
#
# Each case installs a handler in mtvec, provokes the exception, and checks
# mcause. The handler always returns to mepc+4 via MRET, so execution resumes
# at the instruction after the faulting one.

.include "tests/common/test_macros.s"

.set CSR_MSTATUS, 0x300
.set CSR_MTVEC,   0x305
.set CSR_MEPC,    0x341
.set CSR_MCAUSE,  0x342
.set CSR_MTVAL,   0x343

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

    # s11 records the cause of the most recent trap; s10 counts traps.
    li      s10, 0
    la      t0, trap_handler
    csrw    CSR_MTVEC, t0

t01_csr_rw:
    TEST_BEGIN msg_t01
    li      t0, 0x12340000
    csrw    CSR_MTVAL, t0
    csrr    t1, CSR_MTVAL
    ASSERT_EQ_REG_REG t1, t0, t01_fail
    # csrrs with a zero source must read without writing
    csrr    t2, CSR_MTVAL
    ASSERT_EQ_REG_REG t2, t0, t01_fail
    # set and clear bits
    li      t3, 0x000000FF
    csrs    CSR_MTVAL, t3
    csrr    t1, CSR_MTVAL
    li      t4, 0x123400FF
    ASSERT_EQ_REG_REG t1, t4, t01_fail
    csrc    CSR_MTVAL, t3
    csrr    t1, CSR_MTVAL
    ASSERT_EQ_REG_REG t1, t0, t01_fail
    TEST_PASS t02_illegal

t01_fail:
    TEST_FAIL t02_illegal

t02_illegal:
    TEST_BEGIN msg_t02
    li      s10, 0
    .word   0x00000000              # not a valid instruction
    ASSERT_EQ_REG_IMM s10, 1, t02_fail
    ASSERT_EQ_REG_IMM s11, 2, t02_fail      # cause 2 = illegal instruction
    TEST_PASS t03_ecall

t02_fail:
    TEST_FAIL t03_ecall

t03_ecall:
    TEST_BEGIN msg_t03
    li      s10, 0
    ecall
    ASSERT_EQ_REG_IMM s10, 1, t03_fail
    ASSERT_EQ_REG_IMM s11, 11, t03_fail     # cause 11 = ecall from M-mode
    TEST_PASS t04_ebreak

t03_fail:
    TEST_FAIL t04_ebreak

t04_ebreak:
    TEST_BEGIN msg_t04
    li      s10, 0
    ebreak
    ASSERT_EQ_REG_IMM s10, 1, t04_fail
    ASSERT_EQ_REG_IMM s11, 3, t04_fail      # cause 3 = breakpoint
    TEST_PASS t05_misaligned_load

t04_fail:
    TEST_FAIL t05_misaligned_load

t05_misaligned_load:
    TEST_BEGIN msg_t05
    li      s10, 0
    li      t0, 0x00020002          # halfword-misaligned for lw
    lw      t1, 0(t0)
    ASSERT_EQ_REG_IMM s10, 1, t05_fail
    ASSERT_EQ_REG_IMM s11, 4, t05_fail      # cause 4 = misaligned load
    TEST_PASS t06_misaligned_store

t05_fail:
    TEST_FAIL t06_misaligned_store

t06_misaligned_store:
    TEST_BEGIN msg_t06
    li      s10, 0
    li      t0, 0x00020001          # misaligned for sh
    sh      t1, 0(t0)
    ASSERT_EQ_REG_IMM s10, 1, t06_fail
    ASSERT_EQ_REG_IMM s11, 6, t06_fail      # cause 6 = misaligned store
    TEST_PASS t07_aligned_ok

t06_fail:
    TEST_FAIL t07_aligned_ok

t07_aligned_ok:
    TEST_BEGIN msg_t07
    # Aligned accesses of every width must NOT trap.
    li      s10, 0
    li      t0, 0x00020200
    li      t1, 0x11223344
    sw      t1, 0(t0)
    lw      t2, 0(t0)
    lh      t3, 2(t0)
    lb      t4, 1(t0)
    sh      t1, 4(t0)
    sb      t1, 6(t0)
    ASSERT_EQ_REG_IMM s10, 0, t07_fail
    ASSERT_EQ_REG_REG t2, t1, t07_fail
    TEST_PASS t08_fence_is_nop

t07_fail:
    TEST_FAIL t08_fence_is_nop

t08_fence_is_nop:
    TEST_BEGIN msg_t08
    li      s10, 0
    fence
    li      t0, 7
    ASSERT_EQ_REG_IMM s10, 0, t08_fail      # FENCE must not trap
    ASSERT_EQ_REG_IMM t0, 7, t08_fail
    TEST_PASS all_done

t08_fail:
    TEST_FAIL all_done

# ---------------------------------------------------------------------
# Trap handler: record the cause, then resume after the faulting
# instruction. Every exception here is 4 bytes wide.
# ---------------------------------------------------------------------
.align 2
trap_handler:
    csrr    s11, CSR_MCAUSE
    addi    s10, s10, 1
    csrr    t6, CSR_MEPC
    addi    t6, t6, 4
    csrw    CSR_MEPC, t6
    mret

all_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/isa/traps ===\n"
msg_done: .asciz "All tests in traps complete.\n"
msg_t01:  .asciz "Test 01: CSR read/write/set/clear"
msg_t02:  .asciz "Test 02: illegal instruction traps"
msg_t03:  .asciz "Test 03: ECALL traps"
msg_t04:  .asciz "Test 04: EBREAK traps"
msg_t05:  .asciz "Test 05: misaligned load traps"
msg_t06:  .asciz "Test 06: misaligned store traps"
msg_t07:  .asciz "Test 07: aligned accesses do not trap"
msg_t08:  .asciz "Test 08: FENCE is a NOP"

.include "tests/common/test_runtime.s"
