.include "tests/common/test_macros.s"

# ============================================================================
# The SDRAM region, reached through the decoder and the arbiter.
#
# This is the first address region that is not a fixed alias of the two 64 KiB
# memories the design has always had, and the first that both core ports share.
# Three things are worth proving separately:
#
#   * the data side reaches it at all, at the right address, for every access
#     width -- the decoder routes by address now, where it used to discard the
#     top sixteen bits entirely.
#   * it is one device, not two. A word written through the data side and then
#     *executed* through the instruction side has to be the same word. That is
#     what makes it possible to load a program there at all, and it is exactly
#     what an instruction cache will break unless it is invalidated.
#   * the arbiter hands the bus back and forth without losing a response. Code
#     running from SDRAM while it also loads and stores to SDRAM puts both ports
#     on the same target at once, every cycle.
#
# The code that ends up in SDRAM is assembled normally and copied there, rather
# than written out as hex words. Hand-encoding is its own source of bugs, and a
# test that is wrong in the same direction as the design proves nothing. Both
# copied bodies use only PC-relative control flow, so they run correctly from
# an address they were not linked for.
# ============================================================================

.set SDRAM_BASE, 0x80000000
.set SDRAM_DATA, 0x80002000
.set SDRAM_CODE, 0x80001000

.text

_start:
    call    init_stack
    TEST_FILE_HEADER msg_file

# ---------------------------------------------------------------------------
# Word, halfword and byte access, and the fact that SDRAM is distinct storage
# from the data memory at the same offset.
# ---------------------------------------------------------------------------
t01_data_access:
    TEST_BEGIN msg_t01
    li      t0, SDRAM_BASE
    li      t1, 0x12345678
    sw      t1, 0(t0)
    lw      t2, 0(t0)
    ASSERT_EQ_REG_REG t2, t1, t01_fail

    # Byte lanes, so the write strobes are exercised through the decoder.
    li      t1, 0xAB
    sb      t1, 4(t0)
    lbu     t2, 4(t0)
    ASSERT_EQ_REG_IMM t2, 0xAB, t01_fail

    li      t1, 0xBEEF
    sh      t1, 8(t0)
    lhu     t2, 8(t0)
    ASSERT_EQ_REG_IMM t2, 0xBEEF, t01_fail

    # Data memory must be untouched: these are different devices now, where
    # every region used to alias onto every other. Scratch well clear of
    # .rodata, which starts at 0x00020000 -- writing there overwrites the
    # message strings and prints 0x5A5A5A5A as "ZZZZ".
    li      t3, 0x00021000
    li      t4, 0x5A5A5A5A
    sw      t4, 0(t3)
    lw      t2, 0(t0)
    li      t5, 0x12345678
    ASSERT_EQ_REG_REG t2, t5, t01_fail
    TEST_PASS t02_far_offsets

t01_fail:
    TEST_FAIL t02_far_offsets

# ---------------------------------------------------------------------------
# Addresses far apart inside the region, to show the decoder is not folding
# them together.
# ---------------------------------------------------------------------------
t02_far_offsets:
    TEST_BEGIN msg_t02
    li      t0, SDRAM_BASE
    li      t1, 0x11111111
    sw      t1, 0(t0)
    li      t2, 0x80080000          # 512 KiB up
    li      t3, 0x22222222
    sw      t3, 0(t2)
    lw      t4, 0(t0)
    ASSERT_EQ_REG_REG t4, t1, t02_fail
    lw      t4, 0(t2)
    ASSERT_EQ_REG_REG t4, t3, t02_fail
    TEST_PASS t03_execute_from_sdram

t02_fail:
    TEST_FAIL t03_execute_from_sdram

# ---------------------------------------------------------------------------
# Copy a function into SDRAM through the data port, then call it. The
# instruction port fetches what the data port stored, through the arbiter.
# ---------------------------------------------------------------------------
t03_execute_from_sdram:
    TEST_BEGIN msg_t03
    la      a2, fn_add_start
    la      a3, fn_add_end
    li      a4, SDRAM_CODE
    call    copy_words

    li      a0, 300
    li      a1, 45
    li      t0, SDRAM_CODE
    jalr    ra, t0, 0               # call into SDRAM
    ASSERT_EQ_REG_IMM a0, 345, t03_fail
    TEST_PASS t04_both_ports

t03_fail:
    TEST_FAIL t04_both_ports

# ---------------------------------------------------------------------------
# Both ports on SDRAM at once: a loop whose body runs from SDRAM and whose
# loads also target SDRAM. Every iteration has an instruction fetch and a data
# access contending for the same device.
# ---------------------------------------------------------------------------
t04_both_ports:
    TEST_BEGIN msg_t04
    la      a2, fn_sum_start
    la      a3, fn_sum_end
    li      a4, SDRAM_CODE
    call    copy_words

    # Fill an array in SDRAM with 1..8.
    li      t3, SDRAM_DATA
    li      t4, 1
    li      t5, 8
t04_fill:
    sw      t4, 0(t3)
    addi    t3, t3, 4
    addi    t4, t4, 1
    addi    t5, t5, -1
    bnez    t5, t04_fill

    li      a0, SDRAM_DATA
    li      a1, 8
    li      t0, SDRAM_CODE
    jalr    ra, t0, 0
    ASSERT_EQ_REG_IMM a0, 36, t04_fail      # 1+2+..+8
    TEST_PASS t_done

t04_fail:
    TEST_FAIL t_done

t_done:
    la      a0, msg_done
    call    print_str
    HALT

# ---------------------------------------------------------------------------
# copy_words: a2 = source, a3 = source end, a4 = destination.
# Clobbers a2, a4, t6.
# ---------------------------------------------------------------------------
copy_words:
    lw      t6, 0(a2)
    sw      t6, 0(a4)
    addi    a2, a2, 4
    addi    a4, a4, 4
    bltu    a2, a3, copy_words
    ret

# ---------------------------------------------------------------------------
# Bodies copied into SDRAM.
#
# In .rodata, not .text, because they are *read* by the data port -- and this is
# a Harvard machine whose data port cannot see instruction memory at all. In
# .text they would be copied as zeros and the jump would land in a field of
# illegal instructions.
#
# PC-relative control flow only, so they run correctly from an address they were
# not linked for; nothing here may reference a linked address.
# ---------------------------------------------------------------------------
.section .rodata
# Word alignment is required, not cosmetic: the copy loop reads these with lw,
# and .rodata already holds the macro strings, so without this the bodies land
# on a halfword boundary and the first load traps as misaligned. The trap
# vector is zero, so the symptom is execution at PC 0 with no other clue.
.balign 4
fn_add_start:
    add     a0, a0, a1
    ret
fn_add_end:

# a0 = array base, a1 = count. Returns the sum in a0.
.balign 4
fn_sum_start:
    mv      t3, a0
    mv      t2, a1
    li      a0, 0
fn_sum_loop:
    lw      t4, 0(t3)
    add     a0, a0, t4
    addi    t3, t3, 4
    addi    t2, t2, -1
    bnez    t2, fn_sum_loop
    ret
fn_sum_end:

msg_file: .asciz "\n=== tests/isa/sdram ===\n"
msg_done: .asciz "All tests in sdram complete.\n"

msg_t01: .asciz "Test 01: SDRAM data access, all widths, distinct from data memory"
msg_t02: .asciz "Test 02: far offsets are not folded together"
msg_t03: .asciz "Test 03: execute code written through the data port"
msg_t04: .asciz "Test 04: both ports contending on SDRAM"

.include "tests/common/test_runtime.s"
