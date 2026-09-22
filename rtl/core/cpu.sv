`ifndef __cpu_sv
`define __cpu_sv

`include "riscv.sv"
`include "divider.sv"

typedef struct packed {
    bool is_pc_valid;
    riscv::word pc;
} branch_pc_redirect_request_t;

typedef struct packed {
    bool advance;
    bool flush;
} stage_control_signal_t;

typedef struct packed {
    bool is_instruction_valid;
    riscv::instr32 instruction;
    riscv::word pc;
} fetched_instruction_t;

typedef struct packed {
    bool is_instruction_valid;
    riscv::tag rs1;
    riscv::tag rs2;
    riscv::word rd1;
    riscv::word rd2;
    riscv::word imm;
    riscv::tag writeback_select;
    bool is_writeback_valid;
    riscv::funct3 f3;
    riscv::funct7 f7;
    riscv::opcode_q instruction_opcode;
    riscv::instr_format instruction_format;
    riscv::instr32 instruction;
    riscv::word pc;
} decoded_instruction_t;

typedef struct packed {
    bool is_instruction_valid;
    bool is_writeback_valid;
    riscv::tag wbs;
    riscv::word wbd;
} writeback_instruction_t;

typedef struct packed {
    bool bypass_is_valid;
    riscv::word rd;
    riscv::tag rs;
} register_file_bypass_t;

typedef struct packed {
    bool is_instruction_valid;
    riscv::tag rs1;
    riscv::tag rs2;
    riscv::word rd1;
    riscv::word rd2;
    riscv::funct3 f3;
    riscv::opcode_q instruction_opcode;
    writeback_instruction_t writeback_instruction;
} executed_instruction_t;

function automatic bool is_load_use_hazard(executed_instruction_t ex, decoded_instruction_t de);
    return ex.is_instruction_valid
        && (ex.instruction_opcode == riscv::q_load)
        && de.is_instruction_valid
        && (ex.writeback_instruction.wbs != 5'd0)
        && ((de.rs1 == ex.writeback_instruction.wbs)
         || (de.rs2 == ex.writeback_instruction.wbs));
endfunction

typedef struct packed {
    bool branch_redirect_needed;
    riscv::word branch_target_pc;
} pc_control_t;

typedef struct packed {
    bool        valid;
    bool        taken;
    riscv::word pc;
    riscv::word target;
} btb_update_t;

typedef struct packed {
    bool        taken;
    riscv::word cause;
    riscv::word epc;
    riscv::word tval;
} trap_t;

typedef struct packed {
    bool is_instruction_valid;
    riscv::word pc;
    riscv::word execute_result;
    riscv::funct3 f3;
    riscv::opcode_q instruction_opcode;
    writeback_instruction_t writeback_instruction;
} memory_instruction_t;


// -- FETCH --
// Issues instruction memory requests and presents one instruction per cycle to decode
module fetch #(
    parameter btb_enable  = 1,
    parameter btb_entries = 16          // must be a power of two
) (
    input logic                                 clk,
    input logic                                 reset,
    input logic                                 [`word_address_size-1:0] reset_pc,

    input stage_control_signal_t                fetch_control_signal_in,

    input branch_pc_redirect_request_t          branch_pc_redirect_request_in,
    input btb_update_t                          btb_update_in,

    output memory_io_req                        instruction_memory_request,
    input memory_io_rsp                         instruction_memory_response,

    output riscv::word                          instruction_memory_addr,

    output logic                                instruction_memory_wait,

    output fetched_instruction_t                fetched_instruction_out
);

import riscv::*;

word fetch_pc;
assign instruction_memory_addr = fetch_pc;
bool clear_fetch_stream;
word clear_to_this_pc;
instr32 latched_instruction_read;
bool latched_instruction_valid;
word latched_instruction_pc;

// Address of the request issued in the previous cycle
word issued_pc;
bool issued_valid;

// Front-end stall for an instruction memory that does not answer in one cycle
logic instruction_fetch_outstanding;
logic instruction_miss_q;

wire instruction_miss = instruction_fetch_outstanding & ~instruction_memory_response.valid;

assign instruction_memory_wait = instruction_miss | instruction_miss_q | ~instruction_memory_response.ready;

always_ff @(posedge clk) begin
    if (reset) begin
        instruction_fetch_outstanding <= 1'b0;
        instruction_miss_q            <= 1'b0;
    end else begin
        if (instruction_memory_request.valid)
            instruction_fetch_outstanding <= 1'b1;
        else if (instruction_memory_response.valid)
            instruction_fetch_outstanding <= 1'b0;
        instruction_miss_q <= instruction_miss;
    end
end

// Branch target buffer: direct mapped, no history, predict taken on a hit
localparam int BTB_IDX_W = $clog2(btb_entries);
localparam int BTB_TAG_W = 8;

logic [BTB_TAG_W-1:0] btb_tag    [0:btb_entries-1];
logic [13:0]          btb_target [0:btb_entries-1];
logic                 btb_valid  [0:btb_entries-1];

wire [BTB_IDX_W-1:0] btb_rd_idx = fetch_pc[BTB_IDX_W+1:2];
wire [BTB_TAG_W-1:0] btb_rd_tag = fetch_pc[BTB_IDX_W+1+BTB_TAG_W:BTB_IDX_W+2];
wire                 btb_hit    = (btb_enable != 0) && btb_valid[btb_rd_idx]
                                && (btb_tag[btb_rd_idx] == btb_rd_tag);
wire [`word_size-1:0] btb_predicted = {fetch_pc[`word_size-1:16],
                                       btb_target[btb_rd_idx], 2'b00};

wire [BTB_IDX_W-1:0] btb_wr_idx = btb_update_in.pc[BTB_IDX_W+1:2];
wire [BTB_TAG_W-1:0] btb_wr_tag = btb_update_in.pc[BTB_IDX_W+1+BTB_TAG_W:BTB_IDX_W+2];

// instruction memory request and fetch output
always @(*) begin
    instruction_memory_request = memory_io_no_req;
    instruction_memory_request.addr = fetch_pc;
    instruction_memory_request.do_read[3:0] = 4'b1111;
    instruction_memory_request.valid = instruction_memory_response.ready && fetch_control_signal_in.advance;
    instruction_memory_request.user_tag = 0;

    // output whatever we have latched as default
    fetched_instruction_out.pc = latched_instruction_pc;
    fetched_instruction_out.is_instruction_valid = latched_instruction_valid;
    fetched_instruction_out.instruction = latched_instruction_read;

    if (instruction_memory_response.valid && fetch_control_signal_in.advance) begin
        if (clear_fetch_stream && instruction_memory_response.addr != clear_to_this_pc) begin
            // this response is from a request we're flushing, do not forward
        end else begin
            word memory_read;
            memory_read = shuffle_store_data(instruction_memory_response.data, instruction_memory_response.addr);
            fetched_instruction_out.is_instruction_valid = true;
            fetched_instruction_out.pc = instruction_memory_response.addr;
            fetched_instruction_out.instruction = memory_read[31:0];
        end
    end
end

// update PC, latches, and clear state
always_ff @(posedge clk) begin
    if (reset) begin
        fetch_pc <= reset_pc;
        latched_instruction_valid <= false;
        clear_fetch_stream <= false;
        clear_to_this_pc <= 0;
        issued_pc <= 0;
        issued_valid <= false;
        for (int i = 0; i < btb_entries; i++)
            btb_valid[i] <= 1'b0;
    end else begin
        issued_valid <= instruction_memory_request.valid;
        if (instruction_memory_request.valid)
            issued_pc <= fetch_pc;
        if (instruction_memory_response.valid) begin
            if (clear_fetch_stream && instruction_memory_response.addr != clear_to_this_pc) begin
                // discard flushed instruction
            end else begin
                clear_fetch_stream <= false;
                if (fetch_control_signal_in.advance) begin
                    word memory_read;
                    memory_read = shuffle_store_data(instruction_memory_response.data, instruction_memory_response.addr);
                    latched_instruction_pc <= instruction_memory_response.addr;
                    latched_instruction_read <= memory_read[31:0];
                    latched_instruction_valid <= true;
                end
            end
        end

        if (instruction_memory_request.valid) begin
            if (btb_hit)
                fetch_pc <= btb_predicted;
            else
                fetch_pc <= fetch_pc + 4;
        end

        if ((btb_enable != 0) && btb_update_in.valid) begin
            if (btb_update_in.taken) begin
                btb_valid[btb_wr_idx]  <= 1'b1;
                btb_tag[btb_wr_idx]    <= btb_wr_tag;
                btb_target[btb_wr_idx] <= btb_update_in.target[15:2];
            end else if (btb_valid[btb_wr_idx] && (btb_tag[btb_wr_idx] == btb_wr_tag)) begin
                // fell through: stop predicting it, or every pass would mispredict twice instead of once
                btb_valid[btb_wr_idx] <= 1'b0;
            end
        end

        if (branch_pc_redirect_request_in.is_pc_valid) begin
            fetch_pc <= branch_pc_redirect_request_in.pc;
            latched_instruction_valid <= false;
            clear_fetch_stream <= true;
            clear_to_this_pc <= branch_pc_redirect_request_in.pc;
        end else if (!fetch_control_signal_in.advance) begin
            if (latched_instruction_valid) begin
                fetch_pc <= latched_instruction_pc + 4;
                clear_fetch_stream <= true;
                clear_to_this_pc <= latched_instruction_pc + 4;
            end else if (clear_fetch_stream) begin
                fetch_pc <= clear_to_this_pc;
                clear_fetch_stream <= true;
            end else if (issued_valid) begin
                fetch_pc <= issued_pc;
                clear_fetch_stream <= true;
                clear_to_this_pc <= issued_pc;
            end
        end
    end
end
endmodule

// -- DECODE --
// Holds the register file, decodes the fetched instruction, and writes back results
// from the writeback stage. Produces decoded_instruction for execute and bypass info
// so later stages can forward the current write-back to resolve RAW hazards
module decode_and_writeback(
    input logic                                 clk,
    input logic                                 reset,
    input logic                                 clear_regs,     // hold high >=32 cycles to zero the register file

    input stage_control_signal_t                decode_control_signal_in,
    input stage_control_signal_t                execute_control_signal_in,
    input stage_control_signal_t                writeback_control_signal_in,

    output register_file_bypass_t               register_file_bypass_out,

    input fetched_instruction_t                 fetched_instruction_in,
    output decoded_instruction_t                decoded_instruction_out,

    input writeback_instruction_t               writeback_instruction_in
);

import riscv::*;

// Register file and bypass state
(* ram_style = "block" *)
word register_file[0:31];
word register_file_bypass_rd;
tag register_file_bypass_rs;
bool register_file_bypass_valid;
tag  clear_idx;

always_comb begin
    register_file_bypass_out.bypass_is_valid = register_file_bypass_valid;
    register_file_bypass_out.rd = register_file_bypass_rd;
    register_file_bypass_out.rs = register_file_bypass_rs;
end

initial begin
    for (int i = 0; i < 32; i++)
        register_file[i] = `word_size'd0;
end

always_ff @(posedge clk) begin
    word wbd;
    tag rs1;
    tag rs2;
    opcode_q op_q;
    instr_format format;

    rs1 = decode_rs1(fetched_instruction_in.instruction);
    rs2 = decode_rs2(fetched_instruction_in.instruction);
    op_q = decode_opcode_q(fetched_instruction_in.instruction);
    format = decode_format(op_q);

    if (reset)
        register_file_bypass_valid <= false;
    else
        register_file_bypass_valid <= false;

    if (reset || decode_control_signal_in.flush) begin
        decoded_instruction_out <= {($bits(decoded_instruction_t)){1'b0}};
        decoded_instruction_out.is_instruction_valid <= false;
    end else begin
        if (decode_control_signal_in.advance && fetched_instruction_in.is_instruction_valid) begin
            decoded_instruction_out.is_instruction_valid <= true;
            decoded_instruction_out.rs1 <= rs1;
            decoded_instruction_out.rs2 <= rs2;
            decoded_instruction_out.writeback_select <= decode_rd(fetched_instruction_in.instruction);
            decoded_instruction_out.f3 <= decode_funct3(fetched_instruction_in.instruction);
            decoded_instruction_out.instruction_opcode <= op_q;
            decoded_instruction_out.instruction_format <= format;
            decoded_instruction_out.imm <= decode_imm(fetched_instruction_in.instruction, format);
            decoded_instruction_out.is_writeback_valid <= decode_writeback(op_q);
            decoded_instruction_out.f7 <= decode_funct7(fetched_instruction_in.instruction, format);
            decoded_instruction_out.pc <= fetched_instruction_in.pc;
            decoded_instruction_out.instruction <= fetched_instruction_in.instruction;
        end else begin
            // no advance or invalid fetch, send a bubble
            decoded_instruction_out <= {($bits(decoded_instruction_t)){1'b0}};
            decoded_instruction_out.is_instruction_valid <= false;
        end
    end

    if (decode_control_signal_in.advance && fetched_instruction_in.is_instruction_valid) begin
        decoded_instruction_out.rd1 <= register_file[rs1];
        decoded_instruction_out.rd2 <= register_file[rs2];
    end

    // Write-back: record the bypass
    if (!reset
        && writeback_control_signal_in.advance
        && writeback_instruction_in.is_instruction_valid
        && writeback_instruction_in.is_writeback_valid) begin
        register_file_bypass_rs <= writeback_instruction_in.wbs;
        register_file_bypass_rd <= writeback_instruction_in.wbd;
        register_file_bypass_valid <= true;
    end

    if (clear_regs)
        clear_idx <= clear_idx + 5'd1;
    else
        clear_idx <= 5'd0;
end

logic wr_en;
tag   wr_addr;
word  wr_data;

always_comb begin
    if (clear_regs) begin
        wr_en   = 1'b1;
        wr_addr = clear_idx;
        wr_data = `word_size'd0;
    end else begin
        wr_en   = !reset
                  && writeback_control_signal_in.advance
                  && writeback_instruction_in.is_instruction_valid
                  && writeback_instruction_in.is_writeback_valid;
        wr_addr = writeback_instruction_in.wbs;
        wr_data = writeback_instruction_in.wbd;
    end
end

always_ff @(posedge clk) begin
    if (wr_en)
        register_file[wr_addr] <= wr_data;
end
endmodule

// -- EXECUTE --
// Performs ALU operation, computes next PC (PC+4 or branch/jump target), and detects
// branch mispredicts. Outputs executed_instruction (with write-back info) to memory
// and pc_control for redirecting fetch. Uses bypass from decode/writeback and later
// stages to resolve RAW hazards.
module execute(
    input logic                                 clk,
    input logic                                 reset,
    input riscv::word                           reset_pc,

    input stage_control_signal_t                execute_control_signal_in,
    input stage_control_signal_t                memory_control_signal_in,

    input fetched_instruction_t                 fetched_instruction_in,

    input register_file_bypass_t                register_file_bypass_in,
    input executed_instruction_t                executed_instruction_in,
    input writeback_instruction_t               writeback_instruction_in,

    input decoded_instruction_t                 decoded_instruction_in,
    output executed_instruction_t               executed_instruction_out,

    output pc_control_t                         pc_control_out,
    output btb_update_t                         btb_update_out,

    output logic                                div_wait
`ifdef RVFI
    ,output logic                               rvfi_ex_valid
    ,output logic                               [31:0] rvfi_ex_insn
    ,output logic                               [31:0] rvfi_ex_pc
    ,output logic                               [31:0] rvfi_ex_next_pc
    ,output logic                               [4:0]  rvfi_ex_rs1_addr
    ,output logic                               [4:0]  rvfi_ex_rs2_addr
    ,output logic                               [31:0] rvfi_ex_rs1_rdata
    ,output logic                               [31:0] rvfi_ex_rs2_rdata
    ,output logic                               rvfi_ex_trap
`endif
);

import riscv::*;

ext_operand execute_result_comb;
next_pc_result_t next_pc_result;
word next_pc_comb;
bool mispredict;
word bypassed_rd1_comb;
word bypassed_rd2_comb;

`ifndef ext_m_disable
wire is_div_op = decoded_instruction_in.is_instruction_valid
              && (decoded_instruction_in.instruction_opcode == q_op)
              && (decoded_instruction_in.f7 == f7_ext_mul)
              && decoded_instruction_in.f3[2];      // 4..7 are DIV/DIVU/REM/REMU

logic        div_busy, div_done;
word         div_result;

wire div_start = is_div_op & ~div_busy & ~div_done & ~is_load_use_hazard(executed_instruction_in, decoded_instruction_in);
wire div_take  = is_div_op &  div_done & execute_control_signal_in.advance;

assign div_wait = (is_div_op & ~div_done) | div_busy;

divider divider_m(
    .clk(clk),
    .reset(reset),
    .start(div_start),
    .dividend(bypassed_rd1_comb),
    .divisor(bypassed_rd2_comb),
    .is_signed(~decoded_instruction_in.f3[0]),
    .want_rem(decoded_instruction_in.f3[1]),
    .busy(div_busy),
    .done(div_done),
    .take(div_take),
    .result(div_result)
);

`ifndef SYNTHESIS
integer div_park;
always @(posedge clk) begin
    if (reset || !div_done)      div_park <= 0;
    else if (div_done)           div_park <= div_park + 1;
    if (div_park > 65536)
        $error("%m: divider result parked for %0d cycles and owner never returned", div_park);
end
`endif
`else
wire                  is_div_op  = 1'b0;
wire                  div_done   = 1'b0;
wire [`word_size-1:0] div_result = '0;
assign div_wait = 1'b0;
`endif

// Machine-mode CSR file
word mstatus_r, mtvec_r, mepc_r, mcause_r, mtval_r;

// Machine counters; 64 bits so a long benchmark cannot wrap mid-measurement
logic [63:0] mcycle_r, minstret_r;

localparam int MSTATUS_MIE  = 3;
localparam int MSTATUS_MPIE = 7;

logic [11:0] csr_addr;
word         csr_read;
word         csr_write;
bool         csr_wen;

bool  is_system, is_csr, is_ecall, is_ebreak, is_mret;
bool  illegal_instr, misaligned_load, misaligned_store;
word  mem_addr;
trap_t trap;

// Resolve one source operand against the three bypass sources
function automatic word select_operand(input tag rs, input word rf_value);
    bool hit_ex, hit_wb, hit_byp;
    logic [1:0] sel;

    hit_ex = executed_instruction_in.is_instruction_valid
           & executed_instruction_in.writeback_instruction.is_writeback_valid
           & (executed_instruction_in.writeback_instruction.wbs != 5'd0)
           & (executed_instruction_in.instruction_opcode != q_load)
           & (rs == executed_instruction_in.writeback_instruction.wbs);

    hit_wb = writeback_instruction_in.is_instruction_valid
           & writeback_instruction_in.is_writeback_valid
           & (writeback_instruction_in.wbs != 5'd0)
           & (rs == writeback_instruction_in.wbs);

    hit_byp = register_file_bypass_in.bypass_is_valid
            & (register_file_bypass_in.rs != 5'd0)
            & (rs == register_file_bypass_in.rs);

    sel = hit_ex  ? 2'd3 :
          hit_wb  ? 2'd2 :
          hit_byp ? 2'd1 : 2'd0;

    case (sel)
        2'd3:    select_operand = executed_instruction_in.writeback_instruction.wbd;
        2'd2:    select_operand = writeback_instruction_in.wbd;
        2'd1:    select_operand = register_file_bypass_in.rd;
        default: select_operand = (rs == 5'd0) ? `word_size'd0 : rf_value;
    endcase
endfunction

// operands, ALU, next-PC, and mispredict detection
always_comb begin
    word rd1;
    word rd2;

    // Bypass Logic
    // Priority (highest first):
    //   1. executed_instruction_in: EX/MEM result (1 instruction ago), valid
    //      only for NON-LOAD instructions
    //   2. writeback_instruction_in: MEM/WB result (2 ago), valid for all
    //      instruction types including loads
    //   3. register_file_bypass: result written to the register file in the
    //      same cycle decode read it (WB concurrent with ID)
    //   4. the register file value captured at decode

    rd1 = select_operand(decoded_instruction_in.rs1, decoded_instruction_in.rd1);
    rd2 = select_operand(decoded_instruction_in.rs2, decoded_instruction_in.rd2);

    bypassed_rd1_comb = rd1;
    bypassed_rd2_comb = rd2;

    // SYSTEM decode and CSR access
    csr_addr  = decoded_instruction_in.instruction[31:20];
    is_system = (decoded_instruction_in.instruction_opcode == q_system);
    is_csr    = is_system && is_csr_op(decoded_instruction_in.f3);
    is_ecall  = is_system && (decoded_instruction_in.f3 == 3'b000) && (csr_addr == 12'h000);
    is_ebreak = is_system && (decoded_instruction_in.f3 == 3'b000) && (csr_addr == 12'h001);
    is_mret   = is_system && (decoded_instruction_in.f3 == 3'b000) && (csr_addr == 12'h302);

    case (csr_addr)
        csr_mstatus: csr_read = mstatus_r;
        csr_mtvec:   csr_read = mtvec_r;
        csr_mepc:    csr_read = mepc_r;
        csr_mcause:  csr_read = mcause_r;
        csr_mtval:   csr_read = mtval_r;
        csr_mcycle:    csr_read = mcycle_r[31:0];
        csr_mcycleh:   csr_read = mcycle_r[63:32];
        csr_minstret:  csr_read = minstret_r[31:0];
        csr_minstreth: csr_read = minstret_r[63:32];
        default:     csr_read = `word_size'd0;   // unimplemented reads as zero
    endcase

    begin
        word csr_operand;
        csr_operand = decoded_instruction_in.f3[2]
                    ? {{(`word_size-5){1'b0}}, decoded_instruction_in.rs1}
                    : rd1;

        case (decoded_instruction_in.f3[1:0])
            2'b01:   csr_write = csr_operand;                 // csrrw / csrrwi
            2'b10:   csr_write = csr_read | csr_operand;      // csrrs / csrrsi
            default: csr_write = csr_read & ~csr_operand;     // csrrc / csrrci
        endcase

        csr_wen = is_csr &&
                  ((decoded_instruction_in.f3[1:0] == 2'b01) ||
                   (decoded_instruction_in.rs1 != 5'd0));
    end

    // ALU / execution: computes result for R-type, I-type, U-type, etc. (add, sub, shift, compare, etc.)
    execute_result_comb = execute(
        cast_to_ext_operand(rd1),
        cast_to_ext_operand(rd2),
        cast_to_ext_operand(decoded_instruction_in.imm),
        decoded_instruction_in.pc,
        decoded_instruction_in.instruction_opcode,
        decoded_instruction_in.f3,
        decoded_instruction_in.f7);

    if (is_div_op && div_done)
        execute_result_comb = {1'b0, div_result};

    // Exceptions
    illegal_instr = (decoded_instruction_in.instruction_opcode == q_unknown);

    mem_addr = execute_result_comb[`word_size-1:0];
    misaligned_load  = (decoded_instruction_in.instruction_opcode == q_load)
                     && is_misaligned(mem_addr, cast_to_memory_op(decoded_instruction_in.f3));
    misaligned_store = (decoded_instruction_in.instruction_opcode == q_store)
                     && is_misaligned(mem_addr, cast_to_memory_op(decoded_instruction_in.f3));

    trap       = {($bits(trap_t)){1'b0}};
    trap.epc   = decoded_instruction_in.pc;
    if (decoded_instruction_in.is_instruction_valid) begin
        if (illegal_instr) begin
            trap.taken = true;
            trap.cause = cause_illegal_instr;
            trap.tval  = decoded_instruction_in.instruction;
        end else if (is_ecall) begin
            trap.taken = true;
            trap.cause = cause_ecall_m;
        end else if (is_ebreak) begin
            trap.taken = true;
            trap.cause = cause_breakpoint;
            trap.tval  = decoded_instruction_in.pc;
        end else if (misaligned_load) begin
            trap.taken = true;
            trap.cause = cause_misaligned_load;
            trap.tval  = mem_addr;
        end else if (misaligned_store) begin
            trap.taken = true;
            trap.cause = cause_misaligned_store;
            trap.tval  = mem_addr;
        end
    end


    next_pc_result = compute_next_pc(
        cast_to_ext_operand(rd1),
        cast_to_ext_operand(rd2),
        decoded_instruction_in.imm,
        decoded_instruction_in.pc,
        fetched_instruction_in.pc,
        decoded_instruction_in.instruction_opcode,
        decoded_instruction_in.f3);

    next_pc_comb  = next_pc_result.next_pc;
    mispredict    = next_pc_result.mispredict;

    if (trap.taken) begin
        next_pc_comb = {mtvec_r[`word_size-1:2], 2'b00};
        mispredict   = ({mtvec_r[`word_size-1:2], 2'b00} != fetched_instruction_in.pc);
    end else if (decoded_instruction_in.is_instruction_valid && is_mret) begin
        next_pc_comb = mepc_r;
        mispredict   = (mepc_r != fetched_instruction_in.pc);
    end

    pc_control_out = {($bits(pc_control_t)){1'b0}};
    pc_control_out.branch_redirect_needed = false;

    if (decoded_instruction_in.is_instruction_valid && mispredict) begin
        pc_control_out.branch_redirect_needed = true;
        pc_control_out.branch_target_pc = next_pc_comb;
    end

end

// Branch predictor training
always_ff @(posedge clk) begin
    btb_update_out <= {($bits(btb_update_t)){1'b0}};
    if (!reset
        && decoded_instruction_in.is_instruction_valid
        && execute_control_signal_in.advance
        && !trap.taken
        && ((decoded_instruction_in.instruction_opcode == q_branch)
         || (decoded_instruction_in.instruction_opcode == q_jal)
         || (decoded_instruction_in.instruction_opcode == q_jalr))) begin
        btb_update_out.valid  <= true;
        btb_update_out.pc     <= decoded_instruction_in.pc;
        btb_update_out.target <= next_pc_comb;
        btb_update_out.taken  <= (next_pc_comb != (decoded_instruction_in.pc + 4));
    end
end

`ifdef RVFI
always_ff @(posedge clk) begin
    if (reset) begin
        rvfi_ex_valid <= 1'b0;
    end else if (memory_control_signal_in.advance) begin
        rvfi_ex_valid     <= decoded_instruction_in.is_instruction_valid
                           & execute_control_signal_in.advance;
        rvfi_ex_insn      <= decoded_instruction_in.instruction;
        rvfi_ex_pc        <= decoded_instruction_in.pc;
        rvfi_ex_next_pc   <= next_pc_comb;
        rvfi_ex_rs1_addr  <= decoded_instruction_in.rs1;
        rvfi_ex_rs2_addr  <= decoded_instruction_in.rs2;
        rvfi_ex_rs1_rdata <= bypassed_rd1_comb;
        rvfi_ex_rs2_rdata <= bypassed_rd2_comb;
        rvfi_ex_trap      <= trap.taken;
    end
end
`endif

always_ff @(posedge clk) begin
    if (reset) begin
        executed_instruction_out.is_instruction_valid <= false;
        mstatus_r <= `word_size'd0;
        mcycle_r   <= 64'd0;
        minstret_r <= 64'd0;
        mtvec_r   <= `word_size'd0;
        mepc_r    <= `word_size'd0;
        mcause_r  <= `word_size'd0;
        mtval_r   <= `word_size'd0;
    end else begin
        mcycle_r <= mcycle_r + 64'd1;
        if (decoded_instruction_in.is_instruction_valid
            && execute_control_signal_in.advance && !trap.taken)
            minstret_r <= minstret_r + 64'd1;

        if (decoded_instruction_in.is_instruction_valid && execute_control_signal_in.advance) begin
            if (trap.taken) begin
                mepc_r   <= trap.epc;
                mcause_r <= trap.cause;
                mtval_r  <= trap.tval;
                mstatus_r[MSTATUS_MPIE] <= mstatus_r[MSTATUS_MIE];
                mstatus_r[MSTATUS_MIE]  <= 1'b0;
            end else if (is_mret) begin
                mstatus_r[MSTATUS_MIE]  <= mstatus_r[MSTATUS_MPIE];
                mstatus_r[MSTATUS_MPIE] <= 1'b1;
            end else if (csr_wen) begin
                case (csr_addr)
                    csr_mstatus: mstatus_r <= csr_write;
                    csr_mtvec:   mtvec_r   <= csr_write;
                    csr_mepc:    mepc_r    <= csr_write;
                    csr_mcause:  mcause_r  <= csr_write;
                    csr_mtval:   mtval_r   <= csr_write;
                    default:     ;                     // writes to unimplemented CSRs are dropped
                endcase
            end
        end

        if (decoded_instruction_in.is_instruction_valid && execute_control_signal_in.advance && !trap.taken) begin
            executed_instruction_out.is_instruction_valid <= true;
            executed_instruction_out.rd1 <= bypassed_rd1_comb;
            executed_instruction_out.rd2 <= bypassed_rd2_comb;
            executed_instruction_out.rs1 <= decoded_instruction_in.rs1;
            executed_instruction_out.rs2 <= decoded_instruction_in.rs2;
            executed_instruction_out.writeback_instruction.wbs <= decoded_instruction_in.writeback_select;
            executed_instruction_out.writeback_instruction.is_writeback_valid <= decoded_instruction_in.is_writeback_valid;
            executed_instruction_out.writeback_instruction.wbd <= execute_result_comb[`word_size-1:0];
            executed_instruction_out.writeback_instruction.is_instruction_valid <= decoded_instruction_in.is_instruction_valid;
            executed_instruction_out.f3 <= decoded_instruction_in.f3;
            executed_instruction_out.instruction_opcode <= decoded_instruction_in.instruction_opcode;

            if (is_csr)
                executed_instruction_out.writeback_instruction.wbd <= csr_read;
        end else if (memory_control_signal_in.advance) begin
            executed_instruction_out <= {($bits(executed_instruction_t)){1'b0}};
            executed_instruction_out.is_instruction_valid <= false;
        end
    end
end
endmodule

// -- MEMORY --
// Issues data memory requests for loads and stores. For loads, the response is consumed
// in the writeback stage. Passes the executed instruction (with write-back info and f3/op_q
// for load formatting) to writeback.
module memory(
    input logic                                 clk,
    input logic                                 reset,

    input stage_control_signal_t                memory_control_signal_in,
    input stage_control_signal_t                writeback_control_signal_in,

    input register_file_bypass_t                register_file_bypass_in,
    input writeback_instruction_t               writeback_instruction_in,

    output memory_io_req                        data_memory_request,
    input memory_io_rsp                         data_memory_response,

    output riscv::word                          data_memory_addr,
    input executed_instruction_t                executed_instruction_in,
    output memory_instruction_t                 memory_instruction_out,
    output logic                                retired,

    output logic                                data_memory_wait,
    output logic                                data_memory_issue_blocked
);

assign data_memory_addr = executed_instruction_in.writeback_instruction.wbd[`word_address_size - 1:0];

assign retired = memory_control_signal_in.advance & executed_instruction_in.is_instruction_valid;

import riscv::*;

logic access_outstanding;   // accepted, response not yet returned

wire access_busy = access_outstanding & ~data_memory_response.valid;

wire is_memory_op = executed_instruction_in.is_instruction_valid
                  && (executed_instruction_in.instruction_opcode == q_store
                   || executed_instruction_in.instruction_opcode == q_load
                   || executed_instruction_in.instruction_opcode == q_amo);

wire want_issue = is_memory_op & ~access_busy;

wire issue_accepted = data_memory_request.valid;

assign data_memory_wait          = access_busy;
assign data_memory_issue_blocked = want_issue & ~data_memory_response.ready;

always_ff @(posedge clk) begin
    if (reset)
        access_outstanding <= 1'b0;
    else if (issue_accepted)
        access_outstanding <= 1'b1;
    else if (data_memory_response.valid)
        access_outstanding <= 1'b0;
end

`ifndef SYNTHESIS
always @(posedge clk) begin
    if (!reset && memory_control_signal_in.advance && is_memory_op && !issue_accepted)
        $error("%m: memory instruction left EX/MEM without issuing (addr %08x)",
               executed_instruction_in.writeback_instruction.wbd);
end
`endif

// build data memory request
always_comb begin
    word rd2;
    word rd1;

    rd1 = executed_instruction_in.rd1;
    rd2 = executed_instruction_in.rd2;
    data_memory_request = memory_io_no_req;

    if (want_issue && data_memory_response.ready) begin
        data_memory_request.user_tag = 0;

        if (executed_instruction_in.instruction_opcode == q_store) begin
            data_memory_request.addr = executed_instruction_in.writeback_instruction.wbd[`word_address_size - 1:0];
            data_memory_request.valid = true;
            data_memory_request.do_write = shuffle_store_mask(memory_mask(
                cast_to_memory_op(executed_instruction_in.f3)), executed_instruction_in.writeback_instruction.wbd[`word_size - 1:0]);
            data_memory_request.data = shuffle_store_data(rd2, executed_instruction_in.writeback_instruction.wbd[`word_size - 1:0]);
        end
        else if (executed_instruction_in.instruction_opcode == q_load) begin
            data_memory_request.addr = executed_instruction_in.writeback_instruction.wbd[`word_address_size - 1:0];
            data_memory_request.valid = true;
            data_memory_request.do_read = shuffle_store_mask(memory_mask(
                cast_to_memory_op(executed_instruction_in.f3)), executed_instruction_in.writeback_instruction.wbd[`word_size - 1:0]);
        end
        /*        else if (executed_instruction_in.op_q == q_amo) begin
            data_mem_req.addr = rd1;
            data_mem_req.data = rd2;
            data_mem_req.valid = true;
            if (executed_instruction_in.f3 == f3_amo_d) begin
                data_mem_req.do_write = {(`word_size_bytes){1'b1}};
                data_mem_req.do_read = {(`word_size_bytes){1'b1}};
            end
        end
        */
    end
end

always_ff @(posedge clk) begin
    if (memory_control_signal_in.advance) begin
        memory_instruction_out <= {($bits(memory_instruction_t)){1'b0}};
        if (executed_instruction_in.is_instruction_valid) begin
            memory_instruction_out.writeback_instruction <= executed_instruction_in.writeback_instruction;
            memory_instruction_out.f3 <= executed_instruction_in.f3;
            memory_instruction_out.instruction_opcode <= executed_instruction_in.instruction_opcode;
            memory_instruction_out.is_instruction_valid <= executed_instruction_in.is_instruction_valid;
        end
    end else if (writeback_control_signal_in.advance)
        memory_instruction_out <= {($bits(memory_instruction_t)){1'b0}};
end
endmodule

// -- WRITEBACK --
// Selects the final result to write to the register file
module writeback(
    input stage_control_signal_t                writeback_control_signal_in,
    input memory_io_rsp                         data_memory_response,
    input memory_instruction_t                  memory_instruction_in,
    output writeback_instruction_t              writeback_instruction_out
);

import riscv::*;

always_comb begin
    writeback_instruction_out = {($bits(writeback_instruction_t)){1'b0}};

    if (writeback_control_signal_in.advance && memory_instruction_in.is_instruction_valid) begin
        writeback_instruction_out = memory_instruction_in.writeback_instruction;

        if (memory_instruction_in.instruction_opcode == q_load || memory_instruction_in.instruction_opcode == q_amo) begin
            writeback_instruction_out.wbd = subset_load_data(
                shuffle_load_data(data_memory_response.data, memory_instruction_in.writeback_instruction.wbd[`word_size - 1:0]),
                cast_to_memory_op(memory_instruction_in.f3));
            writeback_instruction_out.is_instruction_valid = data_memory_response.valid & memory_instruction_in.is_instruction_valid;
        end
    end
end
endmodule

// -- Control --
// Generates advance/flush per stage and set-PC for fetch
// Handles hazards
module control(
    input logic                                 stall,
    input logic                                 instruction_memory_wait,
    input logic                                 data_memory_wait,
    input logic                                 data_memory_issue_blocked,
    input logic                                 div_wait,

    input pc_control_t                          pc_control_in,
    input decoded_instruction_t                 decoded_instruction_in,
    input executed_instruction_t                executed_instruction_in,

    output stage_control_signal_t               fetch_control_signal_out,
    output stage_control_signal_t               decode_control_signal_out,
    output stage_control_signal_t               execute_control_signal_out,
    output stage_control_signal_t               memory_control_signal_out,
    output stage_control_signal_t               writeback_control_signal_out,

    output branch_pc_redirect_request_t         branch_pc_redirect_request_out
);

import riscv::*;

// Two hazard cases are handled:
// - Load-use hazard
// - Branch / Jump mispredict
//
// WAR & WAW hazards cannot possibly occur (RAW is handled by forwarding)
always_comb begin
    fetch_control_signal_out.advance = true;
    fetch_control_signal_out.flush = false;
    decode_control_signal_out.advance = true;
    decode_control_signal_out.flush = false;
    execute_control_signal_out.advance = true;
    execute_control_signal_out.flush = false;
    memory_control_signal_out.advance = true;
    memory_control_signal_out.flush = false;
    writeback_control_signal_out.advance = true;
    writeback_control_signal_out.flush = false;
    branch_pc_redirect_request_out.is_pc_valid = false;
    branch_pc_redirect_request_out.pc = '0;

    // Load-use hazard has highest priority, check it first
    if (is_load_use_hazard(executed_instruction_in, decoded_instruction_in)) begin
        fetch_control_signal_out.advance  = false;
        decode_control_signal_out.advance = false;
        execute_control_signal_out.advance = false;
    end else begin
        // Only check Branch / Jump mispredict when there is no load-use stall active
        if (pc_control_in.branch_redirect_needed) begin
            branch_pc_redirect_request_out.is_pc_valid = true;
            branch_pc_redirect_request_out.pc = pc_control_in.branch_target_pc;
            decode_control_signal_out.flush = true;
        end
    end

    // Front-end freeze
    if (stall || instruction_memory_wait || data_memory_issue_blocked || data_memory_wait || div_wait) begin
        fetch_control_signal_out.advance = false;
        decode_control_signal_out.advance = false;
        execute_control_signal_out.advance = false;
        decode_control_signal_out.flush = false;
        branch_pc_redirect_request_out.is_pc_valid = false;
    end

    // Back-end freeze
    if (data_memory_issue_blocked || data_memory_wait)
        memory_control_signal_out.advance = false;
    if (data_memory_wait)
        writeback_control_signal_out.advance = false;
end
endmodule

// -- Core --
// Top-level 5-stage RISC-V pipeline (Fetch -> Decode -> Execute -> Memory -> Writeback)
module core #(
    parameter btb_enable  = 1,
    parameter btb_entries = 8
) (
    input logic                                 clk,
    input logic                                 reset,

    input logic                                 stall,
    input logic                                 clear_regs,     // (hold >=32 cycles)

    output logic                                retired,
    input logic                                 [`word_address_size-1:0] reset_pc,

    output memory_io_req                        inst_mem_req,
    input memory_io_rsp                         inst_mem_rsp,
    output riscv::word                          inst_mem_addr,

    output memory_io_req                        data_mem_req,
    input memory_io_rsp                         data_mem_rsp,
    output riscv::word                          data_mem_addr
`ifdef RVFI
    ,output logic                               rvfi_valid
    ,output logic                               [63:0] rvfi_order
    ,output logic                               [31:0] rvfi_insn
    ,output logic                               rvfi_trap
    ,output logic                               rvfi_halt
    ,output logic                               rvfi_intr
    ,output logic                               [1:0]  rvfi_mode
    ,output logic                               [1:0]  rvfi_ixl
    ,output logic                               [4:0]  rvfi_rs1_addr
    ,output logic                               [4:0]  rvfi_rs2_addr
    ,output logic                               [31:0] rvfi_rs1_rdata
    ,output logic                               [31:0] rvfi_rs2_rdata
    ,output logic                               [4:0]  rvfi_rd_addr
    ,output logic                               [31:0] rvfi_rd_wdata
    ,output logic                               [31:0] rvfi_pc_rdata
    ,output logic                               [31:0] rvfi_pc_wdata
    ,output logic                               [31:0] rvfi_mem_addr
    ,output logic                               [3:0]  rvfi_mem_rmask
    ,output logic                               [3:0]  rvfi_mem_wmask
    ,output logic                               [31:0] rvfi_mem_rdata
    ,output logic                               [31:0] rvfi_mem_wdata
`endif
);

import riscv::*;

/* verilator lint_off UNOPTFLAT */
stage_control_signal_t fetch_control_signal, decode_control_signal, execute_control_signal, memory_control_signal, writeback_control_signal;
/* verilator lint_on UNOPTFLAT */
branch_pc_redirect_request_t branch_pc_redirect_request;

logic instruction_memory_wait, data_memory_wait, data_memory_issue_blocked;
logic div_wait;

fetched_instruction_t fetched_instruction;

btb_update_t btb_update;

fetch #(
    .btb_enable(btb_enable),
    .btb_entries(btb_entries)
) fetch_m(
    .clk(clk),
    .reset(reset),
    .reset_pc(reset_pc),
    .fetch_control_signal_in(fetch_control_signal),
    .branch_pc_redirect_request_in(branch_pc_redirect_request),
    .btb_update_in(btb_update),
    .instruction_memory_request(inst_mem_req),
    .instruction_memory_response(inst_mem_rsp),
    .instruction_memory_addr(inst_mem_addr),
    .instruction_memory_wait(instruction_memory_wait),
    .fetched_instruction_out(fetched_instruction)
);

register_file_bypass_t register_file_bypass;
decoded_instruction_t decoded_instruction;
writeback_instruction_t writeback_instruction;

decode_and_writeback decode_and_writeback_m(
    .clk(clk),
    .reset(reset),
    .clear_regs(clear_regs),
    .decode_control_signal_in(decode_control_signal),
    .execute_control_signal_in(execute_control_signal),
    .writeback_control_signal_in(writeback_control_signal),
    .register_file_bypass_out(register_file_bypass),
    .fetched_instruction_in(fetched_instruction),
    .decoded_instruction_out(decoded_instruction),
    .writeback_instruction_in(writeback_instruction)
);

executed_instruction_t executed_instruction;
pc_control_t pc_control;

`ifdef RVFI
logic        rvfi_ex_valid, rvfi_ex_trap;
logic [31:0] rvfi_ex_insn, rvfi_ex_pc, rvfi_ex_next_pc;
logic [4:0]  rvfi_ex_rs1_addr, rvfi_ex_rs2_addr;
logic [31:0] rvfi_ex_rs1_rdata, rvfi_ex_rs2_rdata;
`endif

execute execute_m(
    .clk(clk),
    .reset(reset),
    .reset_pc(reset_pc),
    .execute_control_signal_in(execute_control_signal),
    .memory_control_signal_in(memory_control_signal),
    .fetched_instruction_in(fetched_instruction),
    .register_file_bypass_in(register_file_bypass),
    .executed_instruction_in(executed_instruction),
    .writeback_instruction_in(writeback_instruction),
    .decoded_instruction_in(decoded_instruction),
    .executed_instruction_out(executed_instruction),
    .pc_control_out(pc_control),
    .btb_update_out(btb_update),
    .div_wait(div_wait)
`ifdef RVFI
    ,.rvfi_ex_valid(rvfi_ex_valid)
    ,.rvfi_ex_insn(rvfi_ex_insn)
    ,.rvfi_ex_pc(rvfi_ex_pc)
    ,.rvfi_ex_next_pc(rvfi_ex_next_pc)
    ,.rvfi_ex_rs1_addr(rvfi_ex_rs1_addr)
    ,.rvfi_ex_rs2_addr(rvfi_ex_rs2_addr)
    ,.rvfi_ex_rs1_rdata(rvfi_ex_rs1_rdata)
    ,.rvfi_ex_rs2_rdata(rvfi_ex_rs2_rdata)
    ,.rvfi_ex_trap(rvfi_ex_trap)
`endif
);

memory_instruction_t memory_instruction;

memory memory_m(
    .clk(clk),
    .reset(reset),
    .memory_control_signal_in(memory_control_signal),
    .writeback_control_signal_in(writeback_control_signal),
    .register_file_bypass_in(register_file_bypass),
    .writeback_instruction_in(writeback_instruction),
    .data_memory_request(data_mem_req),
    .data_memory_response(data_mem_rsp),
    .data_memory_addr(data_mem_addr),
    .executed_instruction_in(executed_instruction),
    .memory_instruction_out(memory_instruction),
    .retired(retired),
    .data_memory_wait(data_memory_wait),
    .data_memory_issue_blocked(data_memory_issue_blocked)
);

writeback writeback_m(
    .writeback_control_signal_in(writeback_control_signal),
    .data_memory_response(data_mem_rsp),
    .memory_instruction_in(memory_instruction),
    .writeback_instruction_out(writeback_instruction)
);

`ifdef RVFI
logic        rvfi_wb_valid, rvfi_wb_trap;
logic [31:0] rvfi_wb_insn, rvfi_wb_pc, rvfi_wb_next_pc;
logic [4:0]  rvfi_wb_rs1_addr, rvfi_wb_rs2_addr;
logic [31:0] rvfi_wb_rs1_rdata, rvfi_wb_rs2_rdata;
logic [31:0] rvfi_wb_mem_addr, rvfi_wb_mem_wdata;
logic [3:0]  rvfi_wb_mem_rmask, rvfi_wb_mem_wmask;
logic [63:0] rvfi_order_r;

always_ff @(posedge clk) begin
    if (reset) begin
        rvfi_wb_valid <= 1'b0;
        rvfi_order_r  <= 64'd0;
    end else begin
        if (memory_control_signal.advance) begin
            rvfi_wb_valid      <= rvfi_ex_valid;
            rvfi_wb_trap       <= rvfi_ex_trap;
            rvfi_wb_insn       <= rvfi_ex_insn;
            rvfi_wb_pc         <= rvfi_ex_pc;
            rvfi_wb_next_pc    <= rvfi_ex_next_pc;
            rvfi_wb_rs1_addr   <= rvfi_ex_rs1_addr;
            rvfi_wb_rs2_addr   <= rvfi_ex_rs2_addr;
            rvfi_wb_rs1_rdata  <= rvfi_ex_rs1_rdata;
            rvfi_wb_rs2_rdata  <= rvfi_ex_rs2_rdata;
            rvfi_wb_mem_addr   <= {data_mem_req.addr[31:2], 2'b00};
            rvfi_wb_mem_rmask  <= data_mem_req.valid ? data_mem_req.do_read  : 4'd0;
            rvfi_wb_mem_wmask  <= data_mem_req.valid ? data_mem_req.do_write : 4'd0;
            rvfi_wb_mem_wdata  <= data_mem_req.data;
        end else if (writeback_control_signal.advance)
            rvfi_wb_valid <= 1'b0;

        if (rvfi_valid)
            rvfi_order_r <= rvfi_order_r + 64'd1;
    end
end

assign rvfi_valid      = rvfi_wb_valid & writeback_control_signal.advance;
assign rvfi_order      = rvfi_order_r;
assign rvfi_insn       = rvfi_wb_insn;
assign rvfi_trap       = rvfi_wb_trap;
assign rvfi_halt       = 1'b0;
assign rvfi_intr       = 1'b0;
assign rvfi_mode       = 2'd3;
assign rvfi_ixl        = 2'd1;
assign rvfi_rs1_addr   = rvfi_wb_rs1_addr;
assign rvfi_rs2_addr   = rvfi_wb_rs2_addr;
assign rvfi_rs1_rdata  = (rvfi_wb_rs1_addr == 5'd0) ? 32'd0 : rvfi_wb_rs1_rdata;
assign rvfi_rs2_rdata  = (rvfi_wb_rs2_addr == 5'd0) ? 32'd0 : rvfi_wb_rs2_rdata;
assign rvfi_rd_addr    = (writeback_instruction.is_instruction_valid
                          && writeback_instruction.is_writeback_valid)
                         ? writeback_instruction.wbs : 5'd0;
assign rvfi_rd_wdata   = (rvfi_rd_addr == 5'd0) ? 32'd0 : writeback_instruction.wbd;
assign rvfi_pc_rdata   = rvfi_wb_pc;
assign rvfi_pc_wdata   = rvfi_wb_next_pc;
assign rvfi_mem_addr   = rvfi_wb_mem_addr;
assign rvfi_mem_rmask  = rvfi_wb_mem_rmask;
assign rvfi_mem_wmask  = rvfi_wb_mem_wmask;
assign rvfi_mem_rdata  = data_mem_rsp.data;
assign rvfi_mem_wdata  = rvfi_wb_mem_wdata;
`endif

control control_m(
    .stall(stall),
    .instruction_memory_wait(instruction_memory_wait),
    .data_memory_wait(data_memory_wait),
    .data_memory_issue_blocked(data_memory_issue_blocked),
    .div_wait(div_wait),
    .pc_control_in(pc_control),
    .decoded_instruction_in(decoded_instruction),
    .executed_instruction_in(executed_instruction),
    .fetch_control_signal_out(fetch_control_signal),
    .decode_control_signal_out(decode_control_signal),
    .execute_control_signal_out(execute_control_signal),
    .memory_control_signal_out(memory_control_signal),
    .writeback_control_signal_out(writeback_control_signal),
    .branch_pc_redirect_request_out(branch_pc_redirect_request)
);

`ifndef SYNTHESIS
// memory_io protocol checks.
logic chk_data_outstanding;
logic chk_inst_outstanding;

wire chk_data_accept = data_mem_req.valid & data_mem_rsp.ready;
wire chk_inst_accept = inst_mem_req.valid & inst_mem_rsp.ready;

// Icarus warns on every $error inside an always_ff because it cannot be synthesised (is fine)
always @(posedge clk) begin
    if (reset) begin
        chk_data_outstanding <= chk_data_accept;
        chk_inst_outstanding <= chk_inst_accept;
    end else begin
        if (chk_data_accept && chk_data_outstanding && !data_mem_rsp.valid)
            $error("%m: second data request issued while one is still in flight (addr %08x)", data_mem_req.addr);
        if (chk_inst_accept && chk_inst_outstanding && !inst_mem_rsp.valid)
            $error("%m: second instruction fetch issued while one is still in flight (addr %08x)", inst_mem_req.addr);

        if (data_mem_rsp.valid && !chk_data_outstanding)
            $error("%m: data response with no request outstanding (addr %08x)", data_mem_rsp.addr);
        if (inst_mem_rsp.valid && !chk_inst_outstanding)
            $error("%m: instruction response with no request outstanding (addr %08x)", inst_mem_rsp.addr);

        chk_data_outstanding <= chk_data_accept | (chk_data_outstanding & ~data_mem_rsp.valid);
        chk_inst_outstanding <= chk_inst_accept | (chk_inst_outstanding & ~inst_mem_rsp.valid);
    end

    if (!reset && writeback_control_signal.advance
        && memory_instruction.is_instruction_valid
        && memory_instruction.instruction_opcode == q_load
        && !data_mem_rsp.valid)
        $error("%m: load retiring from MEM/WB with no data response, result dropped");
end
`endif

endmodule

`endif
