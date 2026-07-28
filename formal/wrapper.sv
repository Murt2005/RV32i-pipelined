// riscv-formal wrapper for the RV32I pipelined core.
//
// The memory *data* is left free, which is the whole point: the solver picks
// whatever instruction stream and load values expose a violation. The memory
// *protocol* is constrained to match what a real target may do, and that is now
// wider than it used to be: this modelled a fixed one-cycle memory that always
// accepted, because that is what memory.sv and memory_spram.sv do.
//
// That is no longer good enough. The core now has stall paths for a memory that
// answers late or refuses a request, and against a memory that does neither
// those paths are unreachable -- every check would still pass and would prove
// nothing whatsoever about them. So the model here refuses requests and delays
// responses under the solver's control, and the fast single-cycle case is just
// one of the behaviours it can choose.
//
// Both are bounded structurally rather than by assumption, so `liveness` stays a
// statement about the core rather than about the environment: a response is at
// most one cycle late, and a refusal cannot repeat more than twice before ready
// is forced high. A memory allowed to never answer really does deadlock the
// core, and that would be a true counterexample about an environment no
// implementation has.

`include "system.sv"
`include "memory_io.sv"
`include "rvfi_macros.vh"

module rvfi_wrapper (
    input         clock,
    input         reset,
    `RVFI_OUTPUTS
);
    // Free: the solver drives these.
    (* keep *) `rvformal_rand_reg [31:0] imem_rdata;
    (* keep *) `rvformal_rand_reg [31:0] dmem_rdata;

    (* keep *) wire [`word_address_size-1:0] imem_addr;
    (* keep *) wire        imem_valid;
    (* keep *) wire [`word_address_size-1:0] dmem_addr;
    (* keep *) wire        dmem_valid;
    (* keep *) wire [3:0]  dmem_wstrb;

    memory_io_req inst_req, data_req;
    memory_io_rsp inst_rsp, data_rsp;

    assign imem_addr  = inst_req.addr;
    assign imem_valid = inst_req.valid;
    assign dmem_addr  = data_req.addr;
    assign dmem_valid = data_req.valid;
    assign dmem_wstrb = data_req.do_write;

    // On the eight M checks in checks.cfg. Both halves are excluded from the
    // default run, for different reasons, and `make run-insn` skips them.
    //
    // Multiply is intractable, not slow. insn_mul asks the solver to prove that
    // this core's 33x33 signed multiplier agrees with the model's, for every
    // operand pair -- an equivalence check between two multiplier structures,
    // which is the textbook hard case for SAT and SMT. Measured here: yices sat
    // on a single BMC step for over thirty-five minutes without returning.
    // Waiting longer is not a strategy; multipliers are verified by dedicated
    // equivalence checking, not by bounded model checking, and every practical
    // core does it that way.
    //
    // Divide is merely expensive. The unit is iterative and takes about
    // thirty-five cycles, so the instruction cannot retire inside the depth the
    // other checks use, and a check that cannot reach the retirement it is
    // asserting about passes vacuously rather than failing. Depth 56 makes them
    // reachable and correspondingly slow.
    //
    // The divider's arithmetic does not rest on them. It has a standalone
    // testbench covering every case the spec defines as a result rather than a
    // trap, both rounding directions, the wide divisors that overflow a 32-bit
    // shifted remainder, and four hundred random pairs; the rv32um suite; and
    // random differential testing against the reference model. What formal adds
    // here is the handshake around it -- that a divide cannot be started twice,
    // lost, or have its parked result collected by the wrong instruction -- and
    // the multiply checks, which are combinational and cheap.

    // The depths in checks.cfg were raised to suit this. An access can now take
    // two cycles rather than always one, and a request can be refused, so an
    // instruction sits in the pipeline longer and depths sized for a one-cycle
    // memory no longer reach the state being checked. That failure mode is a
    // check that passes without proving anything, which is worse than one that
    // fails. genchecks.py rejects comments inside its sections, hence this here.

    // Solver-controlled refusal and response delay, one set per port.
    (* keep *) `rvformal_rand_reg       inst_rand_ready, data_rand_ready;
    (* keep *) `rvformal_rand_reg       inst_rand_delay, data_rand_delay;

    // ------------------------------------------------------------------
    // A variable-latency memory target.
    //
    // Accepts at most one access. On acceptance it echoes the address back with
    // the response, which fetch relies on to tell a wanted response from one it
    // has redirected away from. Latency is 1 or 2 cycles: one is the old
    // behaviour and has to stay reachable so the fast path keeps its coverage,
    // and two is enough to exercise every new stall arm, including the extra
    // cycle fetch holds across the arrival of a late response. Wider ranges cost
    // proof depth exponentially and add no new behaviour -- the arms are the
    // same whether a response is two cycles late or ten.
    //
    // ready is forced high after two consecutive refusals. Structural rather
    // than an assumption so that liveness cannot fail on the environment.
    // ------------------------------------------------------------------
    `define MEM_TARGET(NAME, REQ, RSP, RDATA, RAND_READY, RAND_DELAY)          \
        logic NAME``_busy;                                                     \
        logic [1:0] NAME``_refuse;                                             \
        logic NAME``_rsp_valid;                                                \
        logic [`word_address_size-1:0] NAME``_rsp_addr;                        \
                                                                               \
        wire NAME``_ready  = ~NAME``_busy & (RAND_READY | NAME``_refuse[1]);   \
        wire NAME``_accept = REQ.valid & NAME``_ready                          \
                           & (is_any_byte(REQ.do_read) | is_any_byte(REQ.do_write)); \
                                                                               \
        always @(posedge clock) begin                                          \
            if (reset) begin                                                   \
                NAME``_busy      <= 1'b0;                                      \
                NAME``_rsp_valid <= 1'b0;                                      \
                NAME``_refuse    <= 2'd0;                                      \
            end else begin                                                     \
                NAME``_rsp_valid <= 1'b0;                                      \
                                                                               \
                if (NAME``_busy | RAND_READY) NAME``_refuse <= 2'd0;           \
                else                          NAME``_refuse <= NAME``_refuse + 2'd1; \
                                                                               \
                if (NAME``_accept) begin                                       \
                    NAME``_rsp_addr <= REQ.addr;                               \
                    /* delay 0 answers next cycle; delay 1 parks it for one */  \
                    if (RAND_DELAY) NAME``_busy      <= 1'b1;                  \
                    else            NAME``_rsp_valid <= 1'b1;                  \
                end else if (NAME``_busy) begin                                \
                    NAME``_busy      <= 1'b0;                                  \
                    NAME``_rsp_valid <= 1'b1;                                  \
                end                                                            \
            end                                                                \
        end                                                                    \
                                                                               \
        always_comb begin                                                      \
            RSP       = memory_io_no_rsp;                                      \
            RSP.addr  = NAME``_rsp_addr;                                       \
            RSP.data  = RDATA;                                                 \
            RSP.valid = NAME``_rsp_valid;                                      \
            RSP.ready = NAME``_ready;                                          \
        end

    `MEM_TARGET(imem, inst_req, inst_rsp, imem_rdata, inst_rand_ready, inst_rand_delay)
    `MEM_TARGET(dmem, data_req, data_rsp, dmem_rdata, data_rand_ready, data_rand_delay)

    core #(
        .btb_enable(1),
        .btb_entries(16)
    ) uut (
        .clk(clock),
        .reset(reset),
        .stall(1'b0),
        .clear_regs(1'b0),
        .reset_pc(32'h0001_0000),
        .inst_mem_req(inst_req),
        .inst_mem_rsp(inst_rsp),
        .data_mem_req(data_req),
        .data_mem_rsp(data_rsp),
        .retired(),

        .rvfi_valid(rvfi_valid),
        .rvfi_order(rvfi_order),
        .rvfi_insn(rvfi_insn),
        .rvfi_trap(rvfi_trap),
        .rvfi_halt(rvfi_halt),
        .rvfi_intr(rvfi_intr),
        .rvfi_mode(rvfi_mode),
        .rvfi_ixl(rvfi_ixl),
        .rvfi_rs1_addr(rvfi_rs1_addr),
        .rvfi_rs2_addr(rvfi_rs2_addr),
        .rvfi_rs1_rdata(rvfi_rs1_rdata),
        .rvfi_rs2_rdata(rvfi_rs2_rdata),
        .rvfi_rd_addr(rvfi_rd_addr),
        .rvfi_rd_wdata(rvfi_rd_wdata),
        .rvfi_pc_rdata(rvfi_pc_rdata),
        .rvfi_pc_wdata(rvfi_pc_wdata),
        .rvfi_mem_addr(rvfi_mem_addr),
        .rvfi_mem_rmask(rvfi_mem_rmask),
        .rvfi_mem_wmask(rvfi_mem_wmask),
        .rvfi_mem_rdata(rvfi_mem_rdata),
        .rvfi_mem_wdata(rvfi_mem_wdata)
    );
endmodule
