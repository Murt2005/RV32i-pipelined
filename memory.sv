`ifndef _memory_sv
`define _memory_sv

`include "system.sv"
`include "memory_io.sv"

module memory32 #(
    parameter size = 4096                       // in bytes
    ,parameter initialize_mem = 0
    ,parameter byte0 = "data0.hex"
    ,parameter byte1 = "data1.hex"
    ,parameter byte2 = "data2.hex"
    ,parameter byte3 = "data3.hex"
    ,parameter enable_rsp_addr = 1
    ) (
    input   clk
    ,input  reset

    ,input memory_io_req32  req
    ,output memory_io_rsp32 rsp
    );

    localparam size_l2 = $clog2(size);

    // Data memory
    reg [7:0]   data0[0:size/4 - 1];
    reg [7:0]   data1[0:size/4 - 1];
    reg [7:0]   data2[0:size/4 - 1];
    reg [7:0]   data3[0:size/4 - 1];

    initial begin
        // Vivado simulation fills the BRAM with X's and this makes a complete mess of
        // branch mis-predictions that come from the processor.
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

    always @(posedge clk) begin
        rsp <= memory_io_no_rsp32;
        if (req.valid) begin
            rsp.user_tag <= req.user_tag;
            if (is_any_byte32(req.do_read)) begin
                if (enable_rsp_addr)
                    rsp.addr <= req.addr;
                rsp.valid <= 1'b1;
                rsp.user_tag <= req.user_tag;
                rsp.data[7:0] <= data0[req.addr[size_l2 - 1:2]];
                rsp.data[15:8] <= data1[req.addr[size_l2 - 1:2]];
                rsp.data[23:16] <= data2[req.addr[size_l2 - 1:2]];
                rsp.data[31:24] <= data3[req.addr[size_l2 - 1:2]];
            end else if (is_any_byte32(req.do_write)) begin
                if (enable_rsp_addr)
                    rsp.addr <= req.addr;
                rsp.valid <= 1'b1;
                rsp.user_tag <= req.user_tag;
                if (req.do_write[0]) data0[req.addr[size_l2 - 1:2]] <= req.data[7:0];
                if (req.do_write[1]) data1[req.addr[size_l2 - 1:2]] <= req.data[15:8];
                if (req.do_write[2]) data2[req.addr[size_l2 - 1:2]] <= req.data[23:16];
                if (req.do_write[3]) data3[req.addr[size_l2 - 1:2]] <= req.data[31:24];
            end else begin
                rsp.valid <= 1'b0;
            end
        end
    end

endmodule


`ifdef __64bit__
`define memory memory64
`else
`define memory memory32
`endif

`endif
