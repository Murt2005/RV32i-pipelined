.include "tests/common/test_macros.s"

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

t01_branch_depends_on_alu:
    TEST_BEGIN msg_t01
    li      t0, 10
    li      t1, 3
    sub     t2, t0, t1              # 7
    beq     t2, zero, t01_wrong
    li      t3, 0
    j       t01_check
t01_wrong:
    li      t3, 99
t01_check:
    ASSERT_EQ_REG_IMM t3, 0, t01_fail
    TEST_PASS t02_taken_flush_side_effect

t01_fail:
    TEST_FAIL t02_taken_flush_side_effect

t02_taken_flush_side_effect:
    TEST_BEGIN msg_t02
    li      t0, 0x00020180
    sw      zero, 0(t0)             # clear location
    li      t1, 1
    li      t2, 1
    xor     t3, t1, t2              # 0
    beq     t3, zero, t02_taken     # taken
    li      t4, 0xDEADBEEF          # should be flushed (wrong path)
    sw      t4, 0(t0)               # wrong-path store must not commit
t02_taken:
    ASSERT_EQ_MEM32_IMM t0, 0, t02_fail
    TEST_PASS all_done

t02_fail:
    TEST_FAIL all_done

all_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/hazards/branch_after_alu ===\n"
msg_done: .asciz "All tests in branch_after_alu complete.\n"

msg_t01: .asciz "Test 01: branch uses ALU result"
msg_t02: .asciz "Test 02: taken branch flushes side-effect store"

.include "tests/common/test_runtime.s"

