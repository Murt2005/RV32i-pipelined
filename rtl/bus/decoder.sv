`ifndef _bus_decoder_sv
`define _bus_decoder_sv

`include "system.sv"
`include "memory_io.sv"
`include "memory_map.sv"

// Address decode and response steering for one initiator port
module bus_decoder #(
    parameter logic [7:0] present = 8'hFF
) (
    input  logic clk,
    input  logic reset,

    input  memory_io_req  cpu_req,
    input  logic [31:0]   cpu_addr,
    output memory_io_rsp  cpu_rsp,

    output memory_io_req  imem_req,
    input  memory_io_rsp  imem_rsp,
    output memory_io_req  dmem_req,
    input  memory_io_rsp  dmem_rsp,
    output memory_io_req  mmio_req,
    input  memory_io_rsp  mmio_rsp,
    output memory_io_req  sdram_req,
    input  memory_io_rsp  sdram_rsp
);

wire [`BUS_SEL_W-1:0] raw_sel = bus_decode(cpu_addr);
wire [`BUS_SEL_W-1:0] sel     = present[raw_sel] ? raw_sel : `BUS_NONE;

logic all_ready;
always_comb begin
    case (sel)
        `BUS_IMEM:  all_ready = imem_rsp.ready;
        `BUS_DMEM:  all_ready = dmem_rsp.ready;
        `BUS_MMIO:  all_ready = mmio_rsp.ready;
        `BUS_SDRAM: all_ready = sdram_rsp.ready;
        default:    all_ready = 1'b1;
    endcase
end

wire accepted = cpu_req.valid & all_ready;

always_comb begin
    imem_req  = cpu_req;  imem_req.valid  = cpu_req.valid & (sel == `BUS_IMEM);
    dmem_req  = cpu_req;  dmem_req.valid  = cpu_req.valid & (sel == `BUS_DMEM);
    mmio_req  = cpu_req;  mmio_req.valid  = cpu_req.valid & (sel == `BUS_MMIO);
    sdram_req = cpu_req;  sdram_req.valid = cpu_req.valid & (sel == `BUS_SDRAM);
end

logic [`BUS_SEL_W-1:0] sel_q;
logic                  none_valid_q;
logic [`word_address_size-1:0] none_addr_q;

always_ff @(posedge clk) begin
    if (accepted) begin
        sel_q       <= sel;
        none_addr_q <= cpu_req.addr;
    end else if (reset)
        sel_q <= `BUS_NONE;

    none_valid_q <= accepted & (sel == `BUS_NONE);
end

always_comb begin
    case (sel_q)
        `BUS_IMEM:  cpu_rsp = imem_rsp;
        `BUS_DMEM:  cpu_rsp = dmem_rsp;
        `BUS_MMIO:  cpu_rsp = mmio_rsp;
        `BUS_SDRAM: cpu_rsp = sdram_rsp;
        default: begin
            cpu_rsp       = memory_io_no_rsp;
            cpu_rsp.valid = none_valid_q;
            cpu_rsp.addr  = none_addr_q;
        end
    endcase
    cpu_rsp.ready = all_ready;
end

endmodule

`endif
