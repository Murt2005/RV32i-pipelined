// UART clock divider
// ------------------
// Generates a single-cycle `baud_tick` enable by dividing the input
// clock by a fixed ratio (here, 12). The transmit logic uses this
// tick to step its state machine at the target baud rate.
module uart_clk (input logic CLK, input logic RST, output logic baud_tick);
    logic [3:0] counter;
    always_ff @(posedge CLK) begin
        if (RST) begin
            counter   <= 0;
            baud_tick <= 0;
        end else begin
            if (counter == 11) begin
                counter   <= 0;
                baud_tick <= 1;
            end else begin
                counter   <= counter + 1;
                baud_tick <= 0;
            end
        end
    end
endmodule