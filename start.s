#.extern main
.globl _start

# ================================================================
# Lab 6 - RV32i Pipeline Test Suite  (rv32i only, no M extension)
#
# Output via memory-mapped UART: write byte to 0x0002FFF8
# Halt via memory-mapped register: write any value to 0x0002FFFC
#
# Each test prints its name then " --> PASS" or " --> FAIL ***"
# At the end C main() runs then halts.
# ================================================================

.text

_start:
    li      sp, (0x00030000 - 16)

    la      a0, msg_header
    call    print_str

    # ============================================================
    # TEST 01: Basic ALU, no data hazards (spacer instructions)
    # ============================================================
t01:
    la      a0, msg_t01
    call    print_str

    li      s0, 0
    li      s1, 0
    li      s2, 0
    li      t0, 40
    li      t1, 25
    add     t2, t0, t1              # t2 = 65
    li      s0, 0
    li      s1, 0
    li      s2, 0
    li      t3, 65
    bne     t2, t3, t01_fail

    li      s0, 0
    li      s1, 0
    li      s2, 0
    li      t0, 100
    li      t1, 37
    sub     t2, t0, t1              # t2 = 63
    li      s0, 0
    li      s1, 0
    li      s2, 0
    li      t3, 63
    bne     t2, t3, t01_fail

    la      a0, msg_pass
    call    print_str
    j       t02
t01_fail:
    la      a0, msg_fail
    call    print_str

    # ============================================================
    # TEST 02: EX->EX bypass (back-to-back ALU, no gaps)
    # ============================================================
t02:
    la      a0, msg_t02
    call    print_str

    li      a1, 7
    li      a2, 3
    add     a3, a1, a2              # a3 = 10
    add     a4, a3, a1              # a4 = 17  <-- EX->EX: uses a3
    add     a5, a4, a3              # a5 = 27  <-- EX->EX: uses a4, a3
    li      t0, 27
    bne     a5, t0, t02_fail

    li      a1, 50
    sub     a2, a1, a1              # a2 = 0
    sub     a3, a1, a2              # a3 = 50  <-- EX->EX: uses a2
    li      s0, 0
    li      s1, 0
    li      t0, 50
    bne     a3, t0, t02_fail

    la      a0, msg_pass
    call    print_str
    j       t03
t02_fail:
    la      a0, msg_fail
    call    print_str

    # ============================================================
    # TEST 03: MEM->EX bypass (one instruction gap)
    # ============================================================
t03:
    la      a0, msg_t03
    call    print_str

    li      a1, 4
    li      a2, 6
    add     a3, a1, a2              # a3 = 10
    li      a4, 5                   # one gap
    add     a5, a3, a4              # a5 = 15  <-- MEM->EX: uses a3
    li      t0, 15
    bne     a5, t0, t03_fail

    li      a1, 9
    li      a2, 3
    sub     a3, a1, a2              # a3 = 6
    addi    a4, zero, 4             # one gap
    add     a5, a3, a4              # a5 = 10  <-- MEM->EX: uses a3
    li      t0, 10
    bne     a5, t0, t03_fail

    la      a0, msg_pass
    call    print_str
    j       t04
t03_fail:
    la      a0, msg_fail
    call    print_str

    # ============================================================
    # TEST 04: Store + Load (2 gap instructions, no stall)
    # ============================================================
t04:
    la      a0, msg_t04
    call    print_str

    li      t0, 0x00020100
    li      t1, 0x12345678
    sw      t1, 0(t0)
    li      t2, 0                   # gap 1
    li      t3, 0                   # gap 2
    lw      t4, 0(t0)
    li      t2, 0                   # gap before use
    li      t3, 0
    li      t5, 0x12345678
    bne     t4, t5, t04_fail

    la      a0, msg_pass
    call    print_str
    j       t05
t04_fail:
    la      a0, msg_fail
    call    print_str

    # ============================================================
    # TEST 05: Load-use stall  lw->use
    # ============================================================
t05:
    la      a0, msg_t05
    call    print_str

    li      t0, 0x00020100
    li      t1, 42
    sw      t1, 0(t0)
    lw      t2, 0(t0)               # load 42
    add     t3, t2, t2              # t3 = 84  <-- load-use stall
    li      t4, 84
    bne     t3, t4, t05_fail

    li      t0, 0x00020100
    li      t1, 0x00020108
    sw      t1, 0(t0)
    lw      t2, 0(t0)               # load address
    li      t3, 99
    sw      t3, 0(t2)               # store at loaded address (load-use on t2)
    lw      t4, 0(t2)
    li      t5, 0
    li      t5, 0
    li      t5, 99
    bne     t4, t5, t05_fail

    la      a0, msg_pass
    call    print_str
    j       t06
t05_fail:
    la      a0, msg_fail
    call    print_str

    # ============================================================
    # TEST 06: Load-use stall  lb / lbu
    # ============================================================
t06:
    la      a0, msg_t06
    call    print_str

    li      t0, 0x00020100
    li      t1, -5
    sb      t1, 0(t0)
    lb      t2, 0(t0)               # load signed -5
    addi    t3, t2, 10              # t3 = 5  <-- load-use stall
    li      t4, 5
    bne     t3, t4, t06_fail

    li      t1, 200
    sb      t1, 0(t0)
    lbu     t2, 0(t0)               # load unsigned 200
    add     t3, t2, t2              # t3 = 400  <-- load-use stall
    li      t4, 400
    bne     t3, t4, t06_fail

    la      a0, msg_pass
    call    print_str
    j       t07
t06_fail:
    la      a0, msg_fail
    call    print_str

    # ============================================================
    # TEST 07: Load-use stall  lh
    # ============================================================
t07:
    la      a0, msg_t07
    call    print_str

    li      t0, 0x00020100
    li      t1, 1000
    sh      t1, 0(t0)
    lh      t2, 0(t0)               # load 1000
    add     t3, t2, t2              # t3 = 2000  <-- load-use stall
    li      t4, 2000
    bne     t3, t4, t07_fail

    la      a0, msg_pass
    call    print_str
    j       t08
t07_fail:
    la      a0, msg_fail
    call    print_str

    # ============================================================
    # TEST 08: Branch taken (beq, mispredict flush)
    # ============================================================
t08:
    la      a0, msg_t08
    call    print_str

    li      a1, 99
    li      a2, 99
    li      a3, 0
    beq     a1, a2, t08_taken       # TAKEN
    li      a3, 1                   # must be flushed
    li      a3, 2
    li      a3, 3
t08_taken:
    bne     a3, zero, t08_fail

    la      a0, msg_pass
    call    print_str
    j       t09
t08_fail:
    la      a0, msg_fail
    call    print_str

    # ============================================================
    # TEST 09: Branch not taken (beq where values differ)
    # ============================================================
t09:
    la      a0, msg_t09
    call    print_str

    li      a1, 1
    li      a2, 2
    li      a3, 0
    beq     a1, a2, t09_wrong       # NOT taken
    li      a3, 7
    j       t09_check
t09_wrong:
    li      a3, 99
t09_check:
    li      t0, 7
    bne     a3, t0, t09_fail

    la      a0, msg_pass
    call    print_str
    j       t10
t09_fail:
    la      a0, msg_fail
    call    print_str

    # ============================================================
    # TEST 10: BNE, BLT, BGE, BLTU, BGEU
    # ============================================================
t10:
    la      a0, msg_t10
    call    print_str

    li      a1, 3
    li      a2, 7
    li      a3, 0
    bne     a1, a2, t10_bne_ok      # 3 != 7 -> taken
    li      a3, 1
t10_bne_ok:
    bne     a3, zero, t10_fail

    li      a1, -3
    li      a2, 5
    li      a3, 0
    blt     a1, a2, t10_blt_ok      # signed: -3 < 5 -> taken
    li      a3, 1
t10_blt_ok:
    bne     a3, zero, t10_fail

    li      a1, 10
    li      a2, 10
    li      a3, 0
    bge     a1, a2, t10_bge_ok      # 10 >= 10 -> taken
    li      a3, 1
t10_bge_ok:
    bne     a3, zero, t10_fail

    li      a1, 1
    li      a2, -1
    li      a3, 0
    bltu    a1, a2, t10_bltu_ok     # unsigned: 1 < 0xFFFFFFFF -> taken
    li      a3, 1
t10_bltu_ok:
    bne     a3, zero, t10_fail

    li      a1, -1
    li      a2, 1
    li      a3, 0
    bgeu    a1, a2, t10_bgeu_ok     # unsigned: 0xFFFFFFFF >= 1 -> taken
    li      a3, 1
t10_bgeu_ok:
    bne     a3, zero, t10_fail

    la      a0, msg_pass
    call    print_str
    j       t11
t10_fail:
    la      a0, msg_fail
    call    print_str

    # ============================================================
    # TEST 11: JAL + JALR (call / return)
    # ============================================================
t11:
    la      a0, msg_t11
    call    print_str

    li      s0, 0
    jal     ra, t11_sub
    li      t0, 0xBEEF
    bne     s0, t0, t11_fail
    la      a0, msg_pass
    call    print_str
    j       t12

t11_sub:
    li      s0, 0xBEEF
    jalr    zero, 0(ra)

t11_fail:
    la      a0, msg_fail
    call    print_str

    # ============================================================
    # TEST 12: LUI and AUIPC
    # ============================================================
t12:
    la      a0, msg_t12
    call    print_str

    lui     a1, 0x12345             # a1 = 0x12345000
    li      t0, 0x12345000
    bne     a1, t0, t12_fail

    auipc   a2, 0                   # a2 = this instruction's PC
    auipc   a3, 0                   # a3 = PC + 4
    sub     a4, a3, a2              # must be exactly 4
    li      t0, 4
    bne     a4, t0, t12_fail

    la      a0, msg_pass
    call    print_str
    j       t13
t12_fail:
    la      a0, msg_fail
    call    print_str

    # ============================================================
    # TEST 13: Chained EX->EX: 1->2->4->8->16->32
    # ============================================================
t13:
    la      a0, msg_t13
    call    print_str

    li      a1, 1
    add     a2, a1, a1              # a2 =  2
    add     a3, a2, a2              # a3 =  4
    add     a4, a3, a3              # a4 =  8
    add     a5, a4, a4              # a5 = 16
    add     a6, a5, a5              # a6 = 32
    li      t0, 32
    bne     a6, t0, t13_fail

    la      a0, msg_pass
    call    print_str
    j       t14
t13_fail:
    la      a0, msg_fail
    call    print_str

    # ============================================================
    # TEST 14: Backward-branch loop (sum 5+4+3+2+1 = 15)
    # ============================================================
t14:
    la      a0, msg_t14
    call    print_str

    li      a1, 0
    li      a2, 5
t14_loop:
    add     a1, a1, a2
    addi    a2, a2, -1
    bne     a2, zero, t14_loop
    li      t0, 15
    bne     a1, t0, t14_fail

    la      a0, msg_pass
    call    print_str
    j       t15
t14_fail:
    la      a0, msg_fail
    call    print_str

    # ============================================================
    # TEST 15: SLTI, SLTIU, SLT
    # ============================================================
t15:
    la      a0, msg_t15
    call    print_str

    li      a1, -1
    slti    a2, a1, 0               # signed: -1 < 0 -> 1
    li      t0, 1
    bne     a2, t0, t15_fail

    sltiu   a3, a1, 1               # unsigned: 0xFFFFFFFF < 1 -> 0
    li      t0, 0
    bne     a3, t0, t15_fail

    li      a1, 5
    slt     a2, a1, a1              # 5 < 5 -> 0
    bne     a2, zero, t15_fail

    la      a0, msg_pass
    call    print_str
    j       t16
t15_fail:
    la      a0, msg_fail
    call    print_str

    # ============================================================
    # TEST 16: AND, OR, XOR, SLLI, SRLI, SRAI
    # ============================================================
t16:
    la      a0, msg_t16
    call    print_str

    li      a1, 0xFF00FF00
    li      a2, 0x0F0F0F0F
    and     a3, a1, a2              # 0x0F000F00
    li      t0, 0x0F000F00
    bne     a3, t0, t16_fail

    or      a4, a1, a2              # 0xFF0FFF0F
    li      t0, 0xFF0FFF0F
    bne     a4, t0, t16_fail

    xor     a5, a1, a2              # 0xF00FF00F
    li      t0, 0xF00FF00F
    bne     a5, t0, t16_fail

    li      a1, 1
    slli    a2, a1, 15              # a2 = 32768
    li      t0, 32768
    bne     a2, t0, t16_fail

    srli    a3, a2, 3               # a3 = 4096
    li      t0, 4096
    bne     a3, t0, t16_fail

    li      a1, -32768
    srai    a2, a1, 4               # arithmetic shift, stays negative
    bge     a2, zero, t16_fail

    la      a0, msg_pass
    call    print_str
    j       t17
t16_fail:
    la      a0, msg_fail
    call    print_str

    # ============================================================
    # TEST 17: Load widths and sign extension
    # ============================================================
t17:
    la      a0, msg_t17
    call    print_str

    li      t0, 0x00020120
    li      t1, 0xDEADBEEF
    sw      t1, 0(t0)

    lb      t2, 0(t0)               # byte 0 = 0xEF = -17 signed
    li      t3, 0                   # gap 1
    li      t3, 0                   # gap 2
    li      t4, -17
    bne     t2, t4, t17_fail

    lbu     t2, 0(t0)               # byte 0 = 0xEF = 239 unsigned
    li      t3, 0
    li      t3, 0
    li      t4, 239
    bne     t2, t4, t17_fail

    lh      t2, 0(t0)               # halfword = 0xBEEF = -16657 signed
    li      t3, 0
    li      t3, 0
    li      t4, -16657
    bne     t2, t4, t17_fail

    la      a0, msg_pass
    call    print_str
    j       t18
t17_fail:
    la      a0, msg_fail
    call    print_str

    # ============================================================
    # TEST 18: Loop: 6x7=42 by repeated addition
    # ============================================================
t18:
    la      a0, msg_t18
    call    print_str

    li      s0, 0
    li      s1, 6
    li      s2, 7
t18_loop:
    add     s0, s0, s2
    addi    s1, s1, -1
    bne     s1, zero, t18_loop
    li      t0, 42
    bne     s0, t0, t18_fail

    la      a0, msg_pass
    call    print_str
    j       all_done
t18_fail:
    la      a0, msg_fail
    call    print_str

all_done:
    la      a0, msg_done
    call    print_str

    call    main
    call    halt
    j       _start


# ============================================================
# print_str: print null-terminated string at a0
#
# KEY: addi a0, a0, 1 is placed BETWEEN lb and beq so that the
# pointer increment acts as a gap instruction, eliminating the
# load-use hazard on t1 without needing a pipeline stall.
# ============================================================
print_str:
    li      t0, 0x0002FFF8
ps_loop:
    lb      t1, 0(a0)
    addi    a0, a0, 1       # gap: advances pointer AND breaks lb->beq hazard
    beq     t1, zero, ps_ret
    sw      t1, 0(t0)
    j       ps_loop
ps_ret:
    ret


.data

msg_header:
    .asciz "\r\n========================================\r\n  Lab 6 - RV32i Pipeline Test Suite\r\n========================================\r\n"

msg_pass: .asciz " --> PASS\n"
msg_fail: .asciz " --> FAIL ***\n"

msg_done:
    .asciz "\n----------------------------------------\n  All pipeline tests complete.\n  C main() output follows:\n----------------------------------------\n"

msg_t01: .asciz "Test 01: Basic ALU, no hazards"
msg_t02: .asciz "Test 02: EX->EX bypass (back-to-back ALU)"
msg_t03: .asciz "Test 03: MEM->EX bypass (1-cycle gap)"
msg_t04: .asciz "Test 04: Store + Load (2-cycle gap, no stall)"
msg_t05: .asciz "Test 05: Load-use stall  lw->use"
msg_t06: .asciz "Test 06: Load-use stall  lb/lbu->use"
msg_t07: .asciz "Test 07: Load-use stall  lh->use"
msg_t08: .asciz "Test 08: Branch taken (beq mispredict flush)"
msg_t09: .asciz "Test 09: Branch not taken (beq, no flush)"
msg_t10: .asciz "Test 10: BNE + BLT + BGE + BLTU + BGEU"
msg_t11: .asciz "Test 11: JAL + JALR (call/return)"
msg_t12: .asciz "Test 12: LUI + AUIPC"
msg_t13: .asciz "Test 13: Chained bypass  1->2->4->8->16->32"
msg_t14: .asciz "Test 14: Backward-branch loop (sum 5..1 = 15)"
msg_t15: .asciz "Test 15: SLTI + SLTIU + SLT"
msg_t16: .asciz "Test 16: AND + OR + XOR + SLLI + SRLI + SRAI"
msg_t17: .asciz "Test 17: lb/lbu/lh sign extension"
msg_t18: .asciz "Test 18: Loop: 6x7=42 by repeated addition"
