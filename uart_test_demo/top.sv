module top (
    input clk
    ,input ICE_26
    ,output ICE_18
    ,input ICE_PB // aka ICE_10
);

logic rx = ICE_26;
logic tx;
assign ICE_18 = tx;
wire resetn = ICE_PB; // TODO: add debouncer?

// Dummmy/unused
logic [31:0] reg_dat_do, reg_div_do;

`define STR_LENGTH 5

localparam logic [8*`STR_LENGTH-1:0] MY_STRING = "HELLO";
logic [7:0] counter; // helps index the string and adds arbitrary delay so as not to spam too much

logic reg_dat_wait;
logic str_we;
assign str_we = (counter >= `STR_LENGTH) ? 0 : 1;
logic [7:0] str_idx;
assign str_idx = (str_we) ? counter : 0;

simpleuart #(.DEFAULT_DIV(103)) // <- IF RUNNING IN SIMULATOR, change to .DEFAULT_DIV(1)
theuart(
    .clk,
    .resetn,

	.ser_tx(tx),
	.ser_rx(rx),

	.reg_div_we(4'b0000), // Divider settings for adjusting speed/BAUD. We just set the with the parameter DEFAULT_DIV. 
	.reg_div_di(32'b0),
	.reg_div_do,

	.reg_dat_we(str_we),
	.reg_dat_re(1'b0), // Not doing any receiving on fpga side in this example
	.reg_dat_di({24'b0, MY_STRING[8*(`STR_LENGTH-1 - str_idx) +: 8]}), // cool indexing syntax, right value specifies width, left value specifies starting index, + specifies ascending
	.reg_dat_do,
	.reg_dat_wait
);

always_ff @(posedge clk) begin
    if (!resetn) begin
        counter <= 8'hFF;
    end else begin
        if (!reg_dat_wait)
            counter <= counter + 1;
    end
end

endmodule