// riscv-formal wrapper for the RV32I pipelined core.
//
// The memory *data* is left free, which is the whole point: the solver picks
// whatever instruction stream and load values expose a violation. The memory
// *protocol* is constrained to match the real memories in memory.sv and
// memory_spram.sv -- a request presented in one cycle is answered in the next,
// with the response carrying back the address it was issued for. Without that
// the core would be judged against a memory that no implementation has, and
// the pc-chain checks would fail on the environment rather than on the design.

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

    // One-cycle memory, exactly as memory32/memory_spram behave: valid and the
    // echoed address are registered from the request, only the data is free.
    logic [`word_address_size-1:0] inst_rsp_addr_q, data_rsp_addr_q;
    logic inst_rsp_valid_q, data_rsp_valid_q;

    always @(posedge clock) begin
        if (reset) begin
            inst_rsp_valid_q <= 1'b0;
            data_rsp_valid_q <= 1'b0;
        end else begin
            inst_rsp_valid_q <= inst_req.valid
                              & (is_any_byte(inst_req.do_read) | is_any_byte(inst_req.do_write));
            inst_rsp_addr_q  <= inst_req.addr;
            data_rsp_valid_q <= data_req.valid
                              & (is_any_byte(data_req.do_read) | is_any_byte(data_req.do_write));
            data_rsp_addr_q  <= data_req.addr;
        end
    end

    always_comb begin
        inst_rsp          = memory_io_no_rsp;
        inst_rsp.addr     = inst_rsp_addr_q;
        inst_rsp.data     = imem_rdata;
        inst_rsp.valid    = inst_rsp_valid_q;
        inst_rsp.ready    = 1'b1;

        data_rsp          = memory_io_no_rsp;
        data_rsp.addr     = data_rsp_addr_q;
        data_rsp.data     = dmem_rdata;
        data_rsp.valid    = data_rsp_valid_q;
        data_rsp.ready    = 1'b1;
    end

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
