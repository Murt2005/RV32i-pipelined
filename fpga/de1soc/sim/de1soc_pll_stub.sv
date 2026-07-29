// Stand-in for the Quartus altera_pll, so the board top elaborates and can be
// simulated. Synthesis uses the generated IP with this same port list; this
// exists so a structural mistake in the top is caught here rather than an hour
// into a remote compile.
`timescale 1ns / 1ps
module de1soc_pll (
    input  logic refclk,
    input  logic rst,
    output logic outclk_0,     // 50 MHz, CPU + SDRAM
    output logic outclk_1,     // 25 MHz, pixel
    output logic outclk_2,     // 50 MHz, phase-shifted for DRAM_CLK
    output logic locked
);
    logic [1:0] div = 2'd0;
    always @(posedge refclk) div <= div + 2'd1;
    assign outclk_0 = div[0];      // 25 MHz from a 50 MHz refclk in sim
    assign outclk_1 = div[1];
    assign outclk_2 = div[0];
    // Locks after a short delay, so the top's reset sequencer is exercised.
    initial begin locked = 1'b0; #500 locked = 1'b1; end
endmodule
