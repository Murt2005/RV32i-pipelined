// Drives the PS/2 receiver with real waveforms, including the ones that go
// wrong. A receiver that decodes clean frames is easy; the cases that matter on
// a desk with a real keyboard and a metre of cable are the corrupt ones, and
// the failure mode of getting them wrong is a key that sticks down in Doom.
//
//   iverilog -g2012 -o build/de1soc/ps2_tb fpga/de1soc/sim/ps2_tb.sv \
//       fpga/de1soc/ps2_keyboard.sv
//   ./build/de1soc/ps2_tb

`timescale 1ns / 1ps

module ps2_tb;

    logic clk = 0, reset = 1;
    always #10 clk = ~clk;                  // 50 MHz

    logic ps2_clk = 1, ps2_dat = 1;
    logic       code_valid;
    logic [7:0] code;
    logic       err_parity, err_framing, err_timeout;

    // A short timeout so the watchdog test does not take four simulated
    // milliseconds; the logic is identical at either value.
    ps2_keyboard #(.clk_hz(50_000_000), .timeout_us(40)) dut (
        .clk(clk), .reset(reset),
        .ps2_clk(ps2_clk), .ps2_dat(ps2_dat),
        .code_valid(code_valid), .code(code),
        .err_parity(err_parity), .err_framing(err_framing),
        .err_timeout(err_timeout)
    );

    int errors = 0;
    int k;
    logic [7:0] bad;
    int got_codes = 0, got_parity = 0, got_framing = 0, got_timeout = 0;
    logic [7:0] last_code;

    always_ff @(posedge clk) begin
        if (code_valid) begin got_codes++;  last_code <= code; end
        if (err_parity)  got_parity++;
        if (err_framing) got_framing++;
        if (err_timeout) got_timeout++;
    end

    // One PS/2 bit: data set up while the clock is high, then a falling edge.
    // ~16.7 kHz, so 30 us a bit -- the slow end of the spec, which is the
    // harder case for a watchdog.
    localparam time HALF = 15us;

    task send_bit(input logic b);
        ps2_dat = b;
        #(HALF) ps2_clk = 0;      // device shifts on the falling edge
        #(HALF) ps2_clk = 1;
    endtask

    // A whole frame, with the parity bit under the caller's control so a
    // deliberately corrupt one can be sent.
    task send_frame(input logic [7:0] d, input logic parity_bit);
        int i;
        send_bit(1'b0);                       // start
        for (i = 0; i < 8; i++) send_bit(d[i]);
        send_bit(parity_bit);
        send_bit(1'b1);                       // stop
        #(HALF * 4);
    endtask

    task send_good(input logic [7:0] d);
        send_frame(d, ~(^d));                 // odd parity
    endtask

    task check(input [255:0] what, input int got, input int want);
        if (got !== want) begin
            $display("FAIL %-30s got %0d want %0d", what, got, want);
            errors = errors + 1;
        end else begin
            $display("  ok %-30s %0d", what, got);
        end
    endtask

    initial begin
        repeat (10) @(posedge clk);
        reset = 0;
        #(HALF * 4);

        // --- a clean scancode: 0x1C is 'A' in set 2 -----------------------
        send_good(8'h1C);
        check("clean frame accepted",   got_codes, 1);
        check("  decoded value",        last_code, 8'h1C);
        check("  no parity error",      got_parity, 0);
        check("  no framing error",     got_framing, 0);

        // --- a break code sequence: F0 then the key -----------------------
        send_good(8'hF0);
        send_good(8'h1C);
        check("break sequence accepted", got_codes, 3);
        check("  last value",            last_code, 8'h1C);

        // --- 0x00, whose parity bit is 1 and which must not be mistaken
        //     for an idle line ------------------------------------------------
        send_good(8'h00);
        check("zero scancode accepted",  got_codes, 4);
        check("  decoded value",         last_code, 8'h00);

        // --- wrong parity: dropped, and reported ---------------------------
        send_frame(8'h55, ^(8'h55));          // even parity: wrong
        check("bad parity rejected",     got_codes, 4);
        check("  parity error raised",   got_parity, 1);

        // --- the receiver is not wedged by the bad frame -------------------
        send_good(8'h29);
        check("recovers after bad parity", got_codes, 5);
        check("  decoded value",           last_code, 8'h29);

        // --- stop bit low: framing error -----------------------------------
        bad = 8'h3B;
        send_bit(1'b0);                       // start
        for (k = 0; k < 8; k++) send_bit(bad[k]);
        send_bit(~(^bad));                    // correct parity
        send_bit(1'b0);                       // stop bit WRONG
        #(HALF * 4);
        check("bad stop bit rejected",   got_codes, 5);
        check("  framing error raised",  got_framing, 1);

        // --- a frame abandoned half way: the watchdog must free it ---------
        send_bit(1'b0);                       // start
        send_bit(1'b1);
        send_bit(1'b0);                       // ...and the keyboard vanishes
        ps2_clk = 1; ps2_dat = 1;
        #(200us);                             // well past the 40 us timeout
        check("partial frame timed out", got_timeout, 1);

        // --- and the receiver still works afterwards -----------------------
        send_good(8'h5A);
        check("recovers after timeout",  got_codes, 6);
        check("  decoded value",         last_code, 8'h5A);

        $display("");
        $display("%s (%0d errors)", errors ? "PS/2 FAILED" : "ps2 ok", errors);
        if (errors) $fatal(1);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("FAIL timeout");
        $fatal(1);
    end

endmodule
