`ifndef __cpu_sv
`define __cpu_sv

`include "riscv.sv"
`include "divider.sv"

// Request to set a new fetch PC (on branch/jump or mispredict)
typedef struct packed {
    bool is_pc_valid;
    riscv::word pc;
} branch_pc_redirect_request_t;

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
    riscv::instr_format instruction_format;
    riscv::instr32 instruction;
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
    riscv::tag rs1;
    riscv::tag rs2;
    riscv::word rd1;
    riscv::word rd2;
    riscv::funct3 f3;
    riscv::opcode_q instruction_opcode;
    writeback_instruction_t writeback_instruction;
} executed_instruction_t;

// ---------------------------------------------------------------------------
// The instruction in ID/EX reads a register the load in EX/MEM has not written
// yet, so it cannot be executed this cycle.
//
// Written once and used twice: control turns it into a one-cycle front-end
// stall, and execute uses it to hold off starting the divider. Those two have
// to agree exactly. When they did not -- when the divider started as soon as a
// divide appeared in ID/EX, regardless of this -- the unit latched the stale
// operand the stall exists to wait for, and `div t3, t2, t4` immediately after
// `lw t2` produced a wrong quotient. Nothing else caught it: the arithmetic was
// right, rv32um has no load-into-divide sequence, and formal cannot reach a
// retired divide at any tractable depth.
// ---------------------------------------------------------------------------
function automatic bool is_load_use_hazard(
        executed_instruction_t ex, decoded_instruction_t de);
    return ex.is_instruction_valid
        && (ex.instruction_opcode == riscv::q_load)
        && de.is_instruction_valid
        && (ex.writeback_instruction.wbs != 5'd0)
        && ((de.rs1 == ex.writeback_instruction.wbs)
         || (de.rs2 == ex.writeback_instruction.wbs));
endfunction

// PC correction struct from execute if branch misprediction or straight up wrong PC
typedef struct packed {
    bool branch_redirect_needed;
    riscv::word branch_target_pc; // where fetch should go over branch
} pc_control_t;

// Branch-target-buffer training, from execute back to fetch. A prediction only
// changes *when* fetch goes somewhere, never whether the result is correct:
// execute already compares the resolved next PC against what fetch actually
// fetched, and redirects on any mismatch, so a wrong prediction costs exactly
// what no prediction costs today.
typedef struct packed {
    bool        valid;      // a control-flow instruction resolved this cycle
    bool        taken;      // its next PC is not pc + 4
    riscv::word pc;
    riscv::word target;
} btb_update_t;

// Trap taken in the execute stage. Execute is the commit point: instructions
// behind a redirect are already flushed at decode before they get here, so an
// exception raised here is precise -- the faulting instruction is turned into a
// bubble and never reaches writeback.
typedef struct packed {
    bool        taken;
    riscv::word cause;
    riscv::word epc;
    riscv::word tval;
} trap_t;

// Memory stage output, passes write-back info and load result (later) to writeback
typedef struct packed {
    bool is_instruction_valid;
    riscv::word pc;
    riscv::word execute_result;
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

    // Freeze the front end: a fetch is in flight and has not been answered, or
    // one cannot be issued at all. Consumed by control.
    output logic                                imem_wait,

    output fetched_instruction_t                fetched_instruction_out
);

import riscv::*;

word fetch_pc;
bool clear_fetch_stream;
word clear_to_this_pc;
instr32 latched_instruction_read;
bool latched_instruction_valid;
word latched_instruction_pc;

// Address of the request issued in the previous cycle -- i.e. the response
// arriving right now, which a stall would drop. Needed to realign correctly
// when nothing is latched yet (see the stall handling below).
word issued_pc;
bool issued_valid;

// ---------------------------------------------------------------------------
// Front-end stall for an instruction memory that does not answer in one cycle.
//
// Two things go wrong without it. The front end has no "this latched
// instruction has been consumed" bit: it relies on a response arriving every
// cycle so the bypass path overrides the latch, and the latch is re-presented
// only for the single cycle after a stall lifts. If a response is merely late,
// the latch is presented again and decode issues the same instruction twice.
// And if fetch cannot issue at all, fetch_pc holds while decode keeps
// consuming, with the same result.
//
// The stretch by one cycle is the subtle part. Freezing the front end destroys
// ID/EX and relies on fetch re-presenting the latch when the freeze lifts --
// which is only safe because a frozen fetch issues nothing, so no response can
// arrive on the cycle it lifts. A miss breaks exactly that: the response turns
// up on the release cycle, the bypass path forwards it, and the instruction
// waiting in the latch is never decoded at all. Holding the stall one cycle
// longer discards that response and re-fetches it, which costs two cycles per
// miss and makes this behave like the external stall input -- the most heavily
// exercised stall path in the design.
//
// Both terms are identically zero against a single-cycle memory that is always
// ready, so the existing behaviour is bit-for-bit unchanged.
// ---------------------------------------------------------------------------
logic ifetch_outstanding;
logic imiss_q;

wire imiss = ifetch_outstanding & ~instruction_memory_response.valid;

assign imem_wait = imiss | imiss_q | ~instruction_memory_response.ready;

always_ff @(posedge clk) begin
    if (reset) begin
        ifetch_outstanding <= 1'b0;
        imiss_q            <= 1'b0;
    end else begin
        if (instruction_memory_request.valid)
            ifetch_outstanding <= 1'b1;
        else if (instruction_memory_response.valid)
            ifetch_outstanding <= 1'b0;
        imiss_q <= imiss;
    end
end

// ---------------------------------------------------------------------------
// Branch target buffer: direct mapped, no history, predict taken on a hit.
//
// Only the low bits of the target are stored, with the branch's own upper bits
// reused to rebuild it. A target in a different 64K region simply mispredicts
// and gets corrected, so this costs accuracy on far jumps rather than
// correctness -- and it keeps the table small enough to fit on a UP5K that is
// already 80% full.
// ---------------------------------------------------------------------------
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
        issued_pc <= 0;
        issued_valid <= false;
        for (int i = 0; i < btb_entries; i++)
            btb_valid[i] <= 1'b0;
    end else begin
        issued_valid <= instruction_memory_request.valid;
        if (instruction_memory_request.valid)
            issued_pc <= fetch_pc;
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

        // If we issued a request this cycle, follow the prediction for where the
        // next one goes. A redirect below overrides this.
        if (instruction_memory_request.valid) begin
            if (btb_hit)
                fetch_pc <= btb_predicted;
            else
                fetch_pc <= fetch_pc + 4;
        end

        // Train on resolved control-flow instructions.
        if ((btb_enable != 0) && btb_update_in.valid) begin
            if (btb_update_in.taken) begin
                btb_valid[btb_wr_idx]  <= 1'b1;
                btb_tag[btb_wr_idx]    <= btb_wr_tag;
                btb_target[btb_wr_idx] <= btb_update_in.target[15:2];
            end else if (btb_valid[btb_wr_idx] && (btb_tag[btb_wr_idx] == btb_wr_tag)) begin
                // Fell through: stop predicting it, or every pass would
                // mispredict twice instead of once.
                btb_valid[btb_wr_idx] <= 1'b0;
            end
        end

        // redirect fetch PC if needed
        if (branch_pc_redirect_request_in.is_pc_valid) begin
            fetch_pc <= branch_pc_redirect_request_in.pc;
            latched_instruction_valid <= false;
            clear_fetch_stream <= true;
            clear_to_this_pc <= branch_pc_redirect_request_in.pc;
        end else if (!fetch_control_signal_in.advance) begin
            // Decode is stalled, so no request goes out and this cycle's
            // response is dropped. Realign the PC to whatever we must re-fetch
            // once the stall clears. Which address that is depends on what is
            // in flight, and getting it wrong silently resumes at the wrong
            // instruction:
            if (latched_instruction_valid) begin
                // Normal case. The latched instruction is re-presented to
                // decode, so the stream restarts after it.
                fetch_pc <= latched_instruction_pc + 4;
                clear_fetch_stream <= true;
                clear_to_this_pc <= latched_instruction_pc + 4;
            end else if (clear_fetch_stream) begin
                // A redirect is still resolving: nothing is latched and the
                // in-flight response is wrong-path. fetch_pc / clear_to_this_pc
                // already name the target, so hold them. Without this the
                // realign above would overwrite a freshly applied branch target
                // with a stale latched_instruction_pc + 4.
                fetch_pc <= clear_to_this_pc;
                clear_fetch_stream <= true;
            end else if (issued_valid) begin
                // Nothing latched and no redirect pending: re-issue the request
                // whose response we are dropping.
                fetch_pc <= issued_pc;
                clear_fetch_stream <= true;
                clear_to_this_pc <= issued_pc;
            end
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
    input logic clear_regs,     // hold high >=32 cycles to zero the register file

    input stage_control_signal_t decode_control_signal_in,
    input stage_control_signal_t execute_control_signal_in,
    input stage_control_signal_t writeback_control_signal_in,

    output register_file_bypass_t register_file_bypass_out,

    input fetched_instruction_t fetched_instruction_in,
    output decoded_instruction_t decoded_instruction_out,

    input writeback_instruction_t writeback_instruction_in
);

import riscv::*;

// Register file and bypass state.
// ram_style forces the 32x32 file into block RAM on iCE40. Left in logic it
// costs ~1024 FFs plus two 32:1 x 32-bit read muxes, which is the difference
// between fitting on a UP5K and not. Ignored by simulators.
(* ram_style = "block" *)
word register_file[0:31];
word register_file_bypass_rd;
tag register_file_bypass_rs;
bool register_file_bypass_valid;
tag  clear_idx;

// Bypass is driven combinationally from the same values we write to the reg file (see write-back block below).
always_comb begin
    register_file_bypass_out.bypass_is_valid = register_file_bypass_valid;
    register_file_bypass_out.rd = register_file_bypass_rd;
    register_file_bypass_out.rs = register_file_bypass_rs;
end

// Reset register file to zero at elaboration (simulation).
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
        register_file_bypass_valid <= false;  // default; set true only in writeback block below

    // Decode output: either a valid decoded instruction or a bubble
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
            // no advance or invalid fetch: send a bubble (invalid decoded instruction).
            decoded_instruction_out <= {($bits(decoded_instruction_t)){1'b0}};
            decoded_instruction_out.is_instruction_valid <= false;
        end
    end

    // Register file read: when we advance with a valid instruction, latch the read data.
    //
    // This is deliberately a *plain* synchronous read with no mux on the output
    // register, so it maps onto a block RAM. The write-back-during-decode case
    // it used to handle here is already covered one stage later by execute's
    // level-2 bypass (register_file_bypass_in), which is registered from the
    // very same write-back event and lands on exactly the cycle this
    // instruction reaches execute.
    if (decode_control_signal_in.advance && fetched_instruction_in.is_instruction_valid) begin
        decoded_instruction_out.rd1 <= register_file[rs1];
        decoded_instruction_out.rd2 <= register_file[rs2];
    end

    // Write-back: record the bypass. The register file write itself is done by
    // the single muxed port below.
    if (!reset
        && writeback_control_signal_in.advance
        && writeback_instruction_in.is_instruction_valid
        && writeback_instruction_in.is_writeback_valid) begin
        register_file_bypass_rs <= writeback_instruction_in.wbs;
        register_file_bypass_rd <= writeback_instruction_in.wbd;
        register_file_bypass_valid <= true;
    end

    // Sequential clear, one register per cycle.
    if (clear_regs)
        clear_idx <= clear_idx + 5'd1;
    else
        clear_idx <= 5'd0;
end

// ---------------------------------------------------------------------------
// The register file's single write port, explicitly muxed between write-back
// and the clear.
//
// Writing the array from two separate conditions infers a *second* write port,
// which a 1W1R block RAM cannot provide -- yosys then refuses to map it and the
// design stops fitting on the UP5K. Keeping one write site keeps it in BRAM.
//
// The clear exists because the `initial` block above is simulation-only: on
// hardware the file is block RAM whose contents survive a core reset, so
// without it a second run would inherit the previous program's registers.
// ---------------------------------------------------------------------------
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

    output pc_control_t pc_control_out,
    output btb_update_t btb_update_out,

    // Freeze the front end while the iterative divider runs. Consumed by
    // control, and shaped exactly like the load-use stall.
    output logic div_wait
`ifdef RVFI
    // Everything RVFI needs about the instruction leaving execute. Guarded
    // because carrying it through the real pipeline registers would cost more
    // than the UP5K has left.
    ,output logic        rvfi_ex_valid
    ,output logic [31:0] rvfi_ex_insn
    ,output logic [31:0] rvfi_ex_pc
    ,output logic [31:0] rvfi_ex_next_pc
    ,output logic [4:0]  rvfi_ex_rs1_addr
    ,output logic [4:0]  rvfi_ex_rs2_addr
    ,output logic [31:0] rvfi_ex_rs1_rdata
    ,output logic [31:0] rvfi_ex_rs2_rdata
    ,output logic        rvfi_ex_trap
`endif
);

import riscv::*;

// Internal state
ext_operand execute_result_comb;
next_pc_result_t next_pc_result;
word next_pc_comb;
bool mispredict;
word bypassed_rd1_comb;
word bypassed_rd2_comb;

// ---------------------------------------------------------------------------
// M extension, divide half.
//
// Multiply is combinational in the ALU; only divide is iterative, because it is
// rare enough that a fast divider would be area spent for nothing.
//
// The handshake has to survive this pipeline's replay behaviour. Freezing the
// front end clears ID/EX, so the divide instruction disappears from decode
// while the unit is running and is re-decoded from the fetch latch once the
// freeze lifts -- the same mechanism the load-use stall relies on. That is why
// the stall is held by the unit's own `busy` rather than by the instruction
// being present, and why the result is parked in `done` until the instruction
// comes back around to collect it.
//
// Nothing can flush the divide while it is in flight: the front end is frozen,
// so execute sees a bubble and can raise neither a redirect nor a trap, and
// division has no architectural exception of its own.
//
// That argument is about *synchronous* control flow only, and interrupts are not
// synchronous. When mtime/mip land, an interrupt taken between the unit
// finishing and the instruction returning to collect would strand the result,
// and the next divide would take it. The assertion below turns that into a loud
// failure rather than a wrong answer, but the handshake will need revisiting.
// ---------------------------------------------------------------------------
`ifndef ext_m_disable
wire is_div_op = decoded_instruction_in.is_instruction_valid
              && (decoded_instruction_in.instruction_opcode == q_op)
              && (decoded_instruction_in.f7 == f7_ext_mul)
              && decoded_instruction_in.f3[2];      // 4..7 are DIV/DIVU/REM/REMU

logic        div_busy, div_done;
word         div_result;

// Not while the operands are still in flight: a load-use hazard means rs1 or
// rs2 is the destination of the load still in EX/MEM, and starting here would
// capture the value the stall exists to wait for.
wire div_start = is_div_op & ~div_busy & ~div_done
               & ~is_load_use_hazard(executed_instruction_in, decoded_instruction_in);
wire div_take  = is_div_op &  div_done & execute_control_signal_in.advance;

assign div_wait = (is_div_op & ~div_done) | div_busy;

divider divider_m(
    .clk(clk),
    .reset(reset),
    .start(div_start),
    .dividend(bypassed_rd1_comb),
    .divisor(bypassed_rd2_comb),
    .is_signed(~decoded_instruction_in.f3[0]),      // DIV/REM signed, *U not
    .want_rem(decoded_instruction_in.f3[1]),        // REM/REMU rather than DIV
    .busy(div_busy),
    .done(div_done),
    .take(div_take),
    .result(div_result)
);

`ifndef SYNTHESIS
// A parked result must be collected promptly. If it is not, the instruction it
// belongs to was lost, and the next divide would silently take this answer.
integer div_park;
always @(posedge clk) begin
    if (reset || !div_done)      div_park <= 0;
    else if (div_done)           div_park <= div_park + 1;
    // This detects a *lost owner*, not slowness, and the bound has to be far
    // above any legitimate wait or it reports the latter. Against a one-cycle
    // memory a result is collected about two cycles after it is parked. Against
    // a slow one it can take hundreds: to collect, the divide has to be in ID/EX
    // on a cycle execute advances, and after the freeze lifts fetch issues a
    // request that usually misses -- which freezes the front end again and
    // clears ID/EX before the collect can happen. It retries until it draws a
    // fast fetch. Measured over 900 such waits at MEM_LATENCY=16, with every
    // result still correct. An instruction cache removes most of this, since
    // hits answer in one cycle.
    if (div_park > 65536)
        $error("%m: divider result parked for %0d cycles -- owner never returned",
               div_park);
end
`endif
`else
// M disabled for this build: no divider, and the front end never waits on one.
// The ALU's multiply is compiled out to match (see riscv32_common.sv), so an M
// instruction decodes as whatever its funct3 means in the base ISA -- the same
// thing this core did before the extension existed.
wire                  is_div_op  = 1'b0;
wire                  div_done   = 1'b0;
wire [`word_size-1:0] div_result = '0;
assign div_wait = 1'b0;
`endif

// ---------------------------------------------------------------------------
// Machine-mode CSR file. Lives in execute because that is where CSR
// instructions commit: only one instruction is ever in this stage, and a write
// registered at the end of a cycle is visible to the next instruction's read,
// so no bypassing is needed.
// ---------------------------------------------------------------------------
word mstatus_r, mtvec_r, mepc_r, mcause_r, mtval_r;

// Machine counters. 64 bits so a long benchmark cannot wrap mid-measurement.
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

// Resolve one source operand against the three bypass sources. Kept as a
// function so rs1 and rs2 cannot drift apart.
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

// Combinational: operands, ALU, next-PC, and mispredict detection
always_comb begin
    word rd1;
    word rd2;

    // ---------------------------------------------------------------
    // Bypass Logic
    // Priority (highest first):
    //   1. executed_instruction_in: EX/MEM result (1 instruction ago), valid
    //      only for NON-LOAD instructions -- for a load, wbd is still the
    //      computed address. The load-use stall in control keeps a dependent
    //      instruction from reaching execute before the data exists.
    //   2. writeback_instruction_in: MEM/WB result (2 ago), valid for all
    //      instruction types including loads
    //   3. register_file_bypass: result written to the register file in the
    //      same cycle decode read it (WB concurrent with ID)
    //   4. the register file value captured at decode
    //
    // Written as one 4:1 mux rather than four chained overrides. The four
    // conditions are independent and only a few gates each, so resolving them
    // first leaves the 32-bit datapath two LUT levels deep instead of four --
    // and this sits directly in front of the ALU on the critical path.
    // ---------------------------------------------------------------
    rd1 = select_operand(decoded_instruction_in.rs1, decoded_instruction_in.rd1);
    rd2 = select_operand(decoded_instruction_in.rs2, decoded_instruction_in.rd2);

    bypassed_rd1_comb = rd1;
    bypassed_rd2_comb = rd2;

    // ---------------------------------------------------------------
    // SYSTEM decode and CSR access
    // ---------------------------------------------------------------
    csr_addr  = decoded_instruction_in.instruction[31:20];
    is_system = (decoded_instruction_in.instruction_opcode == q_system);
    is_csr    = is_system && is_csr_op(decoded_instruction_in.f3);
    is_ecall  = is_system && (decoded_instruction_in.f3 == 3'b000) && (csr_addr == 12'h000);
    is_ebreak = is_system && (decoded_instruction_in.f3 == 3'b000) && (csr_addr == 12'h001);
    is_mret   = is_system && (decoded_instruction_in.f3 == 3'b000) && (csr_addr == 12'h302);

    // Note the case labels are the *address* localparams from the riscv
    // package. The state registers below must not be named the same, or they
    // shadow those constants and every access silently falls to the default.
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
        // The immediate forms take a zero-extended 5-bit field from where rs1
        // would be, not a register.
        csr_operand = decoded_instruction_in.f3[2]
                    ? {{(`word_size-5){1'b0}}, decoded_instruction_in.rs1}
                    : rd1;

        case (decoded_instruction_in.f3[1:0])
            2'b01:   csr_write = csr_operand;                 // csrrw / csrrwi
            2'b10:   csr_write = csr_read | csr_operand;      // csrrs / csrrsi
            default: csr_write = csr_read & ~csr_operand;     // csrrc / csrrci
        endcase

        // Set/clear forms with a zero source must not write at all, so that
        // reading a CSR cannot have a side effect.
        csr_wen = is_csr &&
                  ((decoded_instruction_in.f3[1:0] == 2'b01) ||
                   (decoded_instruction_in.rs1 != 5'd0));
    end

    // ALU / execution: computes result for R-type, I-type, U-type, etc. (add, sub, shift, compare, etc.).
    execute_result_comb = execute(
        cast_to_ext_operand(rd1),
        cast_to_ext_operand(rd2),
        cast_to_ext_operand(decoded_instruction_in.imm),
        decoded_instruction_in.pc,
        decoded_instruction_in.instruction_opcode,
        decoded_instruction_in.f3,
        decoded_instruction_in.f7);

    // DIV/DIVU/REM/REMU come from the iterative unit instead. The ALU produced
    // zero for them above; substituting here keeps the divider out of that
    // function, which is shared with the formal model and wants to stay pure.
    if (is_div_op && div_done)
        execute_result_comb = {1'b0, div_result};

    // ---------------------------------------------------------------
    // Exceptions
    //
    // This must sit *after* the ALU above: the faulting address for a
    // misaligned access is the ALU result, and reading it earlier in the same
    // always_comb picks up the value from the previous evaluation -- i.e. the
    // previous instruction's address -- which raises traps on perfectly aligned
    // accesses.
    // ---------------------------------------------------------------
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


    // Next PC: for non-control-flow instructions this is PC+4; for branches/jumps it is the target.
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

    // A trap or an MRET overrides the normal next PC. mtvec is used in direct
    // mode: the low two bits select the mode and are not part of the address.
    //
    // Both targets come from CSRs, i.e. registers, so their comparisons against
    // the address fetch is presenting are parallel too -- only the select is
    // serial. The mispredict flag must be overridden alongside next_pc_comb:
    // leaving it at the non-trap value means the redirect to mtvec never fires
    // and the trap silently does not happen.
    if (trap.taken) begin
        next_pc_comb = {mtvec_r[`word_size-1:2], 2'b00};
        mispredict   = ({mtvec_r[`word_size-1:2], 2'b00} != fetched_instruction_in.pc);
    end else if (decoded_instruction_in.is_instruction_valid && is_mret) begin
        next_pc_comb = mepc_r;
        mispredict   = (mepc_r != fetched_instruction_in.pc);
    end

    // Train the branch predictor on resolved control transfers only. Traps
    // also change the next PC, but predicting them would be meaningless.
    // Default: no PC correction
    pc_control_out = {($bits(pc_control_t)){1'b0}};
    pc_control_out.branch_redirect_needed = false;

    // Mispredict: the next PC we computed (next_pc_comb) is not what fetch is currently fetching (fetched_instruction_in.pc).
    // Control can use this to redirect fetch to correct_pc.
    if (decoded_instruction_in.is_instruction_valid && mispredict) begin
        pc_control_out.branch_redirect_needed = true;
        pc_control_out.branch_target_pc = next_pc_comb;
    end

end

// Branch predictor training. Registered, deliberately.
//
// Qualifying this combinationally on execute_control_signal_in.advance would
// make this block depend on a `control` output, and `control` already depends
// on pc_control_out from the same block -- that closes a combinational loop
// which oscillates rather than settling, and wedges the simulator in zero time.
// Training a cycle late costs nothing: it is a prediction hint, not state the
// pipeline depends on.
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
// Shadow of the execute stage for RVFI. Note this tracks *every* instruction
// that leaves execute, including one that traps -- the real EX/MEM register
// gets a bubble in that case, but RVFI still has to report the faulting
// instruction with rvfi_trap set.
always_ff @(posedge clk) begin
    if (reset) begin
        rvfi_ex_valid <= 1'b0;
    end else begin
        rvfi_ex_valid     <= decoded_instruction_in.is_instruction_valid
                           & execute_control_signal_in.advance;
        rvfi_ex_insn      <= decoded_instruction_in.instruction;
        rvfi_ex_pc        <= decoded_instruction_in.pc;
        rvfi_ex_next_pc   <= next_pc_comb;
        rvfi_ex_rs1_addr  <= decoded_instruction_in.rs1;
        rvfi_ex_rs2_addr  <= decoded_instruction_in.rs2;
        // The *bypassed* operand values, which is what RVFI wants: the values
        // the instruction actually computed with.
        rvfi_ex_rs1_rdata <= bypassed_rd1_comb;
        rvfi_ex_rs2_rdata <= bypassed_rd2_comb;
        rvfi_ex_trap      <= trap.taken;
    end
end
`endif

// Sequential: pass instruction to memory stage, update CSRs and PC tracking
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
        // Free-running machine counters. Writes to them are dropped: they are
        // read-only here, which is permitted and keeps them off the CSR write
        // path.
        mcycle_r <= mcycle_r + 64'd1;
        if (decoded_instruction_in.is_instruction_valid
            && execute_control_signal_in.advance && !trap.taken)
            minstret_r <= minstret_r + 64'd1;

        // CSR side effects commit only when the instruction itself does.
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

        // A faulting instruction must not commit: turn it into a bubble rather
        // than passing it to memory, so it neither issues its access nor writes
        // back. Everything behind it is flushed by the redirect.
        if (decoded_instruction_in.is_instruction_valid && execute_control_signal_in.advance
            && !trap.taken) begin
            executed_instruction_out.is_instruction_valid <= true;

            // Pass operands and write-back info to memory stage.
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

            // CSR reads deliver their result through the normal write-back path.
            if (is_csr)
                executed_instruction_out.writeback_instruction.wbd <= csr_read;
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
    output memory_instruction_t memory_instruction_out,
    output logic           retired,

    // Freeze the memory and writeback stages: an access has been accepted and
    // its response has not arrived. Consumed by control.
    output logic           dmem_wait,
    // The access wants to go out but the target will not take it this cycle.
    // A weaker stall -- nothing is in flight, so writeback may still drain.
    output logic           dmem_issue_blocked
);

// One pulse per instruction leaving EX/MEM. Flushed instructions never get
// here -- they are turned into bubbles at decode -- so this counts committed
// instructions, which is what an IPC figure needs.
assign retired = memory_control_signal_in.advance
               & executed_instruction_in.is_instruction_valid;

import riscv::*;

// ---------------------------------------------------------------------------
// Outstanding-access tracking.
//
// The request used to be gated on memory_control_signal_in.advance, which was
// fine while every access finished in one cycle and the stage therefore always
// advanced. Once a miss can freeze the stage, that gating would retract a
// request mid-flight, so issue is decoupled from advance and tracked here.
//
// The stage issues an access exactly once, in the first cycle its occupant is
// able to go out, and the two stall outputs below keep it there until it has.
// There is deliberately no "already issued" flag: control freezes this stage
// whenever an access could not be issued or is still in flight, so an occupant
// can never advance past its own request. That is asserted rather than
// defended against -- if some later change gates this stage for another reason,
// the assertion fires instead of a store silently going out twice or not at all.
// ---------------------------------------------------------------------------
logic access_outstanding;   // accepted, response not yet returned

// Clears in the same cycle the response lands, so back-to-back accesses still
// go out one per cycle and the single-cycle case is unchanged.
wire access_busy = access_outstanding & ~data_memory_response.valid;

wire is_memory_op = executed_instruction_in.is_instruction_valid
                  && (executed_instruction_in.instruction_opcode == q_store
                   || executed_instruction_in.instruction_opcode == q_load
                   || executed_instruction_in.instruction_opcode == q_amo);

wire want_issue = is_memory_op & ~access_busy;

// valid already carries ready, so acceptance is just the request being valid.
wire issue_accepted = data_memory_request.valid;

assign dmem_wait          = access_busy;
assign dmem_issue_blocked = want_issue & ~data_memory_response.ready;

always_ff @(posedge clk) begin
    if (reset)
        access_outstanding <= 1'b0;
    else if (issue_accepted)
        access_outstanding <= 1'b1;
    else if (data_memory_response.valid)
        access_outstanding <= 1'b0;
end

`ifndef SYNTHESIS
// A memory instruction must not leave EX/MEM without having issued its access.
// This is the property that makes the missing "already issued" flag safe, and
// the failure it catches is a lost store, which has no other symptom.
always @(posedge clk) begin
    if (!reset && memory_control_signal_in.advance && is_memory_op && !issue_accepted)
        $error("%m: memory instruction left EX/MEM without issuing (addr %08x)",
               executed_instruction_in.writeback_instruction.wbd);
end
`endif

// Combinational: build data memory request
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
// Four inputs were removed from this module: both raw memory responses, the
// fetched instruction and the memory-stage instruction. All four were declared
// and never read. That was harmless while every stage advanced unconditionally,
// but once fetch's and writeback's advance signals started varying, the unread
// ports made Verilator see combinational loops through them -- fetch drives its
// output combinationally from its own advance, so a port carrying that output
// back into control closes a cycle even if nothing reads it.
module control(
    input logic stall,
    // Decoded from the memory response protocol by the stages that own it, so
    // that it is interpreted in exactly one place each. These replace the raw
    // responses, which this module took as inputs and never looked at.
    input logic imem_wait,
    input logic dmem_wait,
    input logic dmem_issue_blocked,
    input logic div_wait,
    input pc_control_t pc_control_in,
    input decoded_instruction_t decoded_instruction_in,
    input executed_instruction_t executed_instruction_in,
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
    if (is_load_use_hazard(executed_instruction_in, decoded_instruction_in)) begin
        // Stall fetch, decode, and execute for one cycle.
        fetch_control_signal_out.advance  = false;
        decode_control_signal_out.advance = false;
        execute_control_signal_out.advance = false;
    end else begin
        // ------------------------------------------------------------------
        // Branch / Jump mispredict: redirect fetch and flush decode.
        // Only check when there is no load-use stall active.
        // ------------------------------------------------------------------
        if (pc_control_in.branch_redirect_needed) begin
            branch_pc_redirect_request_out.is_pc_valid = true;
            branch_pc_redirect_request_out.pc = pc_control_in.branch_target_pc;
            decode_control_signal_out.flush = true;
        end
    end

    // ------------------------------------------------------------------
    // 3. FRONT-END FREEZE (overrides everything above)
    //
    // Four sources, all with the same shape: freeze fetch, decode and execute,
    // and let memory and writeback drain.
    //
    //   stall               Backpressure from a memory-mapped peripheral that
    //                       cannot accept another write yet (the board's UART
    //                       transmitter).
    //   imem_wait           A fetch is in flight and unanswered, or cannot be
    //                       issued. See fetch for why this also has to cover
    //                       the cycle the response finally arrives.
    //   dmem_issue_blocked  The access in EX/MEM cannot be handed over yet.
    //   dmem_wait           An accepted access has not been answered.
    //   div_wait            The iterative divider is running, or has an
    //                       instruction that has not started one yet.
    //
    // Two reasons this shape and not a whole-pipeline freeze:
    //
    //   * Correctness. The store already in EX/MEM issues its request once and
    //     EX/MEM then takes a bubble (execute is not advancing while memory
    //     is), so the peripheral sees each write exactly once. The instruction
    //     in ID/EX is re-decoded when the stall lifts, because the fetch latch
    //     still holds it.
    //   * Timing. Gating memory_control_signal_out.advance with `stall` would
    //     put the peripheral's own full/empty flag on a combinational path
    //     through the whole control block and back out through the memory
    //     stage's request -- a loop through the peripheral that measured
    //     112 ns and capped the design at 8.9 MHz. The two dmem_* signals below
    //     do gate that advance, but they come from registered state in the
    //     memory stage rather than from a peripheral's live request, so they do
    //     not close that loop.
    //
    // Suppressing the redirect and the flush is required, not tidiness:
    // execute is frozen, so it recomputes and reasserts the redirect when the
    // freeze lifts. Letting it through now would apply it while fetch's realign
    // is also running, which is the interaction that produced the recorded
    // fetch bug.
    // ------------------------------------------------------------------
    if (stall || imem_wait || dmem_issue_blocked || dmem_wait || div_wait) begin
        fetch_control_signal_out.advance = false;
        decode_control_signal_out.advance = false;
        execute_control_signal_out.advance = false;
        decode_control_signal_out.flush = false;
        branch_pc_redirect_request_out.is_pc_valid = false;
    end

    // ------------------------------------------------------------------
    // 4. BACK-END FREEZE (last, so nothing above can undo it)
    //
    // dmem_issue_blocked holds the memory stage so its occupant cannot advance
    // past an access it has not issued yet, but leaves writeback running: by
    // construction nothing is in flight in that cycle, so MEM/WB may be holding
    // a load whose response is live right now, and freezing writeback would
    // discard it.
    //
    // dmem_wait holds writeback as well. That is the whole point of it --
    // writeback reads data_memory_response combinationally, with no capture
    // register, so a load whose response has not arrived would otherwise be
    // marked invalid and its result dropped silently rather than waited for.
    // ------------------------------------------------------------------
    if (dmem_issue_blocked || dmem_wait)
        memory_control_signal_out.advance = false;

    if (dmem_wait)
        writeback_control_signal_out.advance = false;
end
endmodule

// ---------------------------------------------------------------------------
// Core: top-level 5-stage RISC-V pipeline (Fetch -> Decode -> Execute -> Memory -> Writeback).
// ---------------------------------------------------------------------------
module core #(
    parameter btb_enable  = 1,
    parameter btb_entries = 8
) (
    input logic       clk,
    input logic       reset,
    input logic       stall,          // freeze the whole pipeline (peripheral backpressure)
    input logic       clear_regs,     // zero the register file (hold >=32 cycles)
    output logic      retired,        // one pulse per committed instruction
    input logic       [`word_address_size-1:0] reset_pc,
    output memory_io_req   inst_mem_req,
    input  memory_io_rsp   inst_mem_rsp,
    output memory_io_req   data_mem_req,
    input  memory_io_rsp   data_mem_rsp
`ifdef RVFI
    ,output logic        rvfi_valid
    ,output logic [63:0] rvfi_order
    ,output logic [31:0] rvfi_insn
    ,output logic        rvfi_trap
    ,output logic        rvfi_halt
    ,output logic        rvfi_intr
    ,output logic [1:0]  rvfi_mode
    ,output logic [1:0]  rvfi_ixl
    ,output logic [4:0]  rvfi_rs1_addr
    ,output logic [4:0]  rvfi_rs2_addr
    ,output logic [31:0] rvfi_rs1_rdata
    ,output logic [31:0] rvfi_rs2_rdata
    ,output logic [4:0]  rvfi_rd_addr
    ,output logic [31:0] rvfi_rd_wdata
    ,output logic [31:0] rvfi_pc_rdata
    ,output logic [31:0] rvfi_pc_wdata
    ,output logic [31:0] rvfi_mem_addr
    ,output logic [3:0]  rvfi_mem_rmask
    ,output logic [3:0]  rvfi_mem_wmask
    ,output logic [31:0] rvfi_mem_rdata
    ,output logic [31:0] rvfi_mem_wdata
`endif
);

import riscv::*;

/* verilator lint_off UNOPTFLAT */
stage_control_signal_t fetch_control_signal, decode_control_signal, execute_control_signal, memory_control_signal, writeback_control_signal;
/* verilator lint_on UNOPTFLAT */
branch_pc_redirect_request_t branch_pc_redirect_request;

// Memory-protocol stalls, decoded in the stage that owns each port.
logic imem_wait, dmem_wait, dmem_issue_blocked;
// Iterative divider holding the front end while it runs.
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
    .imem_wait(imem_wait),
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
    .executed_instruction_in(executed_instruction),
    .memory_instruction_out(memory_instruction),
    .retired(retired),
    .dmem_wait(dmem_wait),
    .dmem_issue_blocked(dmem_issue_blocked)
);

writeback writeback_m(
    .writeback_control_signal_in(writeback_control_signal),
    .data_memory_response(data_mem_rsp),
    .memory_instruction_in(memory_instruction),
    .writeback_instruction_out(writeback_instruction)
);

`ifdef RVFI
// ---------------------------------------------------------------------------
// RVFI commit record.
//
// An instruction passes through EX/MEM and then MEM/WB, which is where its load
// data and write-back value become available. The shadow below runs in lockstep
// with that, one stage behind execute, so the record is assembled exactly at the
// commit point.
//
// Every shadow register is gated by the same advance signal as the pipeline
// register it shadows. That used to be unnecessary because memory and writeback
// always advanced; now that a slow access can freeze them, an ungated shadow
// would shift a bubble in while the real MEM/WB still held the load, and report
// the wrong instruction with an rvfi_mem_rdata read from a response that had not
// arrived. riscv-formal reasons only about what this port says, so that is the
// kind of error that produces confident nonsense in both directions.
// ---------------------------------------------------------------------------
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
        // Mirrors the MEM/WB pipeline register in the memory stage exactly:
        // loaded when the memory stage advances, cleared when it does not but
        // writeback does.
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
            // Sampled on the cycle the instruction leaves EX/MEM, which is
            // exactly the cycle its request is on the wire -- the memory stage
            // asserts that it cannot advance without having issued.
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

// The instruction commits on the cycle it actually leaves MEM/WB. Without the
// advance qualifier a held instruction would be reported once per stalled cycle,
// which breaks rvfi_order uniqueness and the pc-chain checks at once.
assign rvfi_valid      = rvfi_wb_valid & writeback_control_signal.advance;
assign rvfi_order      = rvfi_order_r;
assign rvfi_insn       = rvfi_wb_insn;
assign rvfi_trap       = rvfi_wb_trap;
assign rvfi_halt       = 1'b0;
assign rvfi_intr       = 1'b0;
assign rvfi_mode       = 2'd3;          // machine mode only
assign rvfi_ixl        = 2'd1;          // RV32
assign rvfi_rs1_addr   = rvfi_wb_rs1_addr;
assign rvfi_rs2_addr   = rvfi_wb_rs2_addr;
assign rvfi_rs1_rdata  = (rvfi_wb_rs1_addr == 5'd0) ? 32'd0 : rvfi_wb_rs1_rdata;
assign rvfi_rs2_rdata  = (rvfi_wb_rs2_addr == 5'd0) ? 32'd0 : rvfi_wb_rs2_rdata;
// writeback_instruction is combinational off MEM/WB, so it lines up with the
// shadow. A trapping or non-writing instruction reports x0 / zero.
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
    .imem_wait(imem_wait),
    .dmem_wait(dmem_wait),
    .dmem_issue_blocked(dmem_issue_blocked),
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
// ---------------------------------------------------------------------------
// memory_io protocol checks.
//
// These pin down the assumptions the pipeline currently makes about memory,
// which until now were only true by accident of both targets answering in
// exactly one cycle and never refusing a request. A cache backed by external
// memory does neither, so the assumptions have to be visible before they are
// changed -- otherwise the way they break is silent: a load whose response
// arrives late is not stalled on, it is *dropped* (see writeback, which ands
// is_instruction_valid with data_memory_response.valid), and the instruction
// simply never writes back.
//
// Written as procedural checks rather than concurrent assertions so they run
// under Icarus as well as Verilator. Compiled out of the synthesised build.
// ---------------------------------------------------------------------------
logic chk_data_outstanding;
logic chk_inst_outstanding;

wire chk_data_accept = data_mem_req.valid & data_mem_rsp.ready;
wire chk_inst_accept = inst_mem_req.valid & inst_mem_rsp.ready;

// Plain always, not always_ff: Icarus warns on every $error inside an always_ff
// because it cannot be synthesised, which is exactly the point here.
always @(posedge clk) begin
    if (reset) begin
        // Still track acceptances during reset. fetch's request valid is not
        // gated on reset (see fetch: it is gated on the response's ready and on
        // advance), so a fetch issued in the last reset cycle is answered in the
        // first cycle after it -- and the memory, which has no reset input, is
        // right to answer it.
        chk_data_outstanding <= chk_data_accept;
        chk_inst_outstanding <= chk_inst_accept;
    end else begin
        // One outstanding access per port. user_tag exists to lift this, but
        // nothing drives it yet, so a second request in flight would make the
        // two responses indistinguishable.
        if (chk_data_accept && chk_data_outstanding && !data_mem_rsp.valid)
            $error("%m: second data request issued while one is still in flight (addr %08x)",
                   data_mem_req.addr);
        if (chk_inst_accept && chk_inst_outstanding && !inst_mem_rsp.valid)
            $error("%m: second instruction fetch issued while one is still in flight (addr %08x)",
                   inst_mem_req.addr);

        // A response with nothing outstanding means the target answered a
        // request that was never accepted, or answered one request twice.
        if (data_mem_rsp.valid && !chk_data_outstanding)
            $error("%m: data response with no request outstanding (addr %08x)",
                   data_mem_rsp.addr);
        if (inst_mem_rsp.valid && !chk_inst_outstanding)
            $error("%m: instruction response with no request outstanding (addr %08x)",
                   inst_mem_rsp.addr);

        chk_data_outstanding <= chk_data_accept | (chk_data_outstanding & ~data_mem_rsp.valid);
        chk_inst_outstanding <= chk_inst_accept | (chk_inst_outstanding & ~inst_mem_rsp.valid);
    end

    // The one that matters most. A load leaving MEM/WB must have its data in
    // the same cycle, because writeback reads data_memory_response live -- there
    // is no capture register. If the response is not there, the load is silently
    // discarded rather than waited for. This is the exact failure a multi-cycle
    // memory introduces, and it produces wrong answers with no other symptom.
    if (!reset && writeback_control_signal.advance
        && memory_instruction.is_instruction_valid
        && memory_instruction.instruction_opcode == q_load
        && !data_mem_rsp.valid)
        $error("%m: load retiring from MEM/WB with no data response -- result dropped");
end
`endif

endmodule

`endif
