// riscv-formal wrapper: memory data is free, and memory and stall timing are chosen by the solver
// Delays and refusals are bounded so liveness can't fail just because the environment never answers

`include "system.sv"
`include "memory-io.sv"
`include "rvfi_macros.vh"

module rvfi_wrapper (
    input         clock,
    input         reset,
    `RVFI_OUTPUTS
);
    // Free: the solver drives these
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

    // The M checks are left out of make run-insn: multiply is intractable for the solver,
    // and divide needs depth 56 to reach retirement (they run under make run-m)

    // checks.cfg depths are sized for the slower memory (genchecks.py won't allow comments there)

    // Solver-controlled refusal and response delay, one set per port
    (* keep *) `rvformal_rand_reg       inst_rand_ready, data_rand_ready;
    (* keep *) `rvformal_rand_reg       inst_rand_delay, data_rand_delay;

    // Memory target: one access at a time, 1 or 2 cycles of latency, address echoed back
    // ready is forced high after two refusals in a row
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

    // External stall from the solver, at most two cycles in a row so the core keeps retiring
    (* keep *) `rvformal_rand_reg stall_rand;

    logic [1:0] stall_run;
    always @(posedge clock) begin
        if (reset)                 stall_run <= 2'd0;
        else if (core_stall)       stall_run <= stall_run + 2'd1;
        else                       stall_run <= 2'd0;
    end

    wire core_stall = stall_rand & ~stall_run[1];

    `MEM_TARGET(imem, inst_req, inst_rsp, imem_rdata, inst_rand_ready, inst_rand_delay)
    `MEM_TARGET(dmem, data_req, data_rsp, dmem_rdata, data_rand_ready, data_rand_delay)

    core #(
        .btb_enable(1),
        .btb_entries(16)
    ) uut (
        .clk(clock),
        .reset(reset),
        .stall(core_stall),
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
