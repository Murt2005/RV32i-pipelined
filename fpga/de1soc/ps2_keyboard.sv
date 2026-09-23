// PS/2 keyboard receiver: synchronises and filters both lines, checks parity and stop bits,
// and times out a half-received frame so an unplugged keyboard doesn't wedge it

module ps2_keyboard #(
    parameter int clk_hz = 50_000_000,
    // Timeout for a half-received frame
    parameter int timeout_us = 4000
) (
    input  logic       clk,
    input  logic       reset,

    // Straight from the PS2_CLK and PS2_DAT pins, receive only
    input  logic       ps2_clk,
    input  logic       ps2_dat,

    // One pulse per accepted scancode byte
    output logic       code_valid,
    output logic [7:0] code,

    // One-cycle error pulses, handy on LEDs during bring-up
    output logic       err_parity,
    output logic       err_framing,
    output logic       err_timeout
);

    localparam int TIMEOUT_CYCLES = (clk_hz / 1_000_000) * timeout_us;
    localparam int TW = $clog2(TIMEOUT_CYCLES + 1);

    // Two-flop synchroniser
    logic [1:0] clk_sync, dat_sync;
    always_ff @(posedge clk) begin
        clk_sync <= {clk_sync[0], ps2_clk};
        dat_sync <= {dat_sync[0], ps2_dat};
    end

    // A line only changes after 8 samples in a row agree
    logic [7:0] clk_hist, dat_hist;
    logic       clk_f, dat_f;
    always_ff @(posedge clk) begin
        if (reset) begin
            clk_hist <= 8'hFF;  dat_hist <= 8'hFF;
            clk_f    <= 1'b1;   dat_f    <= 1'b1;
        end else begin
            clk_hist <= {clk_hist[6:0], clk_sync[1]};
            dat_hist <= {dat_hist[6:0], dat_sync[1]};
            if (clk_hist == 8'h00) clk_f <= 1'b0;
            if (clk_hist == 8'hFF) clk_f <= 1'b1;
            if (dat_hist == 8'h00) dat_f <= 1'b0;
            if (dat_hist == 8'hFF) dat_f <= 1'b1;
        end
    end

    logic clk_f_q;
    always_ff @(posedge clk) clk_f_q <= clk_f;
    wire clk_falling = clk_f_q & ~clk_f;

    // bit_n counts 0..10 across start, 8 data bits, parity and stop
    logic [3:0]  bit_n;
    logic [10:0] shifter;
    logic [TW-1:0] watchdog;

    wire busy = (bit_n != 4'd0);

    always_ff @(posedge clk) begin
        if (reset) begin
            bit_n       <= 4'd0;
            shifter     <= 11'd0;
            watchdog    <= '0;
            code_valid  <= 1'b0;
            code        <= 8'd0;
            err_parity  <= 1'b0;
            err_framing <= 1'b0;
            err_timeout <= 1'b0;
        end else begin
            code_valid  <= 1'b0;
            err_parity  <= 1'b0;
            err_framing <= 1'b0;
            err_timeout <= 1'b0;

            if (busy) begin
                if (watchdog == TW'(TIMEOUT_CYCLES)) begin
                    // Give up on a half-received frame
                    bit_n       <= 4'd0;
                    watchdog    <= '0;
                    err_timeout <= 1'b1;
                end else begin
                    watchdog <= watchdog + TW'(1);
                end
            end else begin
                watchdog <= '0;
            end

            if (clk_falling) begin
                watchdog <= '0;

                if (bit_n == 4'd0) begin
                    // A frame starts with a 0; anything else on an idle line is noise
                    if (!dat_f) begin
                        shifter <= {dat_f, 10'd0};
                        bit_n   <= 4'd1;
                    end
                end else begin
                    shifter <= {dat_f, shifter[10:1]};   // LSB first
                    if (bit_n == 4'd10) begin
                        bit_n <= 4'd0;
                        // Frame layout: [0] start, [8:1] data, [9] parity, [10] stop
                        if (dat_f != 1'b1) begin
                            err_framing <= 1'b1;         // stop bit must be 1
                        end else if (^{shifter[9:2], shifter[10]} != 1'b1) begin
                            // Odd parity; indices are off by one since this bit hasn't shifted in yet
                            err_parity <= 1'b1;
                        end else begin
                            code       <= shifter[9:2];
                            code_valid <= 1'b1;
                        end
                    end else begin
                        bit_n <= bit_n + 4'd1;
                    end
                end
            end
        end
    end

endmodule
