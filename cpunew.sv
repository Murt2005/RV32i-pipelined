`ifndef __cpunew_sv
`define __cpunew_sv

`include "riscv.sv"
`include "regfile_ebr.sv"

// Request to set a new fetch PC (on branch/jump or mispredict)
typedef struct packed {
    bool is_pc_valid;
    riscv::word pc;
} branch_pc_redirect_request_t;

// Placeholder for fetch response upon redirect (unused) 
typedef struct packed {
    bool _unused_;
} branch_pc_redirect_response_t;

// Stage Control Signals
//  - advance: allow instruction to move to next stage
//  - flush: invalidate the stages output
typedef struct packed {
    bool advance;
    bool flush;
} stage_control_signal_t;

// Fetch stage output to pass to decode stage
typedef struct packed {
    bool is_instruction_valid;
    riscv::instr32 instruction;
    riscv::word pc;
} fetched_instruction_t;

// Decode stage output to pass to execute stage
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
    riscv::word pc;
} decoded_instruction_t;

// Writeback payload: what to write if valid to which register (used across execute/memory/writeback)
typedef struct packed {
    bool is_instruction_valid;
    bool is_writeback_valid;
    riscv::tag wbs;
    riscv::word wbd;
} writeback_instruction_t;

// Bypass info struct from decode/writeback containing latest writeback for forwarding
typedef struct packed {
    bool bypass_is_valid;
    riscv::word rd;
    riscv::tag rs;
} register_file_bypass_t;

// Execute stage output to pass to memory stage
typedef struct packed {
    bool is_instruction_valid;
    riscv::word rd2;
    riscv::funct3 f3;
    riscv::opcode_q instruction_opcode;
    writeback_instruction_t writeback_instruction;
} executed_instruction_t;

// PC correction struct from execute if branch misprediction or straight up wrong PC
typedef struct packed {
    bool branch_redirect_needed;
    riscv::word branch_target_pc; // where fetch should go over branch

    bool stale_instruction_in_execute;
    riscv::word expected_execute_pc; 
} pc_control_t;

// Memory stage output, passes write-back info and load result (later) to writeback
typedef struct packed {
    bool is_instruction_valid;
    riscv::funct3 f3;
    riscv::opcode_q instruction_opcode;
    writeback_instruction_t writeback_instruction;
} memory_instruction_t;


// ---------------------------------------------------------------------------
// STAGE 1: FETCH
// Issues instruction memory requests and presents one instruction per cycle to decode.
// Handles: PC increment, stream clear (flush in-flight requests), and external set-PC
// (branch/jump target or mispredict correction from control).
// ---------------------------------------------------------------------------
module fetch(
    input logic                                 clk,
    input logic                                 reset,
    input logic                                 [`word_address_size-1:0] reset_pc,

    input stage_control_signal_t                fetch_control_signal_in,

    input branch_pc_redirect_request_t          branch_pc_redirect_request_in,
    output branch_pc_redirect_response_t        branch_pc_redirect_response_out,

    output memory_io_req                        instruction_memory_request,
    input memory_io_rsp                         instruction_memory_response,

    output fetched_instruction_t                fetched_instruction_out
);

import riscv::*;

word fetch_pc;
bool clear_fetch_stream;                    
word clear_to_this_pc;
instr32 latched_instruction_read;
bool latched_instruction_valid;
word latched_instruction_pc;

// Combinational: instruction memory request and fetch output
always @(*) begin
    instruction_memory_request = memory_io_no_req;
    instruction_memory_request.addr = fetch_pc;
    instruction_memory_request.do_read[3:0] = 4'b1111;
    instruction_memory_request.valid = instruction_memory_response.ready && fetch_control_signal_in.advance;
    instruction_memory_request.user_tag = 0;

    // Default, output whatever we have latched 
    fetched_instruction_out.pc = latched_instruction_pc;
    fetched_instruction_out.is_instruction_valid = latched_instruction_valid;
    fetched_instruction_out.instruction = latched_instruction_read;

    // Bypass path, if we get a valid response this cycle and can advance forward instruction to decode
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

// Sequential: update PC, latches, and clear state
always_ff @(posedge clk) begin
    if (reset) begin
        fetch_pc <= reset_pc;
        latched_instruction_valid <= false;
        clear_fetch_stream <= false;
        clear_to_this_pc <= 0;
    end else begin
        // if we receive a valid response from instruction memory, either discard or latch it if we can advance
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

        // if we issued a request this cycle and it was accepted, update PC += 4
        if (instruction_memory_request.valid) begin
            fetch_pc <= fetch_pc + 4;
        end

        // redirect fetch PC if needed
        if (branch_pc_redirect_request_in.is_pc_valid) begin
            fetch_pc <= branch_pc_redirect_request_in.pc;
            latched_instruction_valid <= false;
            clear_fetch_stream <= true;
            clear_to_this_pc <= branch_pc_redirect_request_in.pc;
        end else if (!fetch_control_signal_in.advance) begin
            // if decode is stalled, realign PC to instruction after latched instruction
            // so we have correct next instruction after the stall clears.
            fetch_pc <= latched_instruction_pc + 4;
            clear_fetch_stream <= true;
            clear_to_this_pc <= latched_instruction_pc + 4;
        end
    end
end
endmodule

// ---------------------------------------------------------------------------
// STAGE 2: DECODE (and register file write-back)
// Holds the register file, decodes the fetched instruction, and writes back results
// from the writeback stage. Produces decoded_instruction for execute and bypass info
// so later stages can forward the current write-back to resolve RAW hazards.
// ---------------------------------------------------------------------------
module decode_and_writeback(
    input logic clk,
    input logic reset,

    input stage_control_signal_t decode_control_signal_in,
    input stage_control_signal_t execute_control_signal_in,
    input stage_control_signal_t writeback_control_signal_in,

    output register_file_bypass_t register_file_bypass_out,

    input fetched_instruction_t fetched_instruction_in,
    output decoded_instruction_t decoded_instruction_out,

    input writeback_instruction_t writeback_instruction_in
);

import riscv::*;

typedef struct packed {
    bool is_instruction_valid;
    riscv::tag rs1;
    riscv::tag rs2;
    riscv::word imm;
    riscv::tag writeback_select;
    bool is_writeback_valid;
    riscv::funct3 f3;
    riscv::funct7 f7;
    riscv::opcode_q instruction_opcode;
    riscv::word pc;
} decoded_fields_t;

decoded_fields_t id0_fields; // field decode + regfile address launch
decoded_fields_t id1_fields; // aligns with EBR regfile read data

logic [31:0] rf_rdata1;
logic [31:0] rf_rdata2;

// Bypass state (for execute stage forwarding)
word register_file_bypass_rd;
tag register_file_bypass_rs;
bool register_file_bypass_valid;

// Bypass is driven combinationally from the same values we write to the reg file (see write-back block below).
always_comb begin
    register_file_bypass_out.bypass_is_valid = register_file_bypass_valid;
    register_file_bypass_out.rd = register_file_bypass_rd;
    register_file_bypass_out.rs = register_file_bypass_rs;
end

regfile_2r1w_ebr regfile_m (
    .clk(clk),
    .raddr1(id0_fields.rs1),
    .raddr2(id0_fields.rs2),
    .rdata1(rf_rdata1),
    .rdata2(rf_rdata2),
    .wen(writeback_control_signal_in.advance
         && writeback_instruction_in.is_instruction_valid
         && writeback_instruction_in.is_writeback_valid),
    .waddr(writeback_instruction_in.wbs),
    .wdata(writeback_instruction_in.wbd)
);

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
        register_file_bypass_valid <= false;  // default; set true only in writeback block below

    // ID0/ID1 pipeline (fields only). Regfile data comes from EBR one cycle later.
    if (reset || decode_control_signal_in.flush) begin
        id0_fields <= {($bits(decoded_fields_t)){1'b0}};
        id0_fields.is_instruction_valid <= false;
        id1_fields <= {($bits(decoded_fields_t)){1'b0}};
        id1_fields.is_instruction_valid <= false;
    end else if (decode_control_signal_in.advance) begin
        // Shift fields to align with EBR output latency
        id1_fields <= id0_fields;

        // Capture new decoded fields (or bubble)
        if (fetched_instruction_in.is_instruction_valid) begin
            id0_fields.is_instruction_valid <= true;
            id0_fields.rs1 <= rs1;
            id0_fields.rs2 <= rs2;
            id0_fields.writeback_select <= decode_rd(fetched_instruction_in.instruction);
            id0_fields.f3 <= decode_funct3(fetched_instruction_in.instruction);
            id0_fields.instruction_opcode <= op_q;
            id0_fields.imm <= decode_imm(fetched_instruction_in.instruction, format);
            id0_fields.is_writeback_valid <= decode_writeback(op_q);
            id0_fields.f7 <= decode_funct7(fetched_instruction_in.instruction, format);
            id0_fields.pc <= fetched_instruction_in.pc;
        end else begin
            id0_fields <= {($bits(decoded_fields_t)){1'b0}};
            id0_fields.is_instruction_valid <= false;
        end
    end

    // Write-back: commit result from writeback stage into register file and set bypass
    if (!reset
        && writeback_control_signal_in.advance
        && writeback_instruction_in.is_instruction_valid
        && writeback_instruction_in.is_writeback_valid) begin
        register_file_bypass_rs <= writeback_instruction_in.wbs;
        register_file_bypass_rd <= writeback_instruction_in.wbd;
        register_file_bypass_valid <= true;
    end
end

// ID1 output assembly (combinational): align decoded fields with EBR regfile data.
// Apply WB->ID bypass in this stage so that an instruction can see a WB write
// occurring during its regfile-read cycle.
always_comb begin
    decoded_instruction_out = {($bits(decoded_instruction_t)){1'b0}};
    decoded_instruction_out.is_instruction_valid = id1_fields.is_instruction_valid;
    decoded_instruction_out.rs1 = id1_fields.rs1;
    decoded_instruction_out.rs2 = id1_fields.rs2;
    decoded_instruction_out.imm = id1_fields.imm;
    decoded_instruction_out.writeback_select = id1_fields.writeback_select;
    decoded_instruction_out.is_writeback_valid = id1_fields.is_writeback_valid;
    decoded_instruction_out.f3 = id1_fields.f3;
    decoded_instruction_out.f7 = id1_fields.f7;
    decoded_instruction_out.instruction_opcode = id1_fields.instruction_opcode;
    decoded_instruction_out.pc = id1_fields.pc;

    decoded_instruction_out.rd1 = rf_rdata1;
    decoded_instruction_out.rd2 = rf_rdata2;

    if (writeback_control_signal_in.advance
        && writeback_instruction_in.is_instruction_valid
        && writeback_instruction_in.is_writeback_valid) begin
        if (id1_fields.rs1 == writeback_instruction_in.wbs)
            decoded_instruction_out.rd1 = writeback_instruction_in.wbd;
        if (id1_fields.rs2 == writeback_instruction_in.wbs)
            decoded_instruction_out.rd2 = writeback_instruction_in.wbd;
    end
end
endmodule

// ---------------------------------------------------------------------------
// STAGE 3: EXECUTE
// Performs ALU operation, computes next PC (PC+4 or branch/jump target), and detects
// branch mispredicts. Outputs executed_instruction (with write-back info) to memory
// and pc_control for redirecting fetch. Uses bypass from decode/writeback and later
// stages to resolve RAW hazards.
// ---------------------------------------------------------------------------
module execute(
    input logic clk,
    input logic reset,
    input riscv::word reset_pc,

    input stage_control_signal_t execute_control_signal_in,
    input stage_control_signal_t memory_control_signal_in,

    input fetched_instruction_t fetched_instruction_in,

    input register_file_bypass_t register_file_bypass_in,
    input executed_instruction_t executed_instruction_in,
    input writeback_instruction_t writeback_instruction_in,

    input decoded_instruction_t decoded_instruction_in,
    output executed_instruction_t executed_instruction_out,

    output pc_control_t pc_control_out
);

import riscv::*;

// Internal state
ext_operand execute_result_comb;
word next_pc_comb;
word bypassed_rd1_comb;
word bypassed_rd2_comb;

// Combinational: operands, ALU, next-PC, and mispredict detection
always_comb begin
    word rd1;
    word rd2;

    // ---------------------------------------------------------------
    // Bypass Logic
    // Priority (lowest to highest):
    //   1. Register file value read at decode (already in rd1/rd2)
    //   2. register_file_bypass: result written to reg file the same cycle
    //      decode read it (WB concurrent with ID)
    //   3. writeback_instruction_in: MEM/WB result (2 instructions ago),
    //      valid for ALL instruction types including loads
    //   4. executed_instruction_in: EX/MEM result (1 instruction ago),
    //      valid only for NON-LOAD instructions (load data not yet ready)
    // ---------------------------------------------------------------

    // Start from register-file values captured at decode time
    rd1 = ((decoded_instruction_in.rs1 == 5'd0) ? `word_size'd0 : decoded_instruction_in.rd1);
    rd2 = ((decoded_instruction_in.rs2 == 5'd0) ? `word_size'd0 : decoded_instruction_in.rd2);

    // --- Level 2: register_file_bypass (WB stage wrote at same cycle as decode read) ---
    if (register_file_bypass_in.bypass_is_valid
        && register_file_bypass_in.rs != 5'd0
        && decoded_instruction_in.rs1 == register_file_bypass_in.rs)
        rd1 = register_file_bypass_in.rd;

    if (register_file_bypass_in.bypass_is_valid
        && register_file_bypass_in.rs != 5'd0
        && decoded_instruction_in.rs2 == register_file_bypass_in.rs)
        rd2 = register_file_bypass_in.rd;

    // --- Level 3: MEM/WB bypass (writeback_instruction_in, 2 cycles ago, incl. loads) ---
    if (writeback_instruction_in.is_instruction_valid
        && writeback_instruction_in.is_writeback_valid
        && writeback_instruction_in.wbs != 5'd0
        && decoded_instruction_in.rs1 == writeback_instruction_in.wbs)
        rd1 = writeback_instruction_in.wbd;

    if (writeback_instruction_in.is_instruction_valid
        && writeback_instruction_in.is_writeback_valid
        && writeback_instruction_in.wbs != 5'd0
        && decoded_instruction_in.rs2 == writeback_instruction_in.wbs)
        rd2 = writeback_instruction_in.wbd;

    // --- Level 4: EX/MEM bypass (executed_instruction_in, 1 cycle ago, NON-LOAD only) ---
    // For loads, the wbd at this point is the computed address, not the loaded data.
    // The load-use hazard stall in the control module prevents this case from
    // reaching execute incorrectly (the dependent instr is held for one cycle).
    if (executed_instruction_in.is_instruction_valid
        && executed_instruction_in.writeback_instruction.is_writeback_valid
        && executed_instruction_in.writeback_instruction.wbs != 5'd0
        && executed_instruction_in.instruction_opcode != q_load
        && decoded_instruction_in.rs1 == executed_instruction_in.writeback_instruction.wbs)
        rd1 = executed_instruction_in.writeback_instruction.wbd;

    if (executed_instruction_in.is_instruction_valid
        && executed_instruction_in.writeback_instruction.is_writeback_valid
        && executed_instruction_in.writeback_instruction.wbs != 5'd0
        && executed_instruction_in.instruction_opcode != q_load
        && decoded_instruction_in.rs2 == executed_instruction_in.writeback_instruction.wbs)
        rd2 = executed_instruction_in.writeback_instruction.wbd;

    bypassed_rd1_comb = rd1;
    bypassed_rd2_comb = rd2;

    // ALU / execution: computes result for R-type, I-type, U-type, etc. (add, sub, shift, compare, etc.).
    execute_result_comb = execute(
        cast_to_ext_operand(rd1),
        cast_to_ext_operand(rd2),
        cast_to_ext_operand(decoded_instruction_in.imm),
        decoded_instruction_in.pc,
        decoded_instruction_in.instruction_opcode,
        decoded_instruction_in.f3,
        decoded_instruction_in.f7);

    // Next PC: compute using direct compares for branches (spec-correct).
    // Do NOT infer branch conditions from subtraction sign bits; that fails on overflow
    // and breaks software routines (e.g. libgcc __udivsi3) that depend on correct Bxx.
    next_pc_comb = decoded_instruction_in.pc + 4;
    unique case (decoded_instruction_in.instruction_opcode)
        q_jal: begin
            next_pc_comb = decoded_instruction_in.pc + decoded_instruction_in.imm;
        end
        q_jalr: begin
            next_pc_comb = (rd1 + decoded_instruction_in.imm) & ~32'd1;
        end
        q_branch: begin
            logic take;
            take = 1'b0;
            unique case (decoded_instruction_in.f3)
                3'd0: take = (rd1 == rd2); // BEQ
                3'd1: take = (rd1 != rd2); // BNE
                3'd4: take = ($signed(rd1) <  $signed(rd2)); // BLT
                3'd5: take = ($signed(rd1) >= $signed(rd2)); // BGE
                3'd6: take = (rd1 < rd2);   // BLTU
                3'd7: take = (rd1 >= rd2);  // BGEU
                default: take = 1'b0;
            endcase
            if (take)
                next_pc_comb = decoded_instruction_in.pc + decoded_instruction_in.imm;
        end
        default: begin end
    endcase

    // Default: no PC correction
    pc_control_out = {($bits(pc_control_t)){1'b0}};
    pc_control_out.branch_redirect_needed = false;

    // Redirect only when this instruction changes control flow away from the sequential PC+4.
    // After adding 1-cycle-latency regfile reads (pipelined decode), fetch PC is no longer
    // aligned with the instruction currently in execute, so comparing against fetched PC
    // would cause spurious redirects.
    if (decoded_instruction_in.is_instruction_valid && next_pc_comb != (decoded_instruction_in.pc + 4)) begin
        pc_control_out.branch_redirect_needed = true;
        pc_control_out.branch_target_pc = next_pc_comb;
    end

end

// Sequential: pass instruction to memory stage and update PC tracking
always_ff @(posedge clk) begin
    if (reset) begin
        executed_instruction_out.is_instruction_valid <= false;
    end else begin
        if (decoded_instruction_in.is_instruction_valid && execute_control_signal_in.advance) begin
            executed_instruction_out.is_instruction_valid <= true;

            // Pass operands and write-back info to memory stage.
            executed_instruction_out.rd2 <= bypassed_rd2_comb;
            executed_instruction_out.writeback_instruction.wbs <= decoded_instruction_in.writeback_select;
            executed_instruction_out.writeback_instruction.is_writeback_valid <= decoded_instruction_in.is_writeback_valid;
            executed_instruction_out.writeback_instruction.wbd <= execute_result_comb[`word_size-1:0];
            executed_instruction_out.writeback_instruction.is_instruction_valid <= decoded_instruction_in.is_instruction_valid;
            executed_instruction_out.f3 <= decoded_instruction_in.f3;
            executed_instruction_out.instruction_opcode <= decoded_instruction_in.instruction_opcode;
        end else if (memory_control_signal_in.advance) begin
            // Execute didn't advance but memory did: clear execute output (bubble).
            executed_instruction_out <= {($bits(executed_instruction_t)){1'b0}};
            executed_instruction_out.is_instruction_valid <= false;
        end
    end
end
endmodule

// ---------------------------------------------------------------------------
// STAGE 4: MEMORY
// Issues data memory requests for loads and stores. For loads, the response is consumed
// in the writeback stage. Passes the executed instruction (with write-back info and f3/op_q
// for load formatting) to writeback.
// ---------------------------------------------------------------------------
module memory(
    input logic clk,
    input logic reset,

    input stage_control_signal_t memory_control_signal_in,
    input stage_control_signal_t writeback_control_signal_in,

    input register_file_bypass_t register_file_bypass_in,
    input writeback_instruction_t writeback_instruction_in,

    output memory_io_req   data_memory_request,
    input  memory_io_rsp   data_memory_response,
    input executed_instruction_t  executed_instruction_in,
    output memory_instruction_t memory_instruction_out
);

import riscv::*;

// Combinational: build data memory request
always_comb begin
    word rd2;

    rd2 = executed_instruction_in.rd2;
    data_memory_request = memory_io_no_req;

    if (memory_control_signal_in.advance && executed_instruction_in.is_instruction_valid
        && (executed_instruction_in.instruction_opcode == q_store
         || executed_instruction_in.instruction_opcode == q_load
         || executed_instruction_in.instruction_opcode == q_amo)) begin
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

// Sequential: pass instruction to writeback stage
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

// ---------------------------------------------------------------------------
// STAGE 5: WRITEBACK
// Selects the final result to write to the register file: for ALU/non-memory instructions
// it is the value already in writeback_instruction.wbd; for loads (and AMO) it is the
// data from data_mem_rsp, properly aligned and sign/zero-extended. This stage is
// purely combinatory: it drives writeback_instruction_out to decode (reg file write + bypass).
// ---------------------------------------------------------------------------
module writeback(
    input stage_control_signal_t writeback_control_signal_in,
    input memory_io_rsp data_memory_response,
    input memory_instruction_t memory_instruction_in,
    output writeback_instruction_t writeback_instruction_out
);

import riscv::*;

always_comb begin
    writeback_instruction_out = {($bits(writeback_instruction_t)){1'b0}};

    if (writeback_control_signal_in.advance && memory_instruction_in.is_instruction_valid) begin
        // Default: pass through the write-back payload from memory stage (ALU result, dest reg, etc.).
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

// ---------------------------------------------------------------------------
// Control: generates advance/flush per stage and set-PC for fetch.
// Currently no hazard or mispredict handling; all stages always advance.
// ---------------------------------------------------------------------------
module control(
    input memory_io_rsp instruction_memory_response,
    input memory_io_rsp data_memory_response,
    input pc_control_t pc_control_in,
    input fetched_instruction_t fetched_instruction_in,
    input decoded_instruction_t decoded_instruction_in,
    input executed_instruction_t executed_instruction_in,
    input memory_instruction_t memory_instruction_in,
    output stage_control_signal_t  fetch_control_signal_out,
    output stage_control_signal_t  decode_control_signal_out,
    output stage_control_signal_t  execute_control_signal_out,
    output stage_control_signal_t  memory_control_signal_out,
    output stage_control_signal_t  writeback_control_signal_out,
    output branch_pc_redirect_request_t branch_pc_redirect_request_out
);

import riscv::*;

// Stall / flush logic: when to advance each stage and when to redirect fetch
//
// Two hazard cases are handled:
//
// 1. LOAD-USE HAZARD
//    A load instruction is in the EX stage and the immediately following
//    instruction (currently in ID/decode) needs its result.  Because the
//    loaded data is not available until the end of the MEM stage, we must
//    insert one bubble between them:
//      - Freeze fetch (advance = false) so the same PC is replayed
//      - Freeze decode (advance = false) so the same fetched instruction
//        is re-decoded next cycle, producing the bubble for execute
//      - Freeze execute (advance = false) so the bubble flows through
//      - Let memory/writeback drain normally
//
// 2. BRANCH / JUMP MISPREDICT
//    After execute computes the true next-PC and discovers that fetch has
//    already fetched from the wrong address:
//      - Redirect fetch to the correct PC via branch_pc_redirect_request
//      - Flush the decode stage (the in-flight wrongly-fetched instruction)
//
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

    // ------------------------------------------------------------------
    // Load-use hazard has highest priority: check it first.
    //
    // Condition:
    //   - The instruction currently in the execute pipeline register
    //     (executed_instruction_in) is a LOAD, AND
    //   - The instruction currently in the decode pipeline register
    //     (decoded_instruction_in) reads the register that the load
    //     will write.
    // ------------------------------------------------------------------
    if (executed_instruction_in.is_instruction_valid
        && (executed_instruction_in.instruction_opcode == q_load)
        && decoded_instruction_in.is_instruction_valid
        && (executed_instruction_in.writeback_instruction.wbs != 5'd0)
        && ((decoded_instruction_in.rs1 == executed_instruction_in.writeback_instruction.wbs)
         || (decoded_instruction_in.rs2 == executed_instruction_in.writeback_instruction.wbs))
       ) begin
        // Stall fetch, decode, and execute for one cycle.
        fetch_control_signal_out.advance  = false;
        decode_control_signal_out.advance = false;
        execute_control_signal_out.advance = false;
    end else begin
        // ------------------------------------------------------------------
        // Branch / Jump mispredict: redirect fetch and flush decode.
        // Only check when there is no load-use stall active.
        // ------------------------------------------------------------------
        // PC redirect: prefer wrong-PC (stale) correction over branch mispredict for ordering
        if (pc_control_in.stale_instruction_in_execute) begin
            branch_pc_redirect_request_out.is_pc_valid = true;
            branch_pc_redirect_request_out.pc = pc_control_in.expected_execute_pc;
            decode_control_signal_out.flush = true;
        end else if (pc_control_in.branch_redirect_needed) begin
            branch_pc_redirect_request_out.is_pc_valid = true;
            branch_pc_redirect_request_out.pc = pc_control_in.branch_target_pc;
            decode_control_signal_out.flush = true;
        end
    end
end
endmodule

// ---------------------------------------------------------------------------
// Core: top-level 5-stage RISC-V pipeline (Fetch -> Decode -> Execute -> Memory -> Writeback).
// ---------------------------------------------------------------------------
module core #(
    parameter btb_enable = false
) (
    input logic       clk,
    input logic       reset,
    input logic       [`word_address_size-1:0] reset_pc,
    output memory_io_req   inst_mem_req,
    input  memory_io_rsp   inst_mem_rsp,
    output memory_io_req   data_mem_req,
    input  memory_io_rsp   data_mem_rsp
);

import riscv::*;

/* verilator lint_off UNOPTFLAT */
stage_control_signal_t fetch_control_signal, decode_control_signal, execute_control_signal, memory_control_signal, writeback_control_signal;
/* verilator lint_on UNOPTFLAT */
branch_pc_redirect_request_t branch_pc_redirect_request;
branch_pc_redirect_response_t branch_pc_redirect_response;

fetched_instruction_t fetched_instruction;

fetch fetch_m(
    .clk(clk),
    .reset(reset),
    .reset_pc(reset_pc),
    .fetch_control_signal_in(fetch_control_signal),
    .branch_pc_redirect_request_in(branch_pc_redirect_request),
    .branch_pc_redirect_response_out(branch_pc_redirect_response),
    .instruction_memory_request(inst_mem_req),
    .instruction_memory_response(inst_mem_rsp),
    .fetched_instruction_out(fetched_instruction)
);

register_file_bypass_t register_file_bypass;
decoded_instruction_t decoded_instruction;
writeback_instruction_t writeback_instruction;

decode_and_writeback decode_and_writeback_m(
    .clk(clk),
    .reset(reset),
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
    .pc_control_out(pc_control)
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
    .executed_instruction_in(executed_instruction),
    .memory_instruction_out(memory_instruction)
);

writeback writeback_m(
    .writeback_control_signal_in(writeback_control_signal),
    .data_memory_response(data_mem_rsp),
    .memory_instruction_in(memory_instruction),
    .writeback_instruction_out(writeback_instruction)
);

control control_m(
    .instruction_memory_response(inst_mem_rsp),
    .data_memory_response(data_mem_rsp),
    .pc_control_in(pc_control),
    .fetched_instruction_in(fetched_instruction),
    .decoded_instruction_in(decoded_instruction),
    .executed_instruction_in(executed_instruction),
    .memory_instruction_in(memory_instruction),
    .fetch_control_signal_out(fetch_control_signal),
    .decode_control_signal_out(decode_control_signal),
    .execute_control_signal_out(execute_control_signal),
    .memory_control_signal_out(memory_control_signal),
    .writeback_control_signal_out(writeback_control_signal),
    .branch_pc_redirect_request_out(branch_pc_redirect_request)
);

endmodule

`endif
