.include "tests/common/test_macros.s"

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

t01_long_dependency_chain:
    TEST_BEGIN msg_t01
    # Deterministic dependency chain that keeps bypass paths busy.
    # x = 1
    # Repeat: x = (x*3 + 7) xor (x<<1) + (x>>1)
    # but expressed with RV32I ops only (no MUL): x*3 = x + x + x
    li      t0, 1                   # x
    .rept   50
        add     t3, t0, t0              # 2x
        add     t3, t3, t0              # 3x
        addi    t3, t3, 7               # 3x+7
        slli    t4, t0, 1               # x<<1
        xor     t3, t3, t4              # (3x+7) xor (x<<1)
        srli    t5, t0, 1               # x>>1
        add     t0, t3, t5              # new x depends on everything above
    .endr

    # Expected value for this recurrence with 50 iterations starting from x=1.
    # If bypassing/flush/stalls are broken, this will almost certainly differ.
    ASSERT_EQ_REG_IMM t0, 0x1996D3A0, t01_fail
    TEST_PASS all_done

t01_fail:
    TEST_FAIL all_done

all_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/hazards/bypass_stress ===\n"
msg_done: .asciz "All tests in bypass_stress complete.\n"

msg_t01: .asciz "Test 01: long dependency chain checksum"

.include "tests/common/test_runtime.s"

