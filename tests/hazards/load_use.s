.include "tests/common/test_macros.s"

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

t01_lw_use_immediate:
    TEST_BEGIN msg_t01
    li      t0, 0x00020100
    li      t1, 42
    sw      t1, 0(t0)
    lw      t2, 0(t0)
    add     t3, t2, t2              # load-use (requires stall)
    ASSERT_EQ_REG_IMM t3, 84, t01_fail
    TEST_PASS t02_lb_lbu_use

t01_fail:
    TEST_FAIL t02_lb_lbu_use

t02_lb_lbu_use:
    TEST_BEGIN msg_t02
    li      t0, 0x00020104
    li      t1, -5
    sb      t1, 0(t0)
    lb      t2, 0(t0)
    addi    t3, t2, 10              # load-use
    ASSERT_EQ_REG_IMM t3, 5, t02_fail

    li      t1, 200
    sb      t1, 0(t0)
    lbu     t2, 0(t0)
    add     t3, t2, t2              # load-use
    ASSERT_EQ_REG_IMM t3, 400, t02_fail
    TEST_PASS t03_lh_use

t02_fail:
    TEST_FAIL t03_lh_use

t03_lh_use:
    TEST_BEGIN msg_t03
    li      t0, 0x00020108
    li      t1, 1000
    sh      t1, 0(t0)
    lh      t2, 0(t0)
    add     t3, t2, t2              # load-use
    ASSERT_EQ_REG_IMM t3, 2000, t03_fail
    TEST_PASS t04_load_to_store_address

t03_fail:
    TEST_FAIL t04_load_to_store_address

t04_load_to_store_address:
    TEST_BEGIN msg_t04
    # Load an address then use it immediately as store base (needs stall).
    li      t0, 0x00020120
    li      t1, 0x00020128
    sw      t1, 0(t0)
    lw      t2, 0(t0)               # t2 = 0x00020128
    li      t3, 99
    sw      t3, 0(t2)               # store using loaded base
    lw      t4, 0(t2)
    ASSERT_EQ_REG_IMM t4, 99, t04_fail
    TEST_PASS t05_load_to_branch

t04_fail:
    TEST_FAIL t05_load_to_branch

t05_load_to_branch:
    TEST_BEGIN msg_t05
    li      t0, 0x0002012C
    li      t1, 1
    sw      t1, 0(t0)
    lw      t2, 0(t0)
    beq     t2, zero, t05_wrong     # must NOT be taken
    li      t3, 7
    j       t05_check
t05_wrong:
    li      t3, 99
t05_check:
    ASSERT_EQ_REG_IMM t3, 7, t05_fail
    TEST_PASS all_done

t05_fail:
    TEST_FAIL all_done

all_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/hazards/load_use ===\n"
msg_done: .asciz "All tests in load_use complete.\n"

msg_t01: .asciz "Test 01: LW->use immediate"
msg_t02: .asciz "Test 02: LB/LBU->use immediate"
msg_t03: .asciz "Test 03: LH->use immediate"
msg_t04: .asciz "Test 04: LW->store base (address hazard)"
msg_t05: .asciz "Test 05: LW->branch condition"

.include "tests/common/test_runtime.s"

