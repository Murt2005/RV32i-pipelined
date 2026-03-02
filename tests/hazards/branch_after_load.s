.include "tests/common/test_macros.s"

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

t01_branch_depends_on_load_not_taken:
    TEST_BEGIN msg_t01
    li      t0, 0x00020100
    li      t1, 1
    sw      t1, 0(t0)
    lw      t2, 0(t0)
    beq     t2, zero, t01_wrong     # must NOT be taken (requires stall)
    li      t3, 7
    j       t01_check
t01_wrong:
    li      t3, 99
t01_check:
    ASSERT_EQ_REG_IMM t3, 7, t01_fail
    TEST_PASS t02_taken_flush_store_after_load

t01_fail:
    TEST_FAIL t02_taken_flush_store_after_load

t02_taken_flush_store_after_load:
    TEST_BEGIN msg_t02
    li      t0, 0x00020120
    li      t1, 0                   # stored value
    sw      t1, 0(t0)
    lw      t2, 0(t0)
    beq     t2, zero, t02_taken     # taken (requires stall)
    li      t4, 0xCAFEBABE
    sw      t4, 4(t0)               # wrong-path store must not commit
t02_taken:
    addi    t5, t0, 4
    ASSERT_EQ_MEM32_IMM t5, 0, t02_fail
    TEST_PASS all_done

t02_fail:
    TEST_FAIL all_done

all_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/hazards/branch_after_load ===\n"
msg_done: .asciz "All tests in branch_after_load complete.\n"

msg_t01: .asciz "Test 01: LW->BEQ not taken"
msg_t02: .asciz "Test 02: LW->BEQ taken flushes store"

.include "tests/common/test_runtime.s"

