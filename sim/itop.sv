`include "top.sv"

// Top file used for iverilog. this is mostly a stub that includes the top which Verilator uses.

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
    // VCD dumping is opt-in. Dumping the whole design dominates run time, and
    // the riscv-tests suite runs 40 programs back to back.
    //   ./result-iverilog +vcd
    if ($test$plusargs("vcd")) begin
        $dumpfile("test.vcd");
        $dumpvars(0);
    end

    // Watchdog. Without it a program that never reaches the halt address hangs
    // the simulator forever, which turns one bad test into a stuck suite.
    //   ./result-iverilog +timeout=50000
    // Deliberately modest. A program that never halts costs this many cycles
    // per test, and a suite runs dozens of them -- at 500000 a broken change
    // makes the suite look like it has hung rather than failed. Raise it with
    // +timeout=<n> for genuinely long programs.
    if (!$value$plusargs("timeout=%d", max_cycles))
        max_cycles = 120000;

    // Stall the pipeline pseudo-randomly:  ./result-iverilog +stallrate=128
    if (!$value$plusargs("stallrate=%d", stall_rate))
        stall_rate = 8'd0;

    // Make both memories answer late, by 0..N extra cycles drawn per access:
    //   ./result-iverilog +memlatency=8
    // 0 is a passthrough and reproduces the single-cycle memory exactly. Note a
    // program takes many more cycles with this on, so the watchdog above needs
    // raising for anything but short tests.
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

// Sample halt on the negedge, not on a #15 timer. top.sv drives halt as a
// single-cycle pulse, so a 15ns sampler against a 10ns clock misses it unless
// the program keeps storing to the halt address -- which made termination
// depend on which cycle the store happened to land on.
always @(negedge clk) if (halt == 1'b1) $finish;

`ifdef RVFI
// Dump the commit record so it can be cross-checked against the reference
// model in host/rv32_model.py. Hierarchical rather than ported through top.sv,
// to keep the RVFI instrumentation out of the synthesised path entirely.
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
