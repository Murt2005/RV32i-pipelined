.include "tests/common/test_macros.s"

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

t01_sw_lw:
    TEST_BEGIN msg_t01
    li      t0, 0x00020100
    li      t1, 0x11223344
    sw      t1, 0(t0)
    lw      t2, 0(t0)
    ASSERT_EQ_REG_IMM t2, 0x11223344, t01_fail
    TEST_PASS t02_sb_masking

t01_fail:
    TEST_FAIL t02_sb_masking

t02_sb_masking:
    TEST_BEGIN msg_t02
    li      t0, 0x00020120
    li      t1, 0xAABBCCDD
    sw      t1, 0(t0)
    li      t2, 0x11
    sb      t2, 0(t0)               # DD -> 11
    lw      t3, 0(t0)
    ASSERT_EQ_REG_IMM t3, 0xAABBCC11, t02_fail
    li      t2, 0x22
    sb      t2, 1(t0)               # CC -> 22
    lw      t3, 0(t0)
    ASSERT_EQ_REG_IMM t3, 0xAABB2211, t02_fail
    TEST_PASS t03_sh_masking

t02_fail:
    TEST_FAIL t03_sh_masking

t03_sh_masking:
    TEST_BEGIN msg_t03
    li      t0, 0x00020140
    li      t1, 0xDEADBEEF
    sw      t1, 0(t0)
    li      t2, 0x1234
    sh      t2, 0(t0)               # low halfword -> 0x1234
    lw      t3, 0(t0)
    ASSERT_EQ_REG_IMM t3, 0xDEAD1234, t03_fail
    li      t4, 0x5678
    sh      t4, 2(t0)               # high halfword -> 0x5678
    lw      t3, 0(t0)
    ASSERT_EQ_REG_IMM t3, 0x56781234, t03_fail
    TEST_PASS all_done

t03_fail:
    TEST_FAIL all_done

all_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/isa/store_basic ===\n"
msg_done: .asciz "All tests in store_basic complete.\n"

msg_t01: .asciz "Test 01: SW then LW"
msg_t02: .asciz "Test 02: SB masking within word"
msg_t03: .asciz "Test 03: SH masking within word"

.include "tests/common/test_runtime.s"

