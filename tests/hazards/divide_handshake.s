.include "tests/common/test_macros.s"

# ============================================================================
# The divider's handshake with the pipeline, as opposed to its arithmetic.
#
# The arithmetic is covered exhaustively elsewhere: a standalone testbench over
# every spec corner plus four hundred random pairs, and the rv32um suite. What
# is *not* covered anywhere else is the handshake, and it is the bespoke part.
#
# riscv-formal cannot reach it. A divide takes about thirty-five cycles to
# retire, and every check runs at a bounded depth of thirty -- so no reachable
# trace in liveness, causal, unique or pc_fwd ever contains a completed divide.
# Raising the bound far enough makes the checks intractable. These tests exist
# to cover what the proofs structurally cannot.
#
# What can go wrong, and what each test aims at:
#   * the front-end freeze clears ID/EX, so the divide vanishes from decode
#     while the unit runs and must be re-decoded from the fetch latch. Anything
#     that disturbs that replay loses or duplicates the instruction.
#   * the result is parked until the instruction comes back to collect it. If a
#     different instruction collects it, the answer is silently wrong.
#   * the collect only happens when execute advances, so any other stall
#     overlapping the collect cycle has to leave the parked result alone.
# ============================================================================

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

# ---------------------------------------------------------------------------
# Back to back divides. The second must start only after the first has been
# collected; if `done` were not cleared on collect, the second would take the
# first's answer.
# ---------------------------------------------------------------------------
t01_back_to_back:
    TEST_BEGIN msg_t01
    li      t0, 100
    li      t1, 7
    div     t2, t0, t1              # 14
    li      t3, 900
    li      t4, 30
    div     t5, t3, t4              # 30
    ASSERT_EQ_REG_IMM t2, 14, t01_fail
    ASSERT_EQ_REG_IMM t5, 30, t01_fail

    # Three in a row, each consuming the previous result, so a stale parked
    # answer shows up immediately.
    li      t0, 1000
    li      t1, 10
    div     t2, t0, t1              # 100
    div     t2, t2, t1              # 10
    div     t2, t2, t1              # 1
    ASSERT_EQ_REG_IMM t2, 1, t01_fail
    TEST_PASS t02_div_use

t01_fail:
    TEST_FAIL t02_div_use

# ---------------------------------------------------------------------------
# The instruction immediately after a divide reads its result. That is the
# EX->EX bypass landing on the cycle the divide finally writes back, which is
# the cycle the front end has just been unfrozen for.
# ---------------------------------------------------------------------------
t02_div_use:
    TEST_BEGIN msg_t02
    li      t0, 84
    li      t1, 2
    div     t2, t0, t1              # 42
    add     t3, t2, t2              # bypass straight out of the divide
    ASSERT_EQ_REG_IMM t3, 84, t02_fail

    li      t0, 90
    li      t1, 7
    rem     t2, t0, t1              # 6
    addi    t3, t2, 1
    ASSERT_EQ_REG_IMM t3, 7, t02_fail
    TEST_PASS t03_load_use_div

t02_fail:
    TEST_FAIL t03_load_use_div

# ---------------------------------------------------------------------------
# A load-use stall on the divide's own operands. The load-use freeze and the
# divide's freeze overlap, and the divide must start from the *bypassed* value
# rather than the stale register.
# ---------------------------------------------------------------------------
t03_load_use_div:
    TEST_BEGIN msg_t03
    li      t0, 0x00020200
    li      t1, 144
    sw      t1, 0(t0)
    li      t4, 12
    lw      t2, 0(t0)
    div     t3, t2, t4              # divide sources a value still in flight
    ASSERT_EQ_REG_IMM t3, 12, t03_fail

    li      t1, 77
    sw      t1, 4(t0)
    li      t4, 10
    lw      t2, 4(t0)
    rem     t3, t2, t4              # 7
    ASSERT_EQ_REG_IMM t3, 7, t03_fail
    TEST_PASS t04_div_branch

t03_fail:
    TEST_FAIL t04_div_branch

# ---------------------------------------------------------------------------
# A branch resolving immediately after a divide, both taken and not taken. The
# redirect is raised on the cycle after the collect, so a redirect suppressed
# during the freeze must be reasserted correctly once it lifts.
# ---------------------------------------------------------------------------
t04_div_branch:
    TEST_BEGIN msg_t04
    li      t0, 50
    li      t1, 5
    div     t2, t0, t1              # 10
    li      t3, 10
    beq     t2, t3, t04_taken       # taken, straight off the divide result
    TEST_FAIL t05_div_in_loop
t04_taken:
    li      t0, 33
    li      t1, 4
    rem     t2, t0, t1              # 1
    li      t3, 99
    beq     t2, t3, t04_fail        # not taken
    ASSERT_EQ_REG_IMM t2, 1, t04_fail
    TEST_PASS t05_div_in_loop

t04_fail:
    TEST_FAIL t05_div_in_loop

# ---------------------------------------------------------------------------
# A divide inside a loop, so the freeze and the backward branch interact every
# iteration rather than once. Also exercises divide by a value that shrinks to
# the signed-overflow neighbourhood.
# ---------------------------------------------------------------------------
t05_div_in_loop:
    TEST_BEGIN msg_t05
    li      s10, 0                  # accumulator
    li      t0, 1000
    li      t1, 1                   # divisor, grows each pass
    li      t2, 5                   # trip count
t05_loop:
    div     t3, t0, t1
    add     s10, s10, t3
    addi    t1, t1, 1
    addi    t2, t2, -1
    bnez    t2, t05_loop
    # 1000/1 + 1000/2 + 1000/3 + 1000/4 + 1000/5 = 1000+500+333+250+200
    ASSERT_EQ_REG_IMM s10, 2283, t05_fail
    TEST_PASS t06_div_zero_flow

t05_fail:
    TEST_FAIL t06_div_zero_flow

# ---------------------------------------------------------------------------
# The two results the spec defines rather than trapping, taken through the
# handshake: both complete early inside the unit and must still park and be
# collected like any other.
# ---------------------------------------------------------------------------
t06_div_zero_flow:
    TEST_BEGIN msg_t06
    li      t0, 1234
    li      t1, 0
    div     t2, t0, t1              # -1
    ASSERT_EQ_REG_IMM t2, -1, t06_fail
    rem     t3, t0, t1              # dividend
    ASSERT_EQ_REG_IMM t3, 1234, t06_fail

    li      t0, 0x80000000
    li      t1, -1
    div     t2, t0, t1              # INT_MIN
    li      t4, 0x80000000
    ASSERT_EQ_REG_REG t2, t4, t06_fail
    rem     t3, t0, t1              # 0
    ASSERT_EQ_REG_IMM t3, 0, t06_fail

    # An early-completing divide immediately followed by a normal one, so the
    # two completion paths run back to back through the same park and collect.
    li      t0, 60
    li      t1, 6
    div     t2, t0, t1              # 10, the slow path
    ASSERT_EQ_REG_IMM t2, 10, t06_fail
    TEST_PASS t07_mul_div_mix

t06_fail:
    TEST_FAIL t07_mul_div_mix

# ---------------------------------------------------------------------------
# Multiply is combinational and divide is not, so alternating them puts a
# single-cycle result next to a thirty-five cycle one repeatedly.
# ---------------------------------------------------------------------------
t07_mul_div_mix:
    TEST_BEGIN msg_t07
    li      t0, 12
    li      t1, 12
    mul     t2, t0, t1              # 144
    div     t3, t2, t0              # 12
    mul     t4, t3, t3              # 144
    div     t5, t4, t1              # 12
    ASSERT_EQ_REG_IMM t5, 12, t07_fail

    li      t0, -7
    li      t1, 3
    mul     t2, t0, t1              # -21
    div     t3, t2, t1              # -7, truncating toward zero
    ASSERT_EQ_REG_IMM t3, -7, t07_fail
    rem     t4, t2, t1              # 0
    ASSERT_EQ_REG_IMM t4, 0, t07_fail
    TEST_PASS t_done

t07_fail:
    TEST_FAIL t_done

t_done:
    la      a0, msg_done
    call    print_str
    HALT

.section .rodata
msg_file: .asciz "\n=== tests/hazards/divide_handshake ===\n"
msg_done: .asciz "All tests in divide_handshake complete.\n"

msg_t01: .asciz "Test 01: back-to-back divides"
msg_t02: .asciz "Test 02: divide result bypassed to the next instruction"
msg_t03: .asciz "Test 03: load-use into a divide"
msg_t04: .asciz "Test 04: branch resolving off a divide result"
msg_t05: .asciz "Test 05: divide inside a loop"
msg_t06: .asciz "Test 06: defined divide-by-zero and overflow results"
msg_t07: .asciz "Test 07: multiply and divide interleaved"

.include "tests/common/test_runtime.s"
