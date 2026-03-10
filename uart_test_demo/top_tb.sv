module top_tb();
    logic clk;
    logic ICE_26;
    logic ICE_18;
    logic ICE_PB;
    top dut(.*);

    // Set up the clock
    parameter CLOCK_PERIOD=100;
    initial begin
        clk <= 0;
        forever #(CLOCK_PERIOD/2) clk <= ~clk;
    end

    initial begin// : run_control
        $dumpfile("_build/default/top_tb.vcd");
        $dumpvars(0, top_tb);
        ICE_26 <= 1'b0;
        ICE_PB <= 1'b0; @(posedge clk);
                        @(posedge clk);
        ICE_PB <= 1'b1; @(posedge clk);
        repeat (1<<9) @(posedge clk);
        $finish;
    end
endmodule