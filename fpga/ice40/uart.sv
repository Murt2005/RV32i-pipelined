`ifndef _uart_sv
`define _uart_sv

// Minimal 8N1 UART

module uart_tx #(
    parameter int CLKS_PER_BIT = 12
) (
    input  logic       clk,
    input  logic       rst,

    input  logic [7:0] data,
    input  logic       valid,
    output logic       busy,
    output logic       tx
);

    localparam int CTR_W = $clog2(CLKS_PER_BIT);

    logic [CTR_W-1:0] ctr;
    logic [3:0]       bit_idx;        // 0 = start, 1..8 = data, 9 = stop
    logic [7:0]       shifter;

    always_ff @(posedge clk) begin
        if (rst) begin
            tx      <= 1'b1;
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
                tx      <= 1'b0;
            end
        end else begin
            if (ctr == CTR_W'(CLKS_PER_BIT - 1)) begin
                ctr <= '0;
                if (bit_idx == 4'd9) begin
                    busy <= 1'b0;
                    tx   <= 1'b1;
                end else begin
                    bit_idx <= bit_idx + 4'd1;
                    tx      <= (bit_idx == 4'd8) ? 1'b1
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
    input  logic       rst,

    input  logic       rx,
    output logic [7:0] data,
    output logic       valid,
    output logic       frame_error
);

    localparam int CTR_W = $clog2(CLKS_PER_BIT);

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
            if (!rx_sync) begin
                receiving <= 1'b1;
                ctr       <= CTR_W'(CLKS_PER_BIT / 2);
                bit_idx   <= 4'd0;
            end
        end else begin
            if (ctr == CTR_W'(CLKS_PER_BIT - 1)) begin
                ctr <= '0;
                if (bit_idx == 4'd0) begin
                    if (rx_sync)
                        receiving <= 1'b0;
                    else
                        bit_idx <= 4'd1;
                end else if (bit_idx <= 4'd8) begin
                    shifter <= {rx_sync, shifter[7:1]};   // LSB first
                    bit_idx <= bit_idx + 4'd1;
                end else begin
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
