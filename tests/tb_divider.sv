// Standalone testbench for the iterative divider.
//
// Brought up on its own rather than through the pipeline, because a wrong
// quotient reached through five stages and a stall looks exactly like a stall
// bug, and the divider has far more interesting corner cases than the pipeline
// around it: both spec-defined results that are not traps, the truncate-toward-
// zero rounding that disagrees with a plain restoring algorithm, and the wide
// divisors that overflow a 32-bit shift.
//
//   iverilog -g2012 -I.. -o tb_divider tests/tb_divider.sv && ./tb_divider

`timescale 1ns / 1ps
`include "divider.sv"

module tb_divider();

logic        clk = 0;
logic        reset = 1;
logic        start = 0;
logic [31:0] dividend, divisor;
logic        is_signed, want_rem;
logic        busy, done, take = 0;
logic [31:0] result;

integer passes = 0;
integer fails  = 0;

divider dut(
    .clk(clk), .reset(reset),
    .start(start), .dividend(dividend), .divisor(divisor),
    .is_signed(is_signed), .want_rem(want_rem),
    .busy(busy), .done(done), .take(take), .result(result)
);

always #5 clk = ~clk;

// Reference: Verilog's / and % on signed values already truncate towards zero,
// which is what RISC-V wants -- unlike Python's, and unlike a bare restoring
// algorithm. The spec's three defined non-trap results are still special-cased.
function automatic [31:0] expected(input [31:0] a, input [31:0] b,
                                   input sgn, input rem);
    logic signed [31:0] sa, sb;
    begin
        sa = a; sb = b;
        if (b == 32'd0)
            expected = rem ? a : 32'hFFFF_FFFF;
        else if (sgn && a == 32'h8000_0000 && b == 32'hFFFF_FFFF)
            expected = rem ? 32'd0 : 32'h8000_0000;
        else if (sgn)
            expected = rem ? (sa % sb) : (sa / sb);
        else
            expected = rem ? (a % b) : (a / b);
    end
endfunction

task automatic check(input [31:0] a, input [31:0] b,
                     input sgn, input rem, input string label);
    logic [31:0] want;
    integer guard;
    begin
        want = expected(a, b, sgn, rem);

        @(negedge clk);
        dividend  = a;
        divisor   = b;
        is_signed = sgn;
        want_rem  = rem;
        start     = 1;
        @(negedge clk);
        start = 0;

        guard = 0;
        while (!done && guard < 200) begin
            @(negedge clk);
            guard = guard + 1;
        end

        if (!done) begin
            $display("FAIL %-6s %0d / %0d : never completed", label, a, b);
            fails = fails + 1;
        end else if (result !== want) begin
            $display("FAIL %-6s a=%08x b=%08x -> %08x, want %08x",
                     label, a, b, result, want);
            fails = fails + 1;
        end else begin
            passes = passes + 1;
        end

        take = 1;
        @(negedge clk);
        take = 0;
    end
endtask

// Directed corner cases, then a randomised sweep. The directed list is the one
// that matters: every entry is something a plain implementation gets wrong.
logic [31:0] ra, rb;
integer i;

initial begin
    repeat (3) @(negedge clk);
    reset = 0;
    @(negedge clk);

    // Spec-defined results that are not exceptions.
    check(32'd7,          32'd0,          1, 0, "div0");
    check(32'd7,          32'd0,          1, 1, "rem0");
    check(32'd7,          32'd0,          0, 0, "divu0");
    check(32'd7,          32'd0,          0, 1, "remu0");
    check(32'h8000_0000,  32'hFFFF_FFFF,  1, 0, "ovf");
    check(32'h8000_0000,  32'hFFFF_FFFF,  1, 1, "ovfr");

    // Truncation towards zero, in all four sign combinations.
    check(-32'sd7,        32'sd2,         1, 0, "-7/2");
    check(-32'sd7,        32'sd2,         1, 1, "-7%2");
    check(32'sd7,         -32'sd2,        1, 0, "7/-2");
    check(32'sd7,         -32'sd2,        1, 1, "7%-2");
    check(-32'sd7,        -32'sd2,        1, 0, "-7/-2");
    check(-32'sd7,        -32'sd2,        1, 1, "-7%-2");

    // Divisors with the top bit set: these overflow a 32-bit shifted remainder
    // and are what the 33-bit intermediate exists for.
    check(32'hFFFF_FFFF,  32'hFFFF_FFFE,  0, 0, "wide1");
    check(32'hFFFF_FFFF,  32'hFFFF_FFFE,  0, 1, "wide1r");
    check(32'hFFFF_FFFF,  32'h8000_0001,  0, 0, "wide2");
    check(32'hFFFF_FFFE,  32'h8000_0000,  0, 1, "wide3");

    // Identities and edges.
    check(32'd0,          32'd5,          1, 0, "zero");
    check(32'd1,          32'd1,          0, 0, "one");
    check(32'hFFFF_FFFF,  32'd1,          0, 0, "maxu");
    check(32'h8000_0000,  32'd1,          1, 0, "minsig");
    check(32'h7FFF_FFFF,  32'd2,          1, 0, "maxsig");

    // Randomised, both signednesses and both results.
    for (i = 0; i < 400; i = i + 1) begin
        ra = $random;
        rb = $random;
        check(ra, rb, i[0], i[1], "rand");
    end

    $display("");
    $display("divider: %0d passed, %0d failed", passes, fails);
    if (fails != 0) $display("*** FAILURES ***");
    $finish;
end

endmodule
