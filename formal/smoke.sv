module smoke(input clk, input rst, output reg [7:0] cnt);
always @(posedge clk) begin
    if (rst) cnt <= 0;
    else if (cnt == 8'd200) cnt <= 0;
    else cnt <= cnt + 1;
end
always @(posedge clk) assert (cnt <= 8'd200);
endmodule
