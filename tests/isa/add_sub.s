.include "tests/common/test_macros.s"

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

test01_add_basic:
    TEST_BEGIN msg_t01
    li      t0, 40
    li      t1, 25
    add     t2, t0, t1
    ASSERT_EQ_REG_IMM t2, 65, test01_fail
    TEST_PASS test02_sub_basic

test01_fail:
    TEST_FAIL test02_sub_basic

test02_sub_basic:
    TEST_BEGIN msg_t02
    li      t0, 100
    li      t1, 37
    sub     t2, t0, t1
    ASSERT_EQ_REG_IMM t2, 63, test02_fail
    TEST_PASS test03_addi_basic

test02_fail:
    TEST_FAIL test03_addi_basic

test03_addi_basic:
    TEST_BEGIN msg_t03
    li      t0, 123
    addi    t1, t0, -23
    ASSERT_EQ_REG_IMM t1, 100, test03_fail
    addi    t2, t1, 0
    ASSERT_EQ_REG_IMM t2, 100, test03_fail
    TEST_PASS test04_overflow_wrap

test03_fail:
    TEST_FAIL test04_overflow_wrap

test04_overflow_wrap:
    TEST_BEGIN msg_t04
    li      t0, 0x7FFFFFFF
    addi    t1, t0, 1
    li      t2, 0x80000000
    ASSERT_EQ_REG_REG t1, t2, test04_fail
    li      t3, 0x80000000
    addi    t4, t3, -1
    li      t5, 0x7FFFFFFF
    ASSERT_EQ_REG_REG t4, t5, test04_fail
    TEST_PASS test05_rd_aliasing

test04_fail:
    TEST_FAIL test05_rd_aliasing

test05_rd_aliasing:
    TEST_BEGIN msg_t05
    # rd == rs1
    li      t0, 7
    li      t1, 9
    add     t0, t0, t1
    ASSERT_EQ_REG_IMM t0, 16, test05_fail
    # rd == rs2
    li      t2, 5
    li      t3, 11
    sub     t3, t2, t3
    ASSERT_EQ_REG_IMM t3, -6, test05_fail
    # rs1 == rs2
    li      t4, 13
    add     t5, t4, t4
    ASSERT_EQ_REG_IMM t5, 26, test05_fail
    TEST_PASS test06_x0_immutable

test05_fail:
    TEST_FAIL test06_x0_immutable

test06_x0_immutable:
    TEST_BEGIN msg_t06
    li      t0, 1234
    add     zero, t0, t0
    addi    zero, zero, 1
    ASSERT_EQ_REG_IMM zero, 0, test06_fail
    TEST_PASS all_done

test06_fail:
    TEST_FAIL all_done

all_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/isa/add_sub ===\n"
msg_done: .asciz "All tests in add_sub complete.\n"

msg_t01: .asciz "Test 01: ADD basics"
msg_t02: .asciz "Test 02: SUB basics"
msg_t03: .asciz "Test 03: ADDI basics"
msg_t04: .asciz "Test 04: overflow wraparound"
msg_t05: .asciz "Test 05: rd/rs aliasing"
msg_t06: .asciz "Test 06: x0 immutable"

.include "tests/common/test_runtime.s"

