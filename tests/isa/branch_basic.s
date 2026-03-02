.include "tests/common/test_macros.s"

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

t01_beq_taken_flush:
    TEST_BEGIN msg_t01
    li      t0, 99
    li      t1, 99
    li      t2, 0
    beq     t0, t1, t01_taken
    li      t2, 1                   # should be flushed
    li      t2, 2
t01_taken:
    ASSERT_EQ_REG_IMM t2, 0, t01_fail
    TEST_PASS t02_beq_not_taken

t01_fail:
    TEST_FAIL t02_beq_not_taken

t02_beq_not_taken:
    TEST_BEGIN msg_t02
    li      t0, 1
    li      t1, 2
    li      t2, 0
    beq     t0, t1, t02_wrong
    li      t2, 7
    j       t02_check
t02_wrong:
    li      t2, 99
t02_check:
    ASSERT_EQ_REG_IMM t2, 7, t02_fail
    TEST_PASS t03_bne_taken

t02_fail:
    TEST_FAIL t03_bne_taken

t03_bne_taken:
    TEST_BEGIN msg_t03
    li      t0, 3
    li      t1, 7
    li      t2, 0
    bne     t0, t1, t03_taken
    li      t2, 1                   # flushed
t03_taken:
    ASSERT_EQ_REG_IMM t2, 0, t03_fail
    TEST_PASS t04_loop_backward_branch

t03_fail:
    TEST_FAIL t04_loop_backward_branch

t04_loop_backward_branch:
    TEST_BEGIN msg_t04
    li      t0, 0                   # sum
    li      t1, 5
t04_loop:
    add     t0, t0, t1
    addi    t1, t1, -1
    bne     t1, zero, t04_loop
    ASSERT_EQ_REG_IMM t0, 15, t04_fail
    TEST_PASS all_done

t04_fail:
    TEST_FAIL all_done

all_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/isa/branch_basic ===\n"
msg_done: .asciz "All tests in branch_basic complete.\n"

msg_t01: .asciz "Test 01: BEQ taken (flush)"
msg_t02: .asciz "Test 02: BEQ not taken"
msg_t03: .asciz "Test 03: BNE taken (flush)"
msg_t04: .asciz "Test 04: backward-branch loop"

.include "tests/common/test_runtime.s"

