`include "top.sv"

// Co-simulation top: the simulation top with the core's RVFI commit port brought out,
// so sim/cosim.cpp can check every retired instruction against Spike

module cosim_top(
    input  logic        clk,
    input  logic        reset,
    input  logic [7:0]  stall_rate,
    input  logic [7:0]  mem_delay,
    output logic        halt,

    output logic        rvfi_valid,
    output logic [31:0] rvfi_insn,
    output logic        rvfi_trap,
    output logic [31:0] rvfi_pc_rdata,
    output logic [31:0] rvfi_pc_wdata,
    output logic [4:0]  rvfi_rd_addr,
    output logic [31:0] rvfi_rd_wdata,
    output logic [31:0] rvfi_mem_addr,
    output logic [3:0]  rvfi_mem_rmask,
    output logic [3:0]  rvfi_mem_wmask,
    output logic [31:0] rvfi_mem_wdata
);

top the_top(
    .clk(clk),
    .reset(reset),
    .stall_rate(stall_rate),
    .mem_delay(mem_delay),
    .halt(halt)
);

assign rvfi_valid     = the_top.the_core.rvfi_valid;
assign rvfi_insn      = the_top.the_core.rvfi_insn;
assign rvfi_trap      = the_top.the_core.rvfi_trap;
assign rvfi_pc_rdata  = the_top.the_core.rvfi_pc_rdata;
assign rvfi_pc_wdata  = the_top.the_core.rvfi_pc_wdata;
assign rvfi_rd_addr   = the_top.the_core.rvfi_rd_addr;
assign rvfi_rd_wdata  = the_top.the_core.rvfi_rd_wdata;
assign rvfi_mem_addr  = the_top.the_core.rvfi_mem_addr;
assign rvfi_mem_rmask = the_top.the_core.rvfi_mem_rmask;
assign rvfi_mem_wmask = the_top.the_core.rvfi_mem_wmask;
assign rvfi_mem_wdata = the_top.the_core.rvfi_mem_wdata;

endmodule
