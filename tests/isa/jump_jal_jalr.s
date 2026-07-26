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
    TEST_PASS t04_jalr_lsb_cleared

t03_fail:
    TEST_FAIL t04_jalr_lsb_cleared

t04_jalr_lsb_cleared:
    TEST_BEGIN msg_t04
    # JALR must clear bit 0 of the computed target. The offset below is odd, so
    # a core that skips the mask jumps to an unaligned address and executes a
    # rotated word.
    li      t2, 0
    auipc   t0, 0                   # t0 = address of this instruction
    jalr    ra, t0, 13              # -> t0 + 13, masked to t0 + 12
    li      t2, 1                   # must be skipped
    li      t2, 2                   # landing point
    ASSERT_EQ_REG_IMM t2, 2, t04_fail
    TEST_PASS all_done

t04_fail:
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
msg_t04: .asciz "Test 04: JALR clears target bit 0"
msg_t03: .asciz "Test 03: JALR indirect jump"

.include "tests/common/test_runtime.s"

