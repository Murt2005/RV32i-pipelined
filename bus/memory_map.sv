`ifndef _memory_map_sv
`define _memory_map_sv

`include "system.sv"

// ---------------------------------------------------------------------------
// The address map, in one place.
//
// There was no address decoding anywhere in this design until now. Both
// memories simply discarded addr[31:16] and indexed from zero, and MMIO was a
// snoop on the request with a mux over the response one cycle later. That works
// exactly as long as there is one memory per port and it always answers in one
// cycle, and stops working the moment there is more than one target or any of
// them is slow.
//
//   0x0000_0000 - 0x0000_FFFF   unmapped. Reads return zero rather than
//                               aliasing onto real memory, so a null pointer
//                               dereference is inert instead of corrupting
//                               whatever lives at offset zero.
//   0x0001_0000 - 0x0001_FFFF   instruction memory, 64 KiB, one cycle
//   0x0002_0000 - 0x0002_FFBF   data memory, 64 KiB minus the MMIO block
//   0x0002_FFC0 - 0x0002_FFFF   MMIO, 64 bytes
//   0x1000_0000 - 0x1000_FFFF   framebuffer, 320x200x8bpp
//   0x8000_0000 - 0x83FF_FFFF   SDRAM, 64 MiB, cacheable
//
// The MMIO block is 64 bytes and not one byte larger. The stack top is
// 0x0002FFB0 and grows *down*, so anything that reaches below 0x0002FFC0 eats
// the top of the stack -- and this project has already been bitten once by the
// stack and the halt register sharing an address. 64 bytes starting at 0xFFC0
// is also exactly the alignment the riscv-tests `p` environment wants for its
// `.align 6` tohost.
//
// Keeping the two legacy regions at their old addresses *and* at one cycle is
// deliberate: ld.script, both riscv-tests linker scripts and the core's reset PC
// are unchanged, so the entire existing regression suite runs through the new
// decoder without taking a single extra cycle. That makes "the decoder changed
// nothing" a checkable claim rather than a hope.
// ---------------------------------------------------------------------------

// Region indices. Kept narrow because they are latched per outstanding access.
`define BUS_SEL_W       3
`define BUS_NONE        3'd0
`define BUS_IMEM        3'd1
`define BUS_DMEM        3'd2
`define BUS_MMIO        3'd3
`define BUS_FB          3'd4
`define BUS_SDRAM       3'd5

// MMIO registers, unchanged from what the board top already decoded so that
// every existing program and test keeps working.
`define MMIO_TOHOST     32'h0002_FFC0
`define MMIO_CYCLES     32'h0002_FFF0
`define MMIO_RETIRED    32'h0002_FFF4
`define MMIO_PUTCHAR    32'h0002_FFF8
`define MMIO_HALT       32'h0002_FFFC
// New: the loader writes a program into SDRAM through the data side, so the
// instruction cache has to be told to forget what it read from those lines
// before the core is released. Harmless when there is no cache. Placed in the
// gap between tohost/fromhost (0xFFC0..0xFFCF) and the counters at 0xFFF0.
`define MMIO_ICACHE_INV 32'h0002_FFD0
// A store here says "the framebuffer holds a complete frame". Nothing in the
// hardware needs it -- the VGA side scans out continuously -- but a simulation
// harness has no other way to know when a frame is worth capturing, and
// guessing from write activity would catch half-drawn ones.
`define MMIO_FRAME      32'h0002_FFD4
// Palette: writing {index[7:0], 8'b0, b, g, r} sets one entry. Doom changes the
// palette for damage flashes and item pickups, so this cannot be write-once.
`define MMIO_PALETTE    32'h0002_FFD8
// Keyboard. Reading pops one event: bit 31 says an event was there at all,
// bit 8 is press/release, bits 7:0 are the key. Reads-to-empty return zero, so
// a polling loop needs no separate "any pending" register.
`define MMIO_KEY        32'h0002_FFDC

function automatic logic [`BUS_SEL_W-1:0] bus_decode(logic [31:0] addr);
    // Ordered most specific first: the MMIO page sits inside the data region.
    if (addr[31:28] == 4'h8)
        return `BUS_SDRAM;
    else if (addr[31:16] == 16'h1000)
        return `BUS_FB;
    else if (addr[31:16] == 16'h0002)
        // Top 64 bytes only -- see the note above about the stack.
        return (addr[15:6] == 10'h3FF) ? `BUS_MMIO : `BUS_DMEM;
    else if (addr[31:16] == 16'h0001)
        return `BUS_IMEM;
    else
        return `BUS_NONE;
endfunction

`endif
