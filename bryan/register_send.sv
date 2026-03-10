// This module is vibe coding. AI generated functions for byte FSM design and fixes. AI generated code accounts for 50% of code.

// Usage, takes inputs for clock, reset, and data. Load the data (address and contents) into the module and pull send to high. 
// It then goes busy and since data is latched, you may modify the input data and pull send to high when busy goes low.

// Register-send UART packetizer
// -----------------------------
// Wraps the low-level `uart_tx` shifter in a higher-level protocol
// for sending a single 32-bit register value over UART.
// Packet format (7 bytes total):
//   [0] 0xAA header
//   [1] register number (x0..x31)
//   [2..5] little-endian 32-bit register contents
//   [6] CRC-8 over bytes [0..5] using polynomial 0x07.
//
// Usage:
//   - Takes inputs for clock, reset, and data. Load the data
//     (address and contents) into the module and pulse `send` high.
//   - It then goes busy; because the data is latched internally, you
//     may change the inputs while `busy` is high.
//   - When `busy` returns low you can start another transfer.
//
// This module is vibe coding: AI-generated FSMs and CRC helpers with
// manual clean-up and integration glue.
module register_send (
    input   logic   CLK,
    input   logic   UART_CLK,
    input   logic   RST,
    input   logic   [31:0]  register_contents,
    input   logic   [7:0]   register_number,
    input   logic   send,
    output  logic   tx,
    output  logic   busy
);

    logic uart_send;
    logic [7:0] uart_data;
    logic uart_busy;
    logic send_single_pulse;
    logic [7:0] b0, b1, b2, b3, b4, b5, b6;
    logic [2:0] byte_index;

    // Byte-wise CRC-8 helper using polynomial 0x07.
    // This is intentionally written as a function so it can be reused
    // when building the final CRC over the packet fields.
    function [7:0] crc8_byte; // Poly 0x07 CRC8 function, (AI Generated)
        input [7:0] crc_in;
        input [7:0] data;
        reg   [7:0] crc;
        integer i;
        begin
            crc = crc_in ^ data;
            for (i = 0; i < 8; i = i + 1) begin
                if (crc[7])
                    crc = (crc<<1)^8'h07;
                else
                    crc = (crc<<1);
            end
            crc8_byte = crc;
        end
    endfunction

    typedef enum logic [2:0] {
        S_IDLE,
        S_LOAD,
        S_ASSERT_SEND,
        S_WAIT_BUSY_HIGH,
        S_WAIT_BUSY_LOW
    } state_t;

    state_t state;

    // High-level FSM that sequences through:
    //   - S_IDLE: wait for a rising edge on `send`
    //   - S_LOAD: select which packet byte to drive into `uart_data`
    //   - S_WAIT_BUSY_*: handshake with `uart_tx` via its `busy` flag
    //     until all bytes have been transmitted.
    always_ff @(posedge CLK) begin // State machine to determine current task. 
        if (RST) begin
            state      <= S_IDLE;
            byte_index <= 3'd0;
            uart_send  <= 1'b0;
            uart_data  <= 8'd0;
            busy       <= 1'b0;
            send_single_pulse <= 1'b0;
        end else begin
            send_single_pulse <= send;
            case (state)
            S_IDLE: begin
                uart_send <= 1'b0;
                busy      <= 1'b0;
                if (send & ~send_single_pulse) begin
                    busy <= 1'b1;
                    b0 <= 8'hAA;
                    b1 <= register_number;
                    b2 <= register_contents[7:0];
                    b3 <= register_contents[15:8];
                    b4 <= register_contents[23:16];
                    b5 <= register_contents[31:24];

                    b6 <= crc8_byte(
                              crc8_byte(
                              crc8_byte(
                              crc8_byte(
                              crc8_byte(
                              crc8_byte(8'h00, 8'hAA),
                                        register_number),
                                        register_contents[7:0]),
                                        register_contents[15:8]),
                                        register_contents[23:16]),
                                        register_contents[31:24]);

                    byte_index <= 3'd0;
                    state      <= S_LOAD;
                end
            end
            S_LOAD: begin
                case (byte_index)
                    3'd0: uart_data <= b0;
                    3'd1: uart_data <= b1;
                    3'd2: uart_data <= b2;
                    3'd3: uart_data <= b3;
                    3'd4: uart_data <= b4;
                    3'd5: uart_data <= b5;
                    3'd6: uart_data <= b6;
                endcase
                uart_send <= 1'b1;
                state     <= S_WAIT_BUSY_HIGH;
            end
            S_WAIT_BUSY_HIGH: begin
                if (uart_busy) begin
                    uart_send <= 1'b0;
                    state     <= S_WAIT_BUSY_LOW;
                end
            end
            S_WAIT_BUSY_LOW: begin
                if (!uart_busy) begin
                    if (byte_index == 3'd6)
                        state <= S_IDLE;
                    else begin
                        byte_index <= byte_index + 1'b1;
                        state      <= S_LOAD;
                    end
                end
            end
            endcase
        end
    end
    uart_tx uart_tx_inst (
        .clk       (CLK),
        .rst       (RST),
        .baud_tick (UART_CLK),
        .data      (uart_data),
        .send      (uart_send),
        .tx        (tx),
        .busy      (uart_busy)
    );

endmodule
