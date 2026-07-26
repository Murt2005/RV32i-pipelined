`ifndef _uart_sv
`define _uart_sv

// ---------------------------------------------------------------------------
// Minimal 8N1 UART, parameterised by clocks-per-bit.
//
// CLKS_PER_BIT is a synthesis-time constant derived from CLK_FREQ / BAUD_RATE.
// It must agree numerically with what the RP2350 firmware asks for -- a
// mismatch produces garbled bytes, not silence (gotcha G4).
//
// On this board both ends are ultimately derived from the same 12 MHz crystal
// (the FPGA clock is XOSC exported through GPOUT0), so there is no relative
// drift and an exact integer divisor is safe.
// ---------------------------------------------------------------------------

module uart_tx #(
    parameter int CLKS_PER_BIT = 12
) (
    input  logic       clk,
    input  logic       rst,           // active high

    input  logic [7:0] data,
    input  logic       valid,         // 1-cycle pulse; accepted only when !busy
    output logic       busy,
    output logic       tx
);

    localparam int CTR_W = $clog2(CLKS_PER_BIT);

    logic [CTR_W-1:0] ctr;
    logic [3:0]       bit_idx;        // 0 = start, 1..8 = data, 9 = stop
    logic [7:0]       shifter;

    always_ff @(posedge clk) begin
        if (rst) begin
            tx      <= 1'b1;          // idle high
            busy    <= 1'b0;
            ctr     <= '0;
            bit_idx <= 4'd0;
            shifter <= 8'd0;
        end else if (!busy) begin
            tx <= 1'b1;
            if (valid) begin
                shifter <= data;
                busy    <= 1'b1;
                ctr     <= '0;
                bit_idx <= 4'd0;
                tx      <= 1'b0;      // start bit begins immediately
            end
        end else begin
            if (ctr == CTR_W'(CLKS_PER_BIT - 1)) begin
                ctr <= '0;
                if (bit_idx == 4'd9) begin
                    busy <= 1'b0;     // stop bit finished
                    tx   <= 1'b1;
                end else begin
                    bit_idx <= bit_idx + 4'd1;
                    tx      <= (bit_idx == 4'd8) ? 1'b1        // stop bit
                                                 : shifter[0];
                    shifter <= {1'b0, shifter[7:1]};
                end
            end else begin
                ctr <= ctr + {{(CTR_W-1){1'b0}}, 1'b1};
            end
        end
    end
endmodule


module uart_rx #(
    parameter int CLKS_PER_BIT = 12
) (
    input  logic       clk,
    input  logic       rst,           // active high

    input  logic       rx,            // raw pin, asynchronous
    output logic [7:0] data,
    output logic       valid,         // 1-cycle pulse
    output logic       frame_error
);

    localparam int CTR_W = $clog2(CLKS_PER_BIT);

    // Two-flop synchroniser: rx crosses from the RP2350's clock domain.
    logic rx_meta, rx_sync;
    always_ff @(posedge clk) begin
        rx_meta <= rx;
        rx_sync <= rx_meta;
    end

    logic             receiving;
    logic [CTR_W-1:0] ctr;
    logic [3:0]       bit_idx;
    logic [7:0]       shifter;

    always_ff @(posedge clk) begin
        valid       <= 1'b0;
        frame_error <= 1'b0;

        if (rst) begin
            receiving <= 1'b0;
            ctr       <= '0;
            bit_idx   <= 4'd0;
            shifter   <= 8'd0;
            data      <= 8'd0;
        end else if (!receiving) begin
            // Wait for the falling edge that starts a frame.
            if (!rx_sync) begin
                receiving <= 1'b1;
                // Half a bit time, so the next sample lands mid-start-bit.
                ctr       <= CTR_W'(CLKS_PER_BIT / 2);
                bit_idx   <= 4'd0;
            end
        end else begin
            if (ctr == CTR_W'(CLKS_PER_BIT - 1)) begin
                ctr <= '0;
                if (bit_idx == 4'd0) begin
                    // Mid-start-bit. If it is no longer low it was a glitch.
                    if (rx_sync)
                        receiving <= 1'b0;
                    else
                        bit_idx <= 4'd1;
                end else if (bit_idx <= 4'd8) begin
                    shifter <= {rx_sync, shifter[7:1]};   // LSB first
                    bit_idx <= bit_idx + 4'd1;
                end else begin
                    // Stop bit must be high, otherwise this is a framing error.
                    receiving <= 1'b0;
                    data      <= shifter;
                    valid     <= rx_sync;
                    frame_error <= ~rx_sync;
                end
            end else begin
                ctr <= ctr + {{(CTR_W-1){1'b0}}, 1'b1};
            end
        end
    end
endmodule

`endif
