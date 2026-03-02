.include "tests/common/test_macros.s"

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

t01_jal_link_value:
    TEST_BEGIN msg_t01
    # Use AUIPC to measure JAL link value relative to a known PC.
    # Layout:
    #   auipc t0,0        ; t0 = PC(auipc)
    #   jal   ra,target   ; ra = PC(jal)+4 = PC(auipc)+8
    auipc   t0, 0
    jal     ra, t01_target
    # If JAL didn't jump, fail.
    j       t01_fail
t01_target:
    sub     t1, ra, t0
    ASSERT_EQ_REG_IMM t1, 8, t01_fail
    TEST_PASS t02_jalr_return

t01_fail:
    TEST_FAIL t02_jalr_return

t02_jalr_return:
    TEST_BEGIN msg_t02
    li      s0, 0
    jal     ra, t02_sub
    ASSERT_EQ_REG_IMM s0, 0xBEEF, t02_fail
    TEST_PASS t03_jalr_indirect

t02_fail:
    TEST_FAIL t03_jalr_indirect

t02_sub:
    li      s0, 0xBEEF
    jalr    zero, 0(ra)

t03_jalr_indirect:
    TEST_BEGIN msg_t03
    la      t0, t03_dst
    jalr    ra, 0(t0)
    j       t03_fail
t03_dst:
    # Returning to caller using ra (set by jalr above) should land after jalr.
    # We just need to ensure control reached here and ra is nonzero.
    ASSERT_NE_REG_IMM ra, 0, t03_fail
    TEST_PASS all_done

t03_fail:
    TEST_FAIL all_done

all_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/isa/jump_jal_jalr ===\n"
msg_done: .asciz "All tests in jump_jal_jalr complete.\n"

msg_t01: .asciz "Test 01: JAL link value (AUIPC delta)"
msg_t02: .asciz "Test 02: JALR return (call/return)"
msg_t03: .asciz "Test 03: JALR indirect jump"

.include "tests/common/test_runtime.s"

