// 64 KiB framebuffer in dual-clock M10K: the CPU writes port A, scanout reads port B
// Board builds only; simulation uses the memory in top.sv

`include "system.sv"
`include "memory_io.sv"

module fb_ram #(
    parameter int bytes = 32'h0001_0000
) (
    // Port A: the CPU
    input  logic          clk,
    input  logic          reset,
    input  memory_io_req  req,
    output memory_io_rsp  rsp,

    // Port B: scanout, byte address, one cycle of latency
    input  logic          rd_clk,
    input  logic [16:0]   rd_addr,
    output logic [7:0]    rd_data
);

    localparam int WORDS = bytes / 4;
    localparam int AW    = $clog2(WORDS);

    (* ramstyle = "M10K" *) reg [7:0] data0 [0:WORDS-1];
    (* ramstyle = "M10K" *) reg [7:0] data1 [0:WORDS-1];
    (* ramstyle = "M10K" *) reg [7:0] data2 [0:WORDS-1];
    (* ramstyle = "M10K" *) reg [7:0] data3 [0:WORDS-1];

    // Starts black rather than random
    initial begin
        for (int i = 0; i < WORDS; i++) begin
            data0[i] = 8'd0; data1[i] = 8'd0;
            data2[i] = 8'd0; data3[i] = 8'd0;
        end
    end

    wire [AW-1:0] a = req.addr[AW-1:0];

    // Port A: always ready, one-cycle response like memory.sv
    logic                          rsp_valid_r;
    logic [`word_address_size-1:0] rsp_addr_r;
    logic [31:0]                   rsp_data_r;

    always_ff @(posedge clk) begin
        if (reset) begin
            rsp_valid_r <= 1'b0;
        end else begin
            rsp_valid_r <= req.valid
                         & (is_any_byte(req.do_read) | is_any_byte(req.do_write));
            rsp_addr_r  <= req.addr;

            if (req.valid && is_any_byte(req.do_read)) begin
                rsp_data_r[7:0]   <= data0[a];
                rsp_data_r[15:8]  <= data1[a];
                rsp_data_r[23:16] <= data2[a];
                rsp_data_r[31:24] <= data3[a];
            end

            if (req.valid) begin
                if (req.do_write[0]) data0[a] <= req.data[7:0];
                if (req.do_write[1]) data1[a] <= req.data[15:8];
                if (req.do_write[2]) data2[a] <= req.data[23:16];
                if (req.do_write[3]) data3[a] <= req.data[31:24];
            end
        end
    end

    always_comb begin
        rsp       = memory_io_no_rsp;
        rsp.ready = 1'b1;
        rsp.valid = rsp_valid_r;
        rsp.addr  = rsp_addr_r;
        rsp.data  = rsp_data_r;
    end

    // Port B: bits [1:0] pick the byte lane
    always_ff @(posedge rd_clk) begin
        case (rd_addr[1:0])
            2'd0: rd_data <= data0[rd_addr[AW+1:2]];
            2'd1: rd_data <= data1[rd_addr[AW+1:2]];
            2'd2: rd_data <= data2[rd_addr[AW+1:2]];
            2'd3: rd_data <= data3[rd_addr[AW+1:2]];
        endcase
    end

endmodule
