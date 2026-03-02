.include "tests/common/test_macros.s"

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

t01_slt_signed:
    TEST_BEGIN msg_t01
    li      t0, -1
    li      t1, 0
    slt     t2, t0, t1              # -1 < 0 => 1
    ASSERT_EQ_REG_IMM t2, 1, t01_fail
    slt     t3, t1, t0              # 0 < -1 => 0
    ASSERT_EQ_REG_IMM t3, 0, t01_fail
    TEST_PASS t02_sltu_unsigned

t01_fail:
    TEST_FAIL t02_sltu_unsigned

t02_sltu_unsigned:
    TEST_BEGIN msg_t02
    li      t0, -1                  # 0xFFFFFFFF
    li      t1, 1
    sltu    t2, t0, t1              # 0xFFFFFFFF < 1 => 0
    ASSERT_EQ_REG_IMM t2, 0, t02_fail
    sltu    t3, t1, t0              # 1 < 0xFFFFFFFF => 1
    ASSERT_EQ_REG_IMM t3, 1, t02_fail
    TEST_PASS t03_slti_sltiu

t02_fail:
    TEST_FAIL t03_slti_sltiu

t03_slti_sltiu:
    TEST_BEGIN msg_t03
    li      t0, -1
    slti    t1, t0, 0               # -1 < 0 => 1
    ASSERT_EQ_REG_IMM t1, 1, t03_fail
    sltiu   t2, t0, 1               # 0xFFFFFFFF < 1 => 0
    ASSERT_EQ_REG_IMM t2, 0, t03_fail

    li      t3, 5
    slti    t4, t3, 5               # 5 < 5 => 0
    ASSERT_EQ_REG_IMM t4, 0, t03_fail
    TEST_PASS all_done

t03_fail:
    TEST_FAIL all_done

all_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/isa/compare ===\n"
msg_done: .asciz "All tests in compare complete.\n"

msg_t01: .asciz "Test 01: SLT (signed)"
msg_t02: .asciz "Test 02: SLTU (unsigned)"
msg_t03: .asciz "Test 03: SLTI/SLTIU"

.include "tests/common/test_runtime.s"

