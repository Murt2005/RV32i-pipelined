.include "tests/common/test_macros.s"

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

t01_lw_store_then_load:
    TEST_BEGIN msg_t01
    li      t0, 0x00020100
    li      t1, 0x12345678
    sw      t1, 0(t0)
    lw      t2, 0(t0)
    ASSERT_EQ_REG_IMM t2, 0x12345678, t01_fail
    TEST_PASS t02_lw_offset_addressing

t01_fail:
    TEST_FAIL t02_lw_offset_addressing

t02_lw_offset_addressing:
    TEST_BEGIN msg_t02
    li      t0, 0x00020120
    li      t1, 0xA5A5A5A5
    sw      t1, 12(t0)
    lw      t2, 12(t0)
    ASSERT_EQ_REG_IMM t2, 0xA5A5A5A5, t02_fail
    TEST_PASS t03_two_locations

t02_fail:
    TEST_FAIL t03_two_locations

t03_two_locations:
    TEST_BEGIN msg_t03
    li      t0, 0x00020140
    li      t1, 0x11112222
    li      t2, 0x33334444
    sw      t1, 0(t0)
    sw      t2, 4(t0)
    lw      t3, 0(t0)
    lw      t4, 4(t0)
    ASSERT_EQ_REG_IMM t3, 0x11112222, t03_fail
    ASSERT_EQ_REG_IMM t4, 0x33334444, t03_fail
    TEST_PASS all_done

t03_fail:
    TEST_FAIL all_done

all_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/isa/load_basic ===\n"
msg_done: .asciz "All tests in load_basic complete.\n"

msg_t01: .asciz "Test 01: LW after SW"
msg_t02: .asciz "Test 02: LW base+offset addressing"
msg_t03: .asciz "Test 03: multiple LW locations"

.include "tests/common/test_runtime.s"

