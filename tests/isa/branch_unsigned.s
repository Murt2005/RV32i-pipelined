.include "tests/common/test_macros.s"

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

t01_bltu_taken:
    TEST_BEGIN msg_t01
    li      t0, 1
    li      t1, -1                  # 0xFFFFFFFF
    li      t2, 0
    bltu    t0, t1, t01_taken
    li      t2, 1                   # flushed
t01_taken:
    ASSERT_EQ_REG_IMM t2, 0, t01_fail
    TEST_PASS t02_bltu_not_taken

t01_fail:
    TEST_FAIL t02_bltu_not_taken

t02_bltu_not_taken:
    TEST_BEGIN msg_t02
    li      t0, -1
    li      t1, 1
    li      t2, 7
    bltu    t0, t1, t02_wrong
    j       t02_check
t02_wrong:
    li      t2, 99
t02_check:
    ASSERT_EQ_REG_IMM t2, 7, t02_fail
    TEST_PASS t03_bgeu_taken

t02_fail:
    TEST_FAIL t03_bgeu_taken

t03_bgeu_taken:
    TEST_BEGIN msg_t03
    li      t0, -1
    li      t1, 1
    li      t2, 0
    bgeu    t0, t1, t03_taken
    li      t2, 1                   # flushed
t03_taken:
    ASSERT_EQ_REG_IMM t2, 0, t03_fail
    TEST_PASS all_done

t03_fail:
    TEST_FAIL all_done

all_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/isa/branch_unsigned ===\n"
msg_done: .asciz "All tests in branch_unsigned complete.\n"

msg_t01: .asciz "Test 01: BLTU taken (1 < 0xFFFFFFFF)"
msg_t02: .asciz "Test 02: BLTU not taken (0xFFFFFFFF < 1)"
msg_t03: .asciz "Test 03: BGEU taken (0xFFFFFFFF >= 1)"

.include "tests/common/test_runtime.s"

