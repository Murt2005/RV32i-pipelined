.include "tests/common/test_macros.s"

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

t01_lb_lbu:
    TEST_BEGIN msg_t01
    li      t0, 0x00020100
    li      t1, -5
    sb      t1, 0(t0)
    lb      t2, 0(t0)
    ASSERT_EQ_REG_IMM t2, -5, t01_fail
    lbu     t3, 0(t0)
    ASSERT_EQ_REG_IMM t3, 251, t01_fail
    TEST_PASS t02_lh_lhu

t01_fail:
    TEST_FAIL t02_lh_lhu

t02_lh_lhu:
    TEST_BEGIN msg_t02
    li      t0, 0x00020120
    li      t1, 0xBEEF
    sh      t1, 0(t0)
    lh      t2, 0(t0)
    li      t3, -16657              # sign-extended 0xBEEF
    ASSERT_EQ_REG_REG t2, t3, t02_fail
    lhu     t4, 0(t0)
    ASSERT_EQ_REG_IMM t4, 0xBEEF, t02_fail
    TEST_PASS t03_mixed_bytes

t02_fail:
    TEST_FAIL t03_mixed_bytes

t03_mixed_bytes:
    TEST_BEGIN msg_t03
    li      t0, 0x00020140
    li      t1, 0xDEADBEEF
    sw      t1, 0(t0)
    lb      t2, 0(t0)               # 0xEF => -17
    ASSERT_EQ_REG_IMM t2, -17, t03_fail
    lbu     t3, 0(t0)               # 0xEF => 239
    ASSERT_EQ_REG_IMM t3, 239, t03_fail
    lh      t4, 0(t0)               # 0xBEEF => -16657
    li      t5, -16657
    ASSERT_EQ_REG_REG t4, t5, t03_fail
    TEST_PASS all_done

t03_fail:
    TEST_FAIL all_done

all_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/isa/load_signext ===\n"
msg_done: .asciz "All tests in load_signext complete.\n"

msg_t01: .asciz "Test 01: LB vs LBU (sign/zero)"
msg_t02: .asciz "Test 02: LH vs LHU (sign/zero)"
msg_t03: .asciz "Test 03: load sign extension from word"

.include "tests/common/test_runtime.s"

