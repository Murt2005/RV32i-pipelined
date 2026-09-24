`ifndef _mmio_sv
`define _mmio_sv

`include "system.sv"
`include "memory-io.sv"
`include "memory-map.sv"

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

    output logic        icache_invalidate
);

wire selected = req.valid & (is_any_byte(req.do_read) | is_any_byte(req.do_write));
wire is_write = selected & is_any_byte(req.do_write);

wire accept = selected;

logic [31:0] rd_value;

always_comb begin
    case (req.addr)
        `MMIO_CYCLES:  rd_value = perf_cycles;
        `MMIO_RETIRED: rd_value = perf_retired;
        default:       rd_value = 32'd0;
    endcase
end

always_comb begin
    putchar_valid     = is_write & (req.addr == `MMIO_PUTCHAR);
    putchar_data      = req.data[7:0];
    tohost_valid      = is_write & (req.addr == `MMIO_TOHOST);
    tohost_data       = req.data;
    icache_invalidate = is_write & (req.addr == `MMIO_ICACHE_INV);
end

always_ff @(posedge clk) begin
    if (reset) begin
        rsp        <= memory_io_no_rsp;
        halt_pulse <= 1'b0;
    end else begin
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
