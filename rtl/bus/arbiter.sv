`ifndef _bus_arbiter_sv
`define _bus_arbiter_sv

`include "system.sv"
`include "memory_io.sv"

module bus_arbiter(
    input  logic clk,
    input  logic reset,

    input  memory_io_req  a_req,      // data side
    output memory_io_rsp  a_rsp,
    input  memory_io_req  b_req,      // instruction side
    output memory_io_rsp  b_rsp,

    output memory_io_req  t_req,
    input  memory_io_rsp  t_rsp
);

logic turn;
logic busy;
logic owner;

wire free = ~busy | t_rsp.valid;

wire a_ready = (turn == 1'b0) & free & t_rsp.ready;
wire b_ready = (turn == 1'b1) & free & t_rsp.ready;

wire a_take = a_req.valid & a_ready;
wire b_take = b_req.valid & b_ready;

always_comb begin
    t_req       = (turn == 1'b0) ? a_req : b_req;
    t_req.valid = a_take | b_take;
end

always_comb begin
    a_rsp       = t_rsp;
    a_rsp.valid = t_rsp.valid & busy & (owner == 1'b0);
    a_rsp.ready = a_ready;

    b_rsp       = t_rsp;
    b_rsp.valid = t_rsp.valid & busy & (owner == 1'b1);
    b_rsp.ready = b_ready;
end

always_ff @(posedge clk) begin
    if (reset) begin
        turn  <= 1'b0;
        busy  <= 1'b0;
        owner <= 1'b0;
    end else begin
        if (a_take | b_take) begin
            busy  <= 1'b1;
            owner <= b_take;
        end else if (t_rsp.valid)
            busy <= 1'b0;

        if (free & ~(a_take | b_take))
            turn <= ~turn;
    end
end

`ifndef SYNTHESIS
always @(posedge clk)
    if (!reset && t_rsp.valid && !busy)
        $error("%m: target answered with nothing outstanding");
`endif

endmodule

`endif
