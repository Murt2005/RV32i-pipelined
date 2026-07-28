
// The M extension is on unless a build turns it off with -Dext_m_disable.
//
// It is not free: a combinational 32x32 multiplier costs roughly 3000 LUT4 on
// an iCE40, which takes the pico2-ice build from 4916 to 8019 and well past the
// 5280 that part has. That board's gateware therefore builds without it. On the
// Cyclone V the multiplier maps to DSP blocks and the area is not the issue.
`define tag_size            5

// Package-local alias. `bool` is also declared at compilation-unit scope in
// base.sv, but $unit types are not visible inside a package. Icarus has `bool`
// built in, so it must not be redeclared there.
`ifndef __ICARUS__
typedef logic bool;
`endif

typedef logic [`tag_size - 1:0]             tag;
typedef logic [4:0]                         shamt;
typedef logic [31:0]                        instr32;
typedef logic [2:0]                         funct3;
typedef logic [6:0]                         funct7;
typedef logic [6:0]                         opcode;
typedef logic signed [`word_size:0]         ext_operand;
typedef logic [`word_size - 1:0]            operand;
typedef logic [`word_size - 1:0]            word;
typedef logic [`word_address_size - 1:0]    word_address;

typedef enum {
     r_format = 0
    ,i_format
    ,s_format
    ,u_format
    ,b_format
    ,j_format
} instr_format;

function automatic bool is_16bit_instruction(logic [31:0] instr);
    if (instr[1:0] == 2'b11)
        return 1'b0;
    else
        return 1'b1;
endfunction

////// 32 bit instruction decode helpers.
function automatic tag decode_rs2(instr32 instr);
    return instr[24:20];
endfunction

function automatic shamt decode_shamt(instr32 instr);
    return instr[24:20];
endfunction

function automatic tag decode_rs1(instr32 instr);
    return instr[19:15];
endfunction

function automatic tag decode_rd(instr32 instr);
    return instr[11:7];
endfunction

// Must match instruction encoding
typedef enum logic [2:0] {
    f3_addsub  = 0
    ,f3_sll = 1
    ,f3_slt = 2
    ,f3_sltu = 3
    ,f3_xor = 4
    ,f3_sral = 5
    ,f3_or = 6
    ,f3_and = 7
}   f3_op;

// Must match instruction encoding
typedef enum logic [2:0] {
     f3_ext_m_mul = 3'd0
    ,f3_ext_m_mulh = 3'd1
    ,f3_ext_m_mulhsu = 3'd2
    ,f3_ext_m_mulhu = 3'd3
    ,f3_ext_m_div = 3'd4
    ,f3_ext_m_divu = 3'd5
    ,f3_ext_m_rem = 3'd6
    ,f3_ext_m_remu = 3'd7
}   f3_ext_m_op;

function funct3 decode_funct3(instr32 instr);
    return instr[14:12];
endfunction

localparam f7_add = 7'b0000000;
localparam f7_sub = 7'b0100000;
localparam f7_ext_mul = 7'b0000001;

function bool f7_mod(funct7 in);
    return in[5];
endfunction

function bool cast_to_f3_mod(funct7 in);
    return in[5];
endfunction

function automatic f3_ext_m_op cast_to_ext_m(funct3 in);
    return f3_ext_m_op'(in);
endfunction


function automatic opcode decode_opcode(instr32 instr);
    return instr[6:0];
endfunction

function automatic logic [`word_size-1:0] decode_imm(instr32 instr, instr_format format);
    case(format)
        i_format : return { {(`word_size - 32 + 21){instr[31]}},           instr[30:25], instr[24:21], instr[20] };
        s_format : return { {(`word_size - 32 + 21){instr[31]}},           instr[30:25], instr[11:8], instr[7] };
        b_format : return { {(`word_size - 32 + 20){instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0 };
        u_format : return { instr[31], instr[30:20], instr[19:12], {12{1'b0}} };
        j_format : return { {(`word_size - 32 + 12){instr[31]}}, instr[19:12], instr[20], instr[30:25], instr[24:21], 1'b0 };
        default: return {`word_size{1'b0}};       
    endcase 
endfunction

function automatic ext_operand cast_to_ext_operand(operand in);
    return { in[`word_size - 1], in };
endfunction 

function automatic operand cast_to_operand(ext_operand in);
    return in[`word_size - 1:0];
endfunction

function automatic bool is_negative(ext_operand in);
    return in[`word_size - 1];
endfunction

function automatic bool is_over_or_under(ext_operand in);
    return in[`word_size];
endfunction 

typedef enum logic [4:0] {
    q_load        = 5'b00000
    ,q_store      = 5'b01000
    ,q_madd       = 5'b10000
    ,q_branch     = 5'b11000
    ,q_load_fp    = 5'b00001
    ,q_store_fp   = 5'b01001
    ,q_msub       = 5'b10001
    ,q_jalr       = 5'b11001
    ,q_custom_0   = 5'b00010
    ,q_custom_1   = 5'b01010
    ,q_nmsub      = 5'b10010
    ,q_reserved_0 = 5'b11010
    ,q_misc_mem   = 5'b00011
    ,q_amo        = 5'b01011
    ,q_nmadd      = 5'b10011
    ,q_jal        = 5'b11011
    ,q_op_imm     = 5'b00100
    ,q_op         = 5'b01100
    ,q_op_fp      = 5'b10100
    ,q_system     = 5'b11100
    ,q_auipc      = 5'b00101
    ,q_lui        = 5'b01101
    ,q_reserved_1 = 5'b10101
    ,q_reserved_2 = 5'b11101
    ,q_op_imm32   = 5'b00110
    ,q_op32       = 5'b01110
    ,q_custom_2   = 5'b10110
    ,q_custom_3   = 5'b11110
    ,q_unknown    = 5'b00111
} opcode_q;

function automatic opcode_q decode_opcode_q(instr32 instr);
    // Every 32-bit instruction has instr[1:0] == 2'b11. Any other value is a
    // 16-bit compressed encoding, which this core does not implement, so it is
    // illegal. Checking only instr[6:2] decoded the all-zero word -- the
    // canonical illegal instruction -- as `lb x0, 0(x0)` and executed it.
    if (instr[1:0] != 2'b11)
        return q_unknown;

    // return instr[6:2]   --- this works too, but the code below detects opcodes we don't support
    case (instr[6:2])
// Unfortunately Vivado complains about the simple way. So we take the long way (below)
//        q_load, q_store, q_branch, q_jalr,
//        q_jal, q_op_imm, q_op, q_auipc, q_lui:   return instr[6:2];
            q_load:     return q_load;
            q_store:    return q_store;
            q_branch:   return q_branch;
            q_jalr:     return q_jalr;
            q_jal:      return q_jal;
            q_op_imm:   return q_op_imm;
            q_op:       return q_op;
            q_auipc:    return q_auipc;
            q_lui:      return q_lui;
            q_system:   return q_system;
            // FENCE. This core has a single in-order pipeline and separate
            // instruction and data memories, so it is architecturally a NOP --
            // but it must decode, or it would now raise an illegal-instruction
            // trap.
            q_misc_mem: return q_misc_mem;
        default:
            return q_unknown;
    endcase
endfunction

function automatic bool decode_writeback(opcode_q in);
    case (in)
        q_load, q_jalr, q_jal, q_op_imm, q_op, q_auipc, q_lui:  return 1'b1;
        // SYSTEM writes rd only for the CSR forms; execute squashes the write
        // for ECALL/EBREAK/MRET, which encode rd as x0 anyway.
        q_system: return 1'b1;
        default: return 1'b0;
    endcase
endfunction

// Must match instruction encoding
typedef enum logic [2:0] {
     memory_b = 0
    ,memory_h = 1
    ,memory_w = 2
    ,memory_bu = 4
    ,memory_hu = 5
}   memory_op;

function automatic memory_op cast_to_memory_op(funct3 in);
// This works, except Vivado complains. So we take the long way (below)
//    return in;  // Yes really
    case (in)
        memory_b: return memory_b;
        memory_h: return memory_h;
        memory_w: return memory_w;
        memory_bu: return memory_bu;
        memory_hu: return memory_hu;
        default: return memory_b;
    endcase;
endfunction

function automatic instr_format decode_format(opcode_q op_q);
    case (op_q)
        q_load, q_op_imm, q_jalr, q_system:  return i_format;
        q_jal:              return j_format;
        q_branch:           return b_format;
        q_op:               return r_format;
        q_store:            return s_format;
        q_lui, q_auipc:     return u_format;
        default:
            return r_format;
    endcase
endfunction

function automatic funct7 decode_funct7(instr32 instr, instr_format format);
    if (format == r_format || format == i_format)
        return instr[31:25];
    return 7'd0;
endfunction

// ---------------------------------------------------------------------------
// Machine-mode CSRs and traps.
//
// Only the handful the base ISA needs to take and return from a trap. Anything
// unimplemented reads as zero and ignores writes, which is what the spec allows
// for read-only-zero CSRs and keeps the register file tiny.
// ---------------------------------------------------------------------------
localparam [11:0] csr_mstatus = 12'h300;
localparam [11:0] csr_mtvec   = 12'h305;
localparam [11:0] csr_mepc    = 12'h341;
localparam [11:0] csr_mcause  = 12'h342;
localparam [11:0] csr_mtval   = 12'h343;

// Machine counters, read-only. Software needs a cycle count to benchmark
// itself, and rdcycle/mcycle is how it expects to get one -- Dhrystone's
// riscv variant reads mcycle directly.
localparam [11:0] csr_mcycle    = 12'hB00;
localparam [11:0] csr_minstret  = 12'hB02;
localparam [11:0] csr_mcycleh   = 12'hB80;
localparam [11:0] csr_minstreth = 12'hB82;

// Standard mcause codes for the exceptions this core can raise.
localparam [31:0] cause_misaligned_fetch = 32'd0;
localparam [31:0] cause_illegal_instr    = 32'd2;
localparam [31:0] cause_breakpoint       = 32'd3;
localparam [31:0] cause_misaligned_load  = 32'd4;
localparam [31:0] cause_misaligned_store = 32'd6;
localparam [31:0] cause_ecall_m          = 32'd11;

// funct3 for the SYSTEM opcode. 0 is the non-CSR group (ECALL/EBREAK/MRET).
typedef enum logic [2:0] {
     f3_priv   = 3'b000
    ,f3_csrrw  = 3'b001
    ,f3_csrrs  = 3'b010
    ,f3_csrrc  = 3'b011
    ,f3_csrrwi = 3'b101
    ,f3_csrrsi = 3'b110
    ,f3_csrrci = 3'b111
} f3_system;

function automatic bool is_csr_op(funct3 f3);
    return (f3 != 3'b000);
endfunction

// Alignment check for a data access of the width implied by funct3.
function automatic bool is_misaligned(word addr, memory_op op);
    case (op)
        memory_h, memory_hu: return addr[0];
        memory_w:            return (addr[1:0] != 2'b00);
        default:             return 1'b0;   // byte accesses are always aligned
    endcase
endfunction

// Must match instruction encoding
typedef enum logic [2:0] {
     beq = 0
    ,bne = 1
    ,blt = 4
    ,bge = 5
    ,bltu = 6
    ,bgeu = 7
}   branch_ops;

// Branch condition, evaluated from the operands rather than from the ALU
// result on purpose.
//
// Taking it from the ALU put the branch decision *after* the ALU's output mux,
// which put the next-PC adder after that again -- two 32-bit adders and a wide
// case mux in series on the critical path. Its own subtractor runs in parallel
// with the ALU instead. The result is the same; only the depth changes.
function automatic bool take_branch(ext_operand in1, ext_operand in2,
                                   funct3 f3); begin
    logic [`word_size:0] diff = {1'b0, in1[`word_size-1:0]}
                              - {1'b0, in2[`word_size-1:0]};
    logic is_zero = (diff[`word_size-1:0] == `word_size'd0) ? 1'b1 : 1'b0;

    // bit 32 is the borrow out of an unsigned subtract, i.e. exactly
    // (in1 <u in2).
    logic ult = diff[`word_size];

    // Signed less-than is NOT the sign bit of that difference: when the signed
    // subtraction overflows, the truncated result has the wrong sign. Flipping
    // both sign bits maps signed order onto unsigned order, which is the same
    // as xor-ing them into the unsigned result.
    //
    // e.g. in1 = 0x8534f457 (-2060127145), in2 = 0x2c33be0a (741588490):
    // in1 <s in2 is true, but bit 31 of the difference is 0.
    logic slt = ult ^ in1[`word_size - 1] ^ in2[`word_size - 1];

    case (f3)
        beq:    return is_zero;
        bne:    return !is_zero;
        blt:    return slt;
        bge:    return !slt;
        bltu:   return ult;
        bgeu:   return !ult;
        default:
            return 1'b0;
    endcase
end
endfunction

// Next PC, together with whether fetch already went there.
typedef struct packed {
    word_address next_pc;
    bool         mispredict;   // fetch is not presenting next_pc
} next_pc_result_t;

// Next PC.
//
// Two things are deliberately parallel here rather than serial:
//
//   * The three candidate targets are added up front, in parallel with each
//     other and with the ALU. Previously this built one adder whose *operands*
//     were chosen by the opcode and branch condition, chaining the adder
//     behind everything that produced them.
//   * Each candidate is compared against the address fetch is presenting, so
//     the 32-bit comparison happens alongside the adders and only a 1-bit
//     select is serial. Comparing after the target mux put a full-width
//     compare directly in front of the control logic.
//
// Returning both from one function keeps the value and the mispredict flag
// from drifting apart.
function automatic next_pc_result_t compute_next_pc(
     ext_operand    rd1
    ,ext_operand    rd2
    ,word           imm
    ,word_address   pc
    ,word_address   fetched_pc
    ,opcode_q       op_q
    ,funct3         f3); begin
    word pc_plus_4;
    word pc_plus_imm;
    word rs1_plus_imm;
    bool miss_p4, miss_pimm, miss_rimm;
    bool taken;
    next_pc_result_t r;

    pc_plus_4   = pc + `word_size'd4;
    pc_plus_imm = pc + imm;
    // "The target address is obtained by adding the sign-extended 12-bit
    // I-immediate to the register rs1, then setting the least-significant bit
    // of the result to zero." Without this an odd target is fetched as-is: the
    // memory drops the low address bits but shuffle_store_data still rotates
    // the word by addr[1:0], so the pipeline executes garbage.
    rs1_plus_imm = (rd1[`word_size-1:0] + imm) & ~(`word_size'd1);

    miss_p4   = (pc_plus_4    != fetched_pc);
    miss_pimm = (pc_plus_imm  != fetched_pc);
    miss_rimm = (rs1_plus_imm != fetched_pc);

    taken = take_branch(rd1, rd2, f3);

    case (op_q)
        q_jal:    begin r.next_pc = pc_plus_imm;  r.mispredict = miss_pimm; end
        q_jalr:   begin r.next_pc = rs1_plus_imm; r.mispredict = miss_rimm; end
        q_branch: begin
            r.next_pc    = taken ? pc_plus_imm : pc_plus_4;
            r.mispredict = taken ? miss_pimm   : miss_p4;
        end
        default:  begin r.next_pc = pc_plus_4;    r.mispredict = miss_p4; end
    endcase
    return r;
end
endfunction

function automatic ext_operand execute(
     ext_operand rd1
    ,ext_operand rd2
    ,ext_operand imm
    ,word        pc
    ,opcode_q    op_q
    ,funct3      f3
    ,funct7      f7);
    ext_operand result;
    ext_operand operand1, operand2;

    operand1 = (op_q == q_auipc)
        ? { 1'b0, pc } : rd1;
    operand2 = (op_q == q_op_imm || op_q == q_load || op_q == q_store || op_q == q_jalr || op_q == q_lui || op_q == q_auipc)
        ? imm : rd2;

    case (op_q)
        q_lui:              result = { 1'b0, imm[`word_size-1:0] };
        q_auipc:            result = { 1'b0, pc } + imm;
        q_jal, q_jalr:      result = { 1'b0, pc } + 4;
        q_branch:           result = { 1'b0, operand1[`word_size-1:0] } - { 1'b0, operand2[`word_size-1:0] };
        q_load, q_store, q_amo:    result = operand1 + operand2;
        // The CSR read value is muxed in by the execute stage, which owns the
        // CSR file; nothing useful to compute here.
        q_system, q_misc_mem:  result = 0;
`ifndef ext_m_disable
        q_op, q_op_imm: if ((op_q == q_op) && (f7 == f7_ext_mul)) begin
            // ---------------------------------------------------------------
            // M extension, multiply half.
            //
            // Combinational, unlike divide, because this is the operation Doom's
            // fixed-point maths runs on every inner loop -- putting it through an
            // iterative unit would cost thirty cycles apiece and defeat the point
            // of having the extension at all. It is a wide combinational path and
            // a candidate for pipelining once there is a real fMax number to
            // measure it against.
            //
            // The three high-half forms differ only in how the operands are
            // extended to 33 bits, so they share one 66-bit product. The low half
            // is the same for all signednesses, which is why MUL needs no variant
            // of its own.
            // ---------------------------------------------------------------
            logic signed [32:0] ext_a, ext_b;
            logic signed [65:0] product;

            ext_a = (f3 == f3_ext_m_mulhu)
                  ? $signed({1'b0, operand1[`word_size-1:0]})
                  : $signed({operand1[`word_size-1], operand1[`word_size-1:0]});
            ext_b = (f3 == f3_ext_m_mul || f3 == f3_ext_m_mulh)
                  ? $signed({operand2[`word_size-1], operand2[`word_size-1:0]})
                  : $signed({1'b0, operand2[`word_size-1:0]});
            product = ext_a * ext_b;

            case (f3)
                f3_ext_m_mul:     result = {1'b0, product[`word_size-1:0]};
                f3_ext_m_mulh,
                f3_ext_m_mulhsu,
                f3_ext_m_mulhu:   result = {1'b0, product[2*`word_size-1:`word_size]};
                // DIV/DIVU/REM/REMU are iterative and resolved in the execute
                // stage; it substitutes the result and never uses this.
                default:    result = 0;
            endcase
        end else begin
`else
        q_op, q_op_imm: begin
`endif
            case (f3)
                f3_addsub:
                    if (op_q == q_op_imm)
                        result = operand1 + operand2;
                    else
                        result = f7_mod(f7) ? (operand1 - operand2) : (operand1 + operand2);
                f3_slt:     result = (operand1 < operand2) ? 1 : 0;
                f3_sltu:    result = { 1'b0, operand1[`word_size-1:0] } < { 1'b0, operand2[`word_size-1:0] } ? 1 : 0;
                // RV32I: shifts use a 5-bit shift amount (rs2[4:0] or shamt[4:0])
                f3_sll: begin
                    word       sh_op1;
                    word       sh_res;
                    shamt      sh_amt;
                    sh_op1 = operand1[`word_size-1:0];
                    sh_amt = operand2[4:0];
                    sh_res = sh_op1 << sh_amt;
                    result = {1'b0, sh_res};
                end
                f3_sral: begin
                    word       sh_op1;
                    word       sh_res;
                    shamt      sh_amt;
                    sh_op1 = operand1[`word_size-1:0];
                    sh_amt = operand2[4:0];
                    if (f7_mod(f7))
                        sh_res = $signed(sh_op1) >>> sh_amt;   // SRA / SRAI (arithmetic)
                    else
                        sh_res = sh_op1 >> sh_amt;             // SRL / SRLI (logical)
                    result = {1'b0, sh_res};
                end
                f3_xor:     result = operand1 ^ operand2;
                f3_or:      result = operand1 | operand2;
                f3_and:     result = operand1 & operand2;
                default: result = 0;   // unreachable: f3 is fully decoded above
            endcase
        end
        // q_unknown lands here. It is no longer a "cannot happen" case: the
        // execute stage raises an illegal-instruction trap for it, so this
        // just needs to produce something harmless.
        default: result = 0;
    endcase
    //if (op_q == q_op_imm32 && f3 == f3_addsub)
    //    $display("%d: %x %x result32: %x result: %x", f7_mod(f7),
    //        operand1, operand2, result32, result);
    return result;
endfunction

function automatic word shuffle_load_data(word in, word low_addr); begin
    logic [7:0] b0 = in[7:0];
    logic [7:0] b1 = in[15:8];
    logic [7:0] b2 = in[23:16];
    logic [7:0] b3 = in[31:24];

    case (low_addr[1:0])
        2'b00:  return { b3, b2, b1, b0 };
        2'b01:  return { b0, b3, b2, b1 };
        2'b10:  return { b1, b0, b3, b2 };
        2'b11:  return { b2, b1, b0, b3 };
    endcase
end
endfunction

function automatic word shuffle_store_data(word in, word low_addr); begin
    logic [7:0] b0 = in[7:0];
    logic [7:0] b1 = in[15:8];
    logic [7:0] b2 = in[23:16];
    logic [7:0] b3 = in[31:24];

    case (low_addr[1:0])
        2'b00:  return { b3, b2, b1, b0 };
        2'b01:  return { b2, b1, b0, b3 };
        2'b10:  return { b1, b0, b3, b2 };
        2'b11:  return { b0, b3, b2, b1 };
    endcase
end
endfunction

function word subset_load_data(word in, memory_op op);
    case (op)
        memory_b:   return { {24{in[7]}}, in[7:0] };
        memory_h:   return { {16{in[15]}}, in[15:0] };
        memory_w:   return in;
        memory_bu:  return { {24{1'b0}}, in[7:0] };
        memory_hu:  return { {16{1'b0}}, in[15:0] };
        default:    return in;
    endcase
endfunction

function automatic logic [3:0] shuffle_store_mask(logic [3:0] mask, word low_addr);
    case (low_addr[1:0])
        2'b00:  return { mask[3], mask[2], mask[1], mask[0] };
        2'b01:  return { mask[2], mask[1], mask[0], mask[3] };
        2'b10:  return { mask[1], mask[0], mask[3], mask[2] };
        2'b11:  return { mask[0], mask[3], mask[2], mask[1] };
    endcase
endfunction

function automatic logic [3:0] memory_mask(memory_op op);
    case (op)
        memory_b, memory_bu:    return 4'b0001;
        memory_h, memory_hu:    return 4'b0011;
        default:                return 4'b1111;
    endcase
endfunction
