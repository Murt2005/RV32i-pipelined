.include "tests/common/test_macros.s"

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

t01_back_to_back_chain:
    TEST_BEGIN msg_t01
    li      a1, 7
    li      a2, 3
    add     a3, a1, a2              # 10
    add     a4, a3, a1              # 17 (uses a3)
    add     a5, a4, a3              # 27 (uses a4,a3)
    ASSERT_EQ_REG_IMM a5, 27, t01_fail
    TEST_PASS t02_dual_operand_forward

t01_fail:
    TEST_FAIL t02_dual_operand_forward

t02_dual_operand_forward:
    TEST_BEGIN msg_t02
    li      t0, 100
    li      t1, 5
    add     t2, t0, t1              # 105
    sub     t3, t2, t1              # 100 (uses t2)
    add     t4, t2, t3              # 205 (uses both forwarded)
    ASSERT_EQ_REG_IMM t4, 205, t02_fail
    TEST_PASS t03_rd_equals_rs1

t02_fail:
    TEST_FAIL t03_rd_equals_rs1

t03_rd_equals_rs1:
    TEST_BEGIN msg_t03
    li      t0, 9
    addi    t0, t0, 1               # 10 (rd==rs1)
    addi    t1, t0, 2               # 12 (uses forwarded t0)
    ASSERT_EQ_REG_IMM t1, 12, t03_fail
    TEST_PASS all_done

t03_fail:
    TEST_FAIL all_done

all_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/hazards/data_ex_ex ===\n"
msg_done: .asciz "All tests in data_ex_ex complete.\n"

msg_t01: .asciz "Test 01: EX->EX chain (no gaps)"
msg_t02: .asciz "Test 02: EX->EX dual-operand forward"
msg_t03: .asciz "Test 03: EX->EX with rd==rs1"

.include "tests/common/test_runtime.s"

