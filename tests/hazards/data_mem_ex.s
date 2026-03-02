.include "tests/common/test_macros.s"

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

t01_one_gap_forward:
    TEST_BEGIN msg_t01
    li      t0, 4
    li      t1, 6
    add     t2, t0, t1              # t2 = 10
    li      t3, 5                   # gap
    add     t4, t2, t3              # t4 = 15 (uses older t2)
    ASSERT_EQ_REG_IMM t4, 15, t01_fail
    TEST_PASS t02_two_gap_no_forward_needed

t01_fail:
    TEST_FAIL t02_two_gap_no_forward_needed

t02_two_gap_no_forward_needed:
    TEST_BEGIN msg_t02
    li      t0, 9
    li      t1, 3
    sub     t2, t0, t1              # 6
    li      t3, 0                   # gap1
    li      t3, 0                   # gap2 (by now regfile writeback should be visible)
    add     t4, t2, t1              # 9
    ASSERT_EQ_REG_IMM t4, 9, t02_fail
    TEST_PASS t03_mixed_stage_sources

t02_fail:
    TEST_FAIL t03_mixed_stage_sources

t03_mixed_stage_sources:
    TEST_BEGIN msg_t03
    # Try to force one operand from a newer producer and one from an older producer.
    li      t0, 10
    li      t1, 1
    add     s1, t0, t1              # s1 = 11
    addi    t2, zero, 0             # gap
    addi    s2, s1, 5               # s2 = 16 (uses s1)
    add     s3, s2, s1              # s3 = 27 (uses both recent results)
    ASSERT_EQ_REG_IMM s3, 27, t03_fail
    TEST_PASS all_done

t03_fail:
    TEST_FAIL all_done

all_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/hazards/data_mem_ex ===\n"
msg_done: .asciz "All tests in data_mem_ex complete.\n"

msg_t01: .asciz "Test 01: 1-gap producer->consumer"
msg_t02: .asciz "Test 02: 2-gap (regfile visibility)"
msg_t03: .asciz "Test 03: mixed-stage source operands"

.include "tests/common/test_runtime.s"

