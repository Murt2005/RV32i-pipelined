// UART transmit shifter
// ----------------------
// Simple 8N1 UART transmitter that:
//   - latches an 8-bit data word when `send` is pulsed in IDLE
//   - shifts out start bit, 8 data bits (LSB-first), then stop bit
//   - asserts `busy` while a frame is in progress.
// This module is "vibe coded": AI-generated with minor tweaks and fixes.
module uart_tx (
    input  logic       clk,
    input  logic       rst,
    input  logic       baud_tick,
    input  logic [7:0] data,
    input  logic       send,
    output logic       tx,
    output logic       busy
);
    //----------------------------------------------------------------------
    // FSM
    //----------------------------------------------------------------------

    typedef enum logic [1:0] {
        IDLE,
        START,
        DATA,
        STOP
    } state_t;

    state_t state;

    logic [7:0] shift_reg;
    logic [3:0] bit_cnt;

    always_ff @(posedge clk) begin
        if (rst) begin
            state     <= IDLE;
            shift_reg <= 8'd0;
            bit_cnt   <= 4'd0;
            tx        <= 1'b1;
            busy      <= 1'b0;
        end
        else if (baud_tick) begin
            case (state)

                IDLE: begin
                    tx   <= 1'b1;
                    busy <= 1'b0;

                    if (send) begin
                        shift_reg <= data;
                        bit_cnt   <= 0;
                        busy      <= 1'b1;
                        state     <= START;
                    end
                end

                START: begin
                    tx    <= 1'b0;
                    state <= DATA;
                end

                DATA: begin
                    tx <= shift_reg[0];
                    shift_reg <= {1'b0, shift_reg[7:1]};

                    if (bit_cnt == 7)
                        state <= STOP;
                    else
                        bit_cnt <= bit_cnt + 1;
                end

                STOP: begin
                    tx    <= 1'b1;
                    state <= IDLE;
                end

            endcase
        end
    end

endmodule
