`ifndef _memory_sv
`define _memory_sv

`include "system.sv"
`include "memory_io.sv"

// Simulation memory. With max_delay > 0 each request waits 0..max_delay extra
// cycles, drawn from an LFSR, and ready drops while one is waiting

// verilator coverage_off
// This is a test model, not part of the design
module memory32 #(
    parameter size = 4096                       // in bytes
    ,parameter initialize_mem = 0
    ,parameter byte0 = "data0.hex"
    ,parameter byte1 = "data1.hex"
    ,parameter byte2 = "data2.hex"
    ,parameter byte3 = "data3.hex"
    ,parameter [15:0] seed = 16'hACE1           // nonzero; differs per instance so delays are independent
    ) (
    input   clk
    ,input  reset
    ,input  [7:0] max_delay

    ,input memory_io_req32  req
    ,output memory_io_rsp32 rsp
    );

    localparam size_l2 = $clog2(size);

    reg [7:0]   data0[0:size/4 - 1] /*verilator public_flat_rw*/;
    reg [7:0]   data1[0:size/4 - 1] /*verilator public_flat_rw*/;
    reg [7:0]   data2[0:size/4 - 1] /*verilator public_flat_rw*/;
    reg [7:0]   data3[0:size/4 - 1] /*verilator public_flat_rw*/;

    initial begin
        for (int i = 0; i < size/4; i++) begin
            data0[i] = 8'd0;
            data1[i] = 8'd0;
            data2[i] = 8'd0;
            data3[i] = 8'd0;
        end

        if (initialize_mem) begin
            $readmemh(byte0, data0, 0);
            $readmemh(byte1, data1, 0);
            $readmemh(byte2, data2, 0);
            $readmemh(byte3, data3, 0);
        end
    end

    // Delay: hold an accepted request until its countdown runs out
    logic [15:0]    lfsr;
    logic           holding;
    logic [7:0]     delay_left;
    memory_io_req32 pending;
    memory_io_req32 mem_req;

    wire passthrough = (max_delay == 8'd0);

    wire can_accept = passthrough ? 1'b1 : (~holding & ~reset);
    wire accept_now = req.valid & can_accept;

    wire [7:0] this_delay = passthrough ? 8'd0 : (lfsr[7:0] % (max_delay + 8'd1));

    always_comb begin
        mem_req       = holding ? pending : req;
        mem_req.valid = (accept_now & (this_delay == 8'd0))
                      | (holding   & (delay_left == 8'd0));
    end

    always @(posedge clk) begin
        if (reset) begin
            lfsr       <= seed;
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

    // Storage: answers the cycle after mem_req
    memory_io_rsp32 rsp_q;

    always @(posedge clk) begin
        rsp_q <= memory_io_no_rsp32;
        if (mem_req.valid) begin
            rsp_q.user_tag <= mem_req.user_tag;
            if (is_any_byte32(mem_req.do_read)) begin
                rsp_q.addr <= mem_req.addr;
                rsp_q.valid <= 1'b1;
                rsp_q.data[7:0] <= data0[mem_req.addr[size_l2 - 1:2]];
                rsp_q.data[15:8] <= data1[mem_req.addr[size_l2 - 1:2]];
                rsp_q.data[23:16] <= data2[mem_req.addr[size_l2 - 1:2]];
                rsp_q.data[31:24] <= data3[mem_req.addr[size_l2 - 1:2]];
            end else if (is_any_byte32(mem_req.do_write)) begin
                rsp_q.addr <= mem_req.addr;
                rsp_q.valid <= 1'b1;
                if (mem_req.do_write[0]) data0[mem_req.addr[size_l2 - 1:2]] <= mem_req.data[7:0];
                if (mem_req.do_write[1]) data1[mem_req.addr[size_l2 - 1:2]] <= mem_req.data[15:8];
                if (mem_req.do_write[2]) data2[mem_req.addr[size_l2 - 1:2]] <= mem_req.data[23:16];
                if (mem_req.do_write[3]) data3[mem_req.addr[size_l2 - 1:2]] <= mem_req.data[31:24];
            end
        end
    end

    always_comb begin
        rsp       = rsp_q;
        rsp.ready = can_accept;
    end

`ifndef SYNTHESIS
    always @(posedge clk)
        if (!reset && req.valid && !can_accept)
            $error("%m: request presented while not ready (addr %08x)", req.addr);
`endif

endmodule
// verilator coverage_on

`endif
