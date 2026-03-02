.include "tests/common/test_macros.s"

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

t01_slli_srli_srai:
    TEST_BEGIN msg_t01
    li      t0, 1
    slli    t1, t0, 15
    ASSERT_EQ_REG_IMM t1, 32768, t01_fail
    srli    t2, t1, 3
    ASSERT_EQ_REG_IMM t2, 4096, t01_fail

    li      t3, -32768
    srai    t4, t3, 4
    bge     t4, zero, t01_fail
    TEST_PASS t02_reg_shifts

t01_fail:
    TEST_FAIL t02_reg_shifts

t02_reg_shifts:
    TEST_BEGIN msg_t02
    li      t0, 0x00000001
    li      t1, 31
    sll     t2, t0, t1
    ASSERT_EQ_REG_IMM t2, 0x80000000, t02_fail
    srl     t3, t2, t1
    ASSERT_EQ_REG_IMM t3, 1, t02_fail

    li      t4, -1
    srl     t5, t4, t1
    ASSERT_EQ_REG_IMM t5, 1, t02_fail
    sra     t6, t4, t1
    ASSERT_EQ_REG_IMM t6, -1, t02_fail
    TEST_PASS t03_shamt_mask

t02_fail:
    TEST_FAIL t03_shamt_mask

t03_shamt_mask:
    TEST_BEGIN msg_t03
    # Register-shift amounts use low 5 bits (mask with 31).
    li      t0, 0x12345678
    li      t1, 32                  # 32 -> 0
    sll     t2, t0, t1
    ASSERT_EQ_REG_REG t2, t0, t03_fail
    srl     t3, t0, t1
    ASSERT_EQ_REG_REG t3, t0, t03_fail

    li      t1, 33                  # 33 -> 1
    sll     t4, t0, t1
    li      t5, 0x2468ACF0
    ASSERT_EQ_REG_REG t4, t5, t03_fail
    TEST_PASS all_done

t03_fail:
    TEST_FAIL all_done

all_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/isa/shift ===\n"
msg_done: .asciz "All tests in shift complete.\n"

msg_t01: .asciz "Test 01: SLLI/SRLI/SRAI"
msg_t02: .asciz "Test 02: SLL/SRL/SRA"
msg_t03: .asciz "Test 03: shift amount masking"

.include "tests/common/test_runtime.s"

