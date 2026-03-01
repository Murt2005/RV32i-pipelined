
`define enable_ext_m        1
`define tag_size            5

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
        return false;
    else
        return true;
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
        default:
            return q_unknown;
    endcase
endfunction

function automatic bool decode_writeback(opcode_q in);
    case (in)
        q_load, q_jalr, q_jal, q_op_imm, q_op, q_auipc, q_lui:  return true;
        default: return false;
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
        q_load, q_op_imm, q_jalr:  return i_format;
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

// Must match instruction encoding
typedef enum logic [2:0] {
     beq = 0
    ,bne = 1
    ,blt = 4
    ,bge = 5
    ,bltu = 6
    ,bgeu = 7
}   branch_ops;

function automatic bool take_branch(ext_operand alu_result, funct3 f3); begin
    logic is_zero = (alu_result[31:0] == 32'd0) ? true : false;

    case (f3)
        beq:    return is_zero;
        bne:    return !is_zero;
        blt:    return alu_result[`word_size - 1];  // (in1 < in2) ? true : false;
        bge:    return !alu_result[`word_size - 1]; //(in1 >= in2) ? true : false;
        bltu:   return alu_result[`word_size];  // (pos_in1 < pos_in2) ? true : false;
        bgeu:   return !alu_result[`word_size]; //(pos_in1 >= pos_in2) ? true : false;
        default:
            return false;
    endcase
end
endfunction

function automatic word_address compute_next_pc(
     ext_operand    rd1
    ,ext_operand    alu_result
    ,word           imm
    ,word_address   pc
    ,opcode_q       op_q
    ,funct3         f3); begin
    word in1 = pc;
    word in2 = 4;
    case (op_q)
        q_jal:  in2 = imm;
        q_jalr: begin
            in1 = rd1[`word_size-1:0];
            in2 = imm[`word_size-1:0];
        end
        q_branch:
            if (take_branch(alu_result, f3))
                in2 = imm[`word_size-1:0];
        default: begin end
    endcase
    return in1 + in2;
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
        q_op, q_op_imm: begin
            case (f3)
                f3_addsub:
                    if (op_q == q_op_imm)
                        result = operand1 + operand2;
                    else
                        result = f7_mod(f7) ? (operand1 - operand2) : (operand1 + operand2);
                f3_slt:     result = (operand1 < operand2) ? 1 : 0;
                f3_sltu:    result = { 1'b0, operand1[`word_size-1:0] } < { 1'b0, operand2[`word_size-1:0] } ? 1 : 0;
                f3_sll:     result = operand1 << operand2[5:0];
                f3_sral:    result = f7_mod(f7) ? (operand1 >>> operand2[5:0]) : { 1'b0, operand1[`word_size-1:0] } >> operand2[5:0];
                f3_xor:     result = operand1 ^ operand2;
                f3_or:      result = operand1 | operand2;
                f3_and:     result = operand1 & operand2;
                default: begin
                            $display("Unimplemnted f3: %x", f3);
                            result = 0;
                end
            endcase
        end
        default: begin
            $display("Should never get here: pc=%x op=%b", pc, op_q);
            result = 0;
        end
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
