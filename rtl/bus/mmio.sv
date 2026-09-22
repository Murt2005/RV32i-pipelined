`ifndef _mmio_sv
`define _mmio_sv

`include "system.sv"
`include "memory_io.sv"
`include "memory_map.sv"

module mmio(
    input  logic clk,
    input  logic reset,

    input  memory_io_req  req,
    output memory_io_rsp  rsp,

    input  logic [31:0] perf_cycles,
    input  logic [31:0] perf_retired,

    output logic        putchar_valid,
    output logic [7:0]  putchar_data,

    output logic        halt_pulse,

    output logic        tohost_valid,
    output logic [31:0] tohost_data,

    output logic        icache_invalidate,

    output logic        frame_valid,

    output logic        palette_valid,
    output logic [7:0]  palette_index,
    output logic [23:0] palette_rgb,

    input  logic        key_strobe,
    input  logic [8:0]  key_event      // [8] pressed, [7:0] code
);

wire selected = req.valid & (is_any_byte(req.do_read) | is_any_byte(req.do_write));
wire is_write = selected & is_any_byte(req.do_write);

wire accept = selected;

logic [8:0] key_q [0:3];
logic [2:0] key_wr, key_rd;
wire        key_empty = (key_wr == key_rd);
wire        key_pop   = selected & ~is_write & (req.addr == `MMIO_KEY) & ~key_empty;

logic [31:0] rd_value;

always_comb begin
    case (req.addr)
        `MMIO_CYCLES:  rd_value = perf_cycles;
        `MMIO_RETIRED: rd_value = perf_retired;
        // Bit 31 distinguishes "no event" from "release of key 0".
        `MMIO_KEY:     rd_value = key_empty ? 32'd0
                                : {1'b1, 22'd0, key_q[key_rd[1:0]]};
        default:       rd_value = 32'd0;
    endcase
end

always_comb begin
    putchar_valid     = is_write & (req.addr == `MMIO_PUTCHAR);
    putchar_data      = req.data[7:0];
    tohost_valid      = is_write & (req.addr == `MMIO_TOHOST);
    tohost_data       = req.data;
    icache_invalidate = is_write & (req.addr == `MMIO_ICACHE_INV);
    frame_valid       = is_write & (req.addr == `MMIO_FRAME);
    palette_valid     = is_write & (req.addr == `MMIO_PALETTE);
    palette_index     = req.data[31:24];
    palette_rgb       = req.data[23:0];
end

always_ff @(posedge clk) begin
    if (reset) begin
        rsp        <= memory_io_no_rsp;
        halt_pulse <= 1'b0;
        key_wr     <= 3'd0;
        key_rd     <= 3'd0;
    end else begin
        if (key_strobe) begin
            key_q[key_wr[1:0]] <= key_event;
            key_wr             <= key_wr + 3'd1;
        end
        if (key_pop)
            key_rd <= key_rd + 3'd1;

        rsp        <= memory_io_no_rsp;
        halt_pulse <= is_write & ((req.addr == `MMIO_HALT)
                                | (req.addr == `MMIO_TOHOST));

        if (accept) begin
            rsp.valid    <= 1'b1;
            rsp.addr     <= req.addr;
            rsp.user_tag <= req.user_tag;
            rsp.data     <= rd_value;
        end
    end
end
endmodule

`endif
