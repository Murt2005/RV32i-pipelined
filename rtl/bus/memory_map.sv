`ifndef _memory_map_sv
`define _memory_map_sv

`include "system.sv"

//   0x0000_0000 - 0x0000_FFFF   unmapped
//   0x0001_0000 - 0x0001_FFFF   instruction memory, 64 KiB, one cycle
//   0x0002_0000 - 0x0002_FFBF   data memory, 64 KiB minus the MMIO block
//   0x0002_FFC0 - 0x0002_FFFF   MMIO, 64 bytes
//   0x1000_0000 - 0x1000_FFFF   framebuffer, 320x200x8bpp
//   0x8000_0000 - 0x83FF_FFFF   SDRAM, 64 MiB, cacheable

`define BUS_SEL_W       3
`define BUS_NONE        3'd0
`define BUS_IMEM        3'd1
`define BUS_DMEM        3'd2
`define BUS_MMIO        3'd3
`define BUS_FB          3'd4
`define BUS_SDRAM       3'd5

`define MMIO_TOHOST     32'h0002_FFC0
`define MMIO_CYCLES     32'h0002_FFF0
`define MMIO_RETIRED    32'h0002_FFF4
`define MMIO_PUTCHAR    32'h0002_FFF8
`define MMIO_HALT       32'h0002_FFFC
`define MMIO_ICACHE_INV 32'h0002_FFD0
`define MMIO_FRAME      32'h0002_FFD4
`define MMIO_PALETTE    32'h0002_FFD8
`define MMIO_KEY        32'h0002_FFDC

function automatic logic [`BUS_SEL_W-1:0] bus_decode(logic [31:0] addr);
    if (addr[31:28] == 4'h8)
        return `BUS_SDRAM;
    else if (addr[31:16] == 16'h1000)
        return `BUS_FB;
    else if (addr[31:16] == 16'h0002)
        return (addr[15:6] == 10'h3FF) ? `BUS_MMIO : `BUS_DMEM;
    else if (addr[31:16] == 16'h0001)
        return `BUS_IMEM;
    else
        return `BUS_NONE;
endfunction

`endif
