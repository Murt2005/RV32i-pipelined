.include "tests/common/test_macros.s"

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

t01_blt_taken:
    TEST_BEGIN msg_t01
    li      t0, -3
    li      t1, 5
    li      t2, 0
    blt     t0, t1, t01_taken
    li      t2, 1                   # flushed
t01_taken:
    ASSERT_EQ_REG_IMM t2, 0, t01_fail
    TEST_PASS t02_blt_not_taken

t01_fail:
    TEST_FAIL t02_blt_not_taken

t02_blt_not_taken:
    TEST_BEGIN msg_t02
    li      t0, 10
    li      t1, -1
    li      t2, 7
    blt     t0, t1, t02_wrong
    j       t02_check
t02_wrong:
    li      t2, 99
t02_check:
    ASSERT_EQ_REG_IMM t2, 7, t02_fail
    TEST_PASS t03_bge_taken_equal

t02_fail:
    TEST_FAIL t03_bge_taken_equal

t03_bge_taken_equal:
    TEST_BEGIN msg_t03
    li      t0, -123
    li      t1, -123
    li      t2, 0
    bge     t0, t1, t03_taken       # equal => taken
    li      t2, 1                   # flushed
t03_taken:
    ASSERT_EQ_REG_IMM t2, 0, t03_fail
    TEST_PASS t04_bge_taken_greater

t03_fail:
    TEST_FAIL t04_bge_taken_greater

t04_bge_taken_greater:
    TEST_BEGIN msg_t04
    li      t0, 0
    li      t1, -100
    li      t2, 0
    bge     t0, t1, t04_taken
    li      t2, 1                   # flushed
t04_taken:
    ASSERT_EQ_REG_IMM t2, 0, t04_fail
    TEST_PASS all_done

t04_fail:
    TEST_FAIL all_done

all_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/isa/branch_signed ===\n"
msg_done: .asciz "All tests in branch_signed complete.\n"

msg_t01: .asciz "Test 01: BLT taken (-3 < 5)"
msg_t02: .asciz "Test 02: BLT not taken (10 < -1)"
msg_t03: .asciz "Test 03: BGE taken (equal)"
msg_t04: .asciz "Test 04: BGE taken (0 >= -100)"

.include "tests/common/test_runtime.s"

