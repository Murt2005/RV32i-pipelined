.include "tests/common/test_macros.s"

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

t01_counters_advance:
    TEST_BEGIN msg_t01
    li      t0, CYCLE_ADDR
    lw      s1, 0(t0)               # cycles, sample 1
    lw      s2, 0(t0)               # cycles, sample 2
    ASSERT_NE_REG_IMM s1, 0, t01_fail
    bgeu    s1, s2, t01_fail        # must be strictly increasing
    TEST_PASS t02_retired_advances

t01_fail:
    TEST_FAIL t02_retired_advances

t02_retired_advances:
    TEST_BEGIN msg_t02
    li      t0, RETIRED_ADDR
    lw      s1, 0(t0)
    lw      s2, 0(t0)
    ASSERT_NE_REG_IMM s1, 0, t02_fail
    bgeu    s1, s2, t02_fail
    TEST_PASS t03_ipc_sane

t02_fail:
    TEST_FAIL t03_ipc_sane

t03_ipc_sane:
    TEST_BEGIN msg_t03
    # Retired can never exceed cycles: this core issues at most one
    # instruction per cycle.
    li      t0, CYCLE_ADDR
    li      t1, RETIRED_ADDR
    lw      s1, 0(t1)               # retired
    lw      s2, 0(t0)               # cycles
    bgtu    s1, s2, t03_fail
    TEST_PASS all_done

t03_fail:
    TEST_FAIL all_done

all_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/isa/perf_counters ===\n"
msg_done: .asciz "All tests in perf_counters complete.\n"
msg_t01:  .asciz "Test 01: cycle counter advances"
msg_t02:  .asciz "Test 02: retired counter advances"
msg_t03:  .asciz "Test 03: retired <= cycles"

.include "tests/common/test_runtime.s"
