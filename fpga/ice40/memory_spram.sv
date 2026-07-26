`ifndef _memory_spram_sv
`define _memory_spram_sv

`include "system.sv"
`include "memory_io.sv"

// ---------------------------------------------------------------------------
// 64 KiB memory with the same memory_io interface as memory32, backed by two
// SB_SPRAM256KA hard blocks instead of an inferred array.
//
// Why SPRAM rather than block RAM:
//   * The UP5K has only 30 x 4 Kbit BRAM = 15 KiB total, which cannot hold the
//     64 KiB instruction + 64 KiB data image the memory map assumes.
//   * It has 4 x 256 Kbit SPRAM = 128 KiB, exactly enough for both, so the
//     board build keeps the simulator's memory map bit for bit.
//   * SPRAM cannot be initialised at configuration time -- but this design
//     loads programs over the UART at run time, so no initialisation is needed.
//     That also leaves all 30 BRAMs free.
//
// One SPRAM is 16384 x 16. Two side by side give 16384 x 32 = 64 KiB, indexed
// by addr[15:2]. MASKWREN is per *nibble*, so each byte lane needs two bits.
//
// Timing matches memory32 exactly: a request presented in cycle N produces
// rsp.valid and rsp.data in cycle N+1.
// ---------------------------------------------------------------------------

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

    // Byte lane i lives at bits [8i+7:8i], i.e. two MASKWREN nibbles each.
    SB_SPRAM256KA spram_lo (
        .ADDRESS    (word_addr),
        .DATAIN     (req.data[15:0]),
        .MASKWREN   ({{2{req.do_write[1]}}, {2{req.do_write[0]}}}),
        .WREN       (req.valid & do_wr),
        .CHIPSELECT (active),
        .CLOCK      (clk),
        .STANDBY    (1'b0),
        .SLEEP      (1'b0),
        .POWEROFF   (1'b1),          // active low: 1 means powered up
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

    // Response bookkeeping, registered so it lands alongside DATAOUT.
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
