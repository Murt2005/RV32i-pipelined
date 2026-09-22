`ifndef _memory_delay_sv
`define _memory_delay_sv

`include "system.sv"
`include "memory_io.sv"
`include "memory.sv"

// A memory32 that does not answer in one cycle. Simulation only.

// verilator coverage_off
// This is a test fixture, not part of the design
module memory_delay #(
    parameter size = 4096
    ,parameter initialize_mem = 0
    ,parameter byte0 = "data0.hex"
    ,parameter byte1 = "data1.hex"
    ,parameter byte2 = "data2.hex"
    ,parameter byte3 = "data3.hex"
    ,parameter enable_rsp_addr = 1
    ) (
    input   clk
    ,input  reset
    ,input  [7:0] max_delay

    ,input memory_io_req32  req
    ,output memory_io_rsp32 rsp
    );

    memory_io_req32 inner_req;
    memory_io_rsp32 inner_rsp;

    memory32 #(
        .size(size)
        ,.initialize_mem(initialize_mem)
        ,.byte0(byte0)
        ,.byte1(byte1)
        ,.byte2(byte2)
        ,.byte3(byte3)
        ,.enable_rsp_addr(enable_rsp_addr)
    ) mem (
        .clk(clk)
        ,.reset(reset)
        ,.req(inner_req)
        ,.rsp(inner_rsp)
    );

    logic [15:0] lfsr;

    logic           holding;
    logic [7:0]     delay_left;
    memory_io_req32 pending;

    wire passthrough = (max_delay == 8'd0);

    wire can_accept = passthrough ? 1'b1 : (~holding & ~reset);
    wire accept_now = req.valid & can_accept;

    wire [7:0] this_delay = passthrough ? 8'd0 : (lfsr[7:0] % (max_delay + 8'd1));

    always_comb begin
        inner_req       = holding ? pending : req;
        inner_req.valid = (accept_now & (this_delay == 8'd0))
                        | (holding   & (delay_left == 8'd0));
    end

    always_comb begin
        rsp       = inner_rsp;
        rsp.ready = can_accept;
    end

    always @(posedge clk) begin
        if (reset) begin
            lfsr       <= 16'hACE1;
            holding    <= 1'b0;
            delay_left <= 8'd0;
        end else begin
            lfsr <= {1'b0, lfsr[15:1]} ^ (lfsr[0] ? 16'hB400 : 16'h0000);

            if (accept_now && this_delay != 8'd0) begin
                holding    <= 1'b1;
                pending    <= req;
                delay_left <= this_delay - 8'd1;
            end else if (holding) begin
                if (delay_left == 8'd0)
                    holding <= 1'b0;
                else
                    delay_left <= delay_left - 8'd1;
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk)
        if (!reset && req.valid && !can_accept)
            $error("%m: request presented while not ready (addr %08x)", req.addr);
`endif

endmodule
// verilator coverage_on

`endif
