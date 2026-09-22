`include "top.sv"

// Top file used for iverilog. this is mostly a stub that includes the top which Verilator uses

`timescale 1ns / 1ps

module itop();

logic clk = 0;
logic reset = 1;
logic halt;
logic [7:0] stall_rate = 8'd0;
logic [7:0] mem_delay = 8'd0;

integer max_cycles;
integer cycles = 0;

top the_top(
    .clk(clk)
    ,.reset(reset)
    ,.stall_rate(stall_rate)
    ,.mem_delay(mem_delay)
    ,.halt(halt)
    ,.frame_done()
    ,.key_strobe(1'b0)
    ,.key_event(9'd0));

always #5 clk = ~clk;

initial begin
    if ($test$plusargs("vcd")) begin
        $dumpfile("test.vcd");
        $dumpvars(0);
    end

    if (!$value$plusargs("timeout=%d", max_cycles))
        max_cycles = 120000;

    if (!$value$plusargs("stallrate=%d", stall_rate))
        stall_rate = 8'd0;

    if (!$value$plusargs("memlatency=%d", mem_delay))
        mem_delay = 8'd0;

    reset = 1;
    #16 reset = 0;
end

always @(posedge clk) begin
    cycles = cycles + 1;
    if (cycles > max_cycles) begin
        $display("TIMEOUT after %0d cycles, fetch_pc=%08x",
                 cycles, the_top.the_core.fetch_m.fetch_pc);
        $finish;
    end
end

always @(negedge clk) if (halt == 1'b1) $finish;

`ifdef RVFI
always @(negedge clk) begin
    if (!reset && the_top.the_core.rvfi_valid)
        $display("RVFI %0d %08x %08x %08x %0d %08x %0d %08x %0d %08x %08x %1x %1x %08x %08x %0d",
                 the_top.the_core.rvfi_order,
                 the_top.the_core.rvfi_pc_rdata,
                 the_top.the_core.rvfi_pc_wdata,
                 the_top.the_core.rvfi_insn,
                 the_top.the_core.rvfi_rs1_addr,
                 the_top.the_core.rvfi_rs1_rdata,
                 the_top.the_core.rvfi_rs2_addr,
                 the_top.the_core.rvfi_rs2_rdata,
                 the_top.the_core.rvfi_rd_addr,
                 the_top.the_core.rvfi_rd_wdata,
                 the_top.the_core.rvfi_mem_addr,
                 the_top.the_core.rvfi_mem_rmask,
                 the_top.the_core.rvfi_mem_wmask,
                 the_top.the_core.rvfi_mem_rdata,
                 the_top.the_core.rvfi_mem_wdata,
                 the_top.the_core.rvfi_trap);
end
`endif

endmodule
