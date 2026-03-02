.include "tests/common/test_macros.s"

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

t01_multi_consumer_same_load:
    TEST_BEGIN msg_t01
    li      t0, 0x00020100
    li      t1, 0x0000002A          # 42
    sw      t1, 0(t0)
    lw      t2, 0(t0)               # 42
    add     t3, t2, t2              # 84 (load-use)
    sub     t4, t2, t2              # 0  (also depends on t2)
    addi    t5, t2, 1               # 43 (also depends on t2)
    ASSERT_EQ_REG_IMM t3, 84, t01_fail
    ASSERT_EQ_REG_IMM t4, 0, t01_fail
    ASSERT_EQ_REG_IMM t5, 43, t01_fail
    TEST_PASS t02_back_to_back_loads

t01_fail:
    TEST_FAIL t02_back_to_back_loads

t02_back_to_back_loads:
    TEST_BEGIN msg_t02
    li      t0, 0x00020120
    li      t1, 10
    li      t2, 20
    sw      t1, 0(t0)
    sw      t2, 4(t0)
    lw      s1, 0(t0)               # 10
    lw      s2, 4(t0)               # 20
    add     s3, s1, s2              # depends on both loads
    ASSERT_EQ_REG_IMM s3, 30, t02_fail
    TEST_PASS all_done

t02_fail:
    TEST_FAIL all_done

all_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/hazards/load_chain ===\n"
msg_done: .asciz "All tests in load_chain complete.\n"

msg_t01: .asciz "Test 01: multi-consumer of one load"
msg_t02: .asciz "Test 02: back-to-back loads then use"

.include "tests/common/test_runtime.s"

