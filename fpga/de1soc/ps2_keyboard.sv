// PS/2 keyboard receiver, producing the same key events the simulation harness
// injects over MMIO.
//
// PS/2 is a synchronous serial link clocked by the *keyboard*, not by us: 11
// bits per frame -- start(0), 8 data LSB-first, odd parity, stop(1) -- shifted
// on the falling edge of a 10-16.7 kHz clock the device drives. Against a
// 50 MHz system clock that is 3000-5000 cycles per bit, so nothing here needs
// to be fast; it needs to be robust against a line that is asynchronous, open
// drain, and physically long enough to ring.
//
// Three things this does that a minimal shift register does not:
//
// Synchronises and debounces both lines. They arrive from outside the FPGA with
// no relationship to our clock, so sampling them directly is a metastability
// bug that shows up as one wrong scancode an hour. Two flops for the crossing,
// then an 8-cycle agreement filter -- 160 ns, far below a 30 us bit but far
// above any ringing.
//
// Times out a partial frame. If a keyboard is unplugged mid-word, or a bit is
// lost to noise, a pure state machine waits for the missing edges forever and
// the keyboard is dead until reset. A watchdog returns to idle after ~4 ms,
// which is longer than any legitimate frame and shorter than a person notices.
//
// Checks parity and the stop bit, and drops bad frames. A corrupted scancode is
// worse than a missing one: in Doom it means a key that sticks down, and the
// player walks into a wall until they work out which one.
//
// Scancode set 2 is what a keyboard sends after power-on. This decodes the wire
// protocol only -- break codes (0xF0) and extended codes (0xE0) are passed up
// as flags and translated to Doom keycodes by the layer above, which is where
// the keymap belongs.

module ps2_keyboard #(
    parameter int clk_hz = 50_000_000,
    // Idle timeout for a partial frame. 4 ms is ~130 bit times.
    parameter int timeout_us = 4000
) (
    input  logic       clk,
    input  logic       reset,

    // Straight from the DE1-SoC's PS2_CLK / PS2_DAT pins. Receive only, so
    // these are inputs; driving the bus to send commands to the keyboard (LEDs,
    // typematic rate) would need open-drain outputs and is not needed here.
    input  logic       ps2_clk,
    input  logic       ps2_dat,

    // One pulse per accepted scancode byte.
    output logic       code_valid,
    output logic [7:0] code,

    // Diagnostics. Worth bringing out to LEDs during bring-up: a keyboard that
    // is wired wrong produces framing errors rather than silence, and the two
    // look identical from the CPU side.
    output logic       err_parity,
    output logic       err_framing,
    output logic       err_timeout
);

    localparam int TIMEOUT_CYCLES = (clk_hz / 1_000_000) * timeout_us;
    localparam int TW = $clog2(TIMEOUT_CYCLES + 1);

    // ---- synchronise, then filter ----------------------------------------
    logic [1:0] clk_sync, dat_sync;
    always_ff @(posedge clk) begin
        clk_sync <= {clk_sync[0], ps2_clk};
        dat_sync <= {dat_sync[0], ps2_dat};
    end

    // Agreement filter: the output only moves after 8 consecutive samples
    // agree. A shift register rather than a counter because the "has it been
    // stable" question is exactly "are these 8 bits all the same".
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

    // ---- frame assembly ---------------------------------------------------
    // bit_n counts 0..10 across start, 8 data, parity, stop.
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
            // Single-cycle pulses.
            code_valid  <= 1'b0;
            err_parity  <= 1'b0;
            err_framing <= 1'b0;
            err_timeout <= 1'b0;

            if (busy) begin
                if (watchdog == TW'(TIMEOUT_CYCLES)) begin
                    // Partial frame abandoned. Returning to idle is what makes
                    // an unplugged keyboard recoverable without a reset.
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
                    // A start bit is a 0. Anything else on an idle line is
                    // noise or the tail of a frame we already gave up on, and
                    // is ignored rather than beginning a doomed frame.
                    if (!dat_f) begin
                        shifter <= {dat_f, 10'd0};
                        bit_n   <= 4'd1;
                    end
                end else begin
                    shifter <= {dat_f, shifter[10:1]};   // LSB first
                    if (bit_n == 4'd10) begin
                        bit_n <= 4'd0;
                        // The completed frame, with this last bit shifted in:
                        // [0] start, [8:1] data, [9] parity, [10] stop.
                        if (dat_f != 1'b1) begin
                            err_framing <= 1'b1;         // stop bit must be 1
                        end else if (^{shifter[9:2], shifter[10]} != 1'b1) begin
                            // Odd parity over the 8 data bits plus the parity
                            // bit must be 1. Indices account for this cycle's
                            // shift not having landed in `shifter` yet.
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
