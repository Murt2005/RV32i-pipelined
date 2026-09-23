`ifndef _memory_spram_sv
`define _memory_spram_sv

`include "system.sv"
`include "memory_io.sv"

// 64 KiB memory from two SPRAM blocks, since the UP5K's block RAM is too small.
// Same interface and one-cycle timing as memory32

module memory_spram #(
    parameter enable_rsp_addr = 1
) (
    input  logic            clk,
    input  logic            reset,

    input  memory_io_req32  req,
    output memory_io_rsp32  rsp
);

    logic [13:0] word_addr;
    logic        do_rd, do_wr, active;

    assign word_addr = req.addr[15:2];
    assign do_rd     = is_any_byte32(req.do_read);
    assign do_wr     = is_any_byte32(req.do_write);
    assign active    = req.valid & (do_rd | do_wr);

    logic [15:0] dout_lo, dout_hi;

    // MASKWREN is per nibble, so each byte needs two bits
    SB_SPRAM256KA spram_lo (
        .ADDRESS    (word_addr),
        .DATAIN     (req.data[15:0]),
        .MASKWREN   ({{2{req.do_write[1]}}, {2{req.do_write[0]}}}),
        .WREN       (req.valid & do_wr),
        .CHIPSELECT (active),
        .CLOCK      (clk),
        .STANDBY    (1'b0),
        .SLEEP      (1'b0),
        .POWEROFF   (1'b1),          // active low
        .DATAOUT    (dout_lo)
    );

    SB_SPRAM256KA spram_hi (
        .ADDRESS    (word_addr),
        .DATAIN     (req.data[31:16]),
        .MASKWREN   ({{2{req.do_write[3]}}, {2{req.do_write[2]}}}),
        .WREN       (req.valid & do_wr),
        .CHIPSELECT (active),
        .CLOCK      (clk),
        .STANDBY    (1'b0),
        .SLEEP      (1'b0),
        .POWEROFF   (1'b1),
        .DATAOUT    (dout_hi)
    );

    logic [`word_address_size-1:0] rsp_addr_r;
    logic                          rsp_valid_r;
    logic [`user_tag_size-1:0]     rsp_tag_r;

    always_ff @(posedge clk) begin
        if (reset) begin
            rsp_valid_r <= 1'b0;
            rsp_addr_r  <= '0;
            rsp_tag_r   <= '0;
        end else begin
            rsp_valid_r <= active;
            rsp_tag_r   <= req.user_tag;
            if (active)
                rsp_addr_r <= req.addr;
        end
    end

    always_comb begin
        rsp          = memory_io_no_rsp32;
        rsp.addr     = enable_rsp_addr ? rsp_addr_r : '0;
        rsp.data     = {dout_hi, dout_lo};
        rsp.valid    = rsp_valid_r;
        rsp.ready    = 1'b1;
        rsp.user_tag = rsp_tag_r;
    end

endmodule

`endif
