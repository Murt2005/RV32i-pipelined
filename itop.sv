`include "top.sv"

// Top file used for iverilog. this is mostly a stub that includes the top which Verilator uses.

`timescale 1ns / 1ps

module itop();

logic clk = 0;
logic reset = 1;
logic halt;

integer max_cycles;
integer cycles = 0;

top the_top(
    .clk(clk)
    ,.reset(reset)
    ,.halt(halt));

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
    if (!$value$plusargs("timeout=%d", max_cycles))
        max_cycles = 500000;

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

endmodule
