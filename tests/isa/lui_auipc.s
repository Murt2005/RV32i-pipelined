.include "tests/common/test_macros.s"

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

t01_lui_basic:
    TEST_BEGIN msg_t01
    lui     t0, 0x12345             # 0x12345000
    ASSERT_EQ_REG_IMM t0, 0x12345000, t01_fail
    lui     t1, 0xFFFFF             # 0xFFFFF000 (negative)
    ASSERT_EQ_REG_IMM t1, 0xFFFFF000, t01_fail
    TEST_PASS t02_auipc_delta

t01_fail:
    TEST_FAIL t02_auipc_delta

t02_auipc_delta:
    TEST_BEGIN msg_t02
    auipc   t0, 0
    auipc   t1, 0
    sub     t2, t1, t0
    ASSERT_EQ_REG_IMM t2, 4, t02_fail
    TEST_PASS t03_auipc_add

t02_fail:
    TEST_FAIL t03_auipc_add

t03_auipc_add:
    TEST_BEGIN msg_t03
    # Verify AUIPC provides a stable PC-relative base for address arithmetic.
    auipc   t0, 0
    addi    t1, t0, 16
    addi    t2, t1, -16
    ASSERT_EQ_REG_REG t2, t0, t03_fail
    TEST_PASS all_done

t03_fail:
    TEST_FAIL all_done

all_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/isa/lui_auipc ===\n"
msg_done: .asciz "All tests in lui_auipc complete.\n"

msg_t01: .asciz "Test 01: LUI basics"
msg_t02: .asciz "Test 02: AUIPC consecutive delta"
msg_t03: .asciz "Test 03: AUIPC address arithmetic"

.include "tests/common/test_runtime.s"

