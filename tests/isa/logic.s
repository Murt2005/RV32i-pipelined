.include "tests/common/test_macros.s"

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

t01_and_or_xor:
    TEST_BEGIN msg_t01
    li      t0, 0xFF00FF00
    li      t1, 0x0F0F0F0F
    and     t2, t0, t1
    ASSERT_EQ_REG_IMM t2, 0x0F000F00, t01_fail
    or      t3, t0, t1
    ASSERT_EQ_REG_IMM t3, 0xFF0FFF0F, t01_fail
    xor     t4, t0, t1
    ASSERT_EQ_REG_IMM t4, 0xF00FF00F, t01_fail
    TEST_PASS t02_andi_ori_xori

t01_fail:
    TEST_FAIL t02_andi_ori_xori

t02_andi_ori_xori:
    TEST_BEGIN msg_t02
    li      t0, 0x12345678
    andi    t1, t0, 0x0FF
    ASSERT_EQ_REG_IMM t1, 0x00000078, t02_fail
    ori     t2, t1, 0x100
    ASSERT_EQ_REG_IMM t2, 0x00000178, t02_fail
    xori    t3, t2, 0x1FF
    ASSERT_EQ_REG_IMM t3, 0x00000087, t02_fail
    TEST_PASS t03_de_morgan

t02_fail:
    TEST_FAIL t03_de_morgan

t03_de_morgan:
    TEST_BEGIN msg_t03
    # (~(a|b)) == (~a & ~b) for 32-bit two's complement
    li      t0, 0x00FF00FF
    li      t1, 0x0F0F0F0F
    or      t2, t0, t1
    xori    t2, t2, -1
    xori    t3, t0, -1
    xori    t4, t1, -1
    and     t5, t3, t4
    ASSERT_EQ_REG_REG t2, t5, t03_fail
    TEST_PASS t04_bit_toggling

t03_fail:
    TEST_FAIL t04_bit_toggling

t04_bit_toggling:
    TEST_BEGIN msg_t04
    li      t0, 0
    xori    t0, t0, -1
    ASSERT_EQ_REG_IMM t0, 0xFFFFFFFF, t04_fail
    xori    t0, t0, -1
    ASSERT_EQ_REG_IMM t0, 0x00000000, t04_fail
    TEST_PASS all_done

t04_fail:
    TEST_FAIL all_done

all_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/isa/logic ===\n"
msg_done: .asciz "All tests in logic complete.\n"

msg_t01: .asciz "Test 01: AND/OR/XOR"
msg_t02: .asciz "Test 02: ANDI/ORI/XORI"
msg_t03: .asciz "Test 03: De Morgan identity"
msg_t04: .asciz "Test 04: XOR toggle pattern"

.include "tests/common/test_runtime.s"

