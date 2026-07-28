`ifndef _mmio_sv
`define _mmio_sv

`include "system.sv"
`include "memory_io.sv"
`include "bus/memory_map.sv"

// ---------------------------------------------------------------------------
// The memory-mapped registers, as a real bus target.
//
// These used to be a snoop: the board top watched data_mem_req go past, acted
// on it, and muxed a value over the data memory's response exactly one cycle
// later. That works only while the response is always exactly one cycle later,
// which stopped being true the moment the memory could be slow. Here the
// registers answer for themselves, at their own pace, like any other target.
//
// Effects are edge-shaped, not level-shaped: putchar and halt pulse for a single
// cycle when the write is accepted, so a caller cannot see one write twice even
// if the request stays asserted. The board top turns those pulses into a UART
// byte; the simulation top turns them into $write.
//
// Reads of an unimplemented register return zero rather than trapping. There is
// no bus-error mechanism in this design and inventing one here would be the
// wrong place for it.
// ---------------------------------------------------------------------------
module mmio(
    input  logic clk,
    input  logic reset,

    input  memory_io_req  req,
    output memory_io_rsp  rsp,

    // Free-running counters owned by the top, sampled at request time.
    input  logic [31:0] perf_cycles,
    input  logic [31:0] perf_retired,

    // One-cycle effects.
    output logic        putchar_valid,
    output logic [7:0]  putchar_data,
    output logic        halt_pulse,
    output logic        tohost_valid,
    output logic [31:0] tohost_data,
    output logic        icache_invalidate,
    // A frame has been completed in the framebuffer.
    output logic        frame_valid,
    // Palette write: index and 24-bit colour.
    output logic        palette_valid,
    output logic [7:0]  palette_index,
    output logic [23:0] palette_rgb
);

wire selected = req.valid & (is_any_byte(req.do_read) | is_any_byte(req.do_write));
wire is_write = selected & is_any_byte(req.do_write);

// Always able to accept: these are registers, not memory behind a controller.
// rsp.ready comes out of memory_io_no_rsp, which has it set, and nothing below
// ever clears it -- so it is a constant, which trivially satisfies the contract's
// requirement that it not depend on the live request.
wire accept = selected;

logic [31:0] rd_value;

always_comb begin
    case (req.addr)
        `MMIO_CYCLES:  rd_value = perf_cycles;
        `MMIO_RETIRED: rd_value = perf_retired;
        default:       rd_value = 32'd0;
    endcase
end

// Observable side effects fire in the same cycle the write is accepted; only
// `halt` is registered. That split is not arbitrary, and getting it wrong loses
// output: halt reaches the testbench a cycle after the store, and the testbench
// calls $finish on the *negedge* of that cycle. Anything the top prints by
// sampling a registered pulse would therefore be scheduled for the following
// posedge, which never arrives -- the run has already ended. Registering the
// tohost pulse cost exactly that, and every riscv-tests `p` result vanished
// while the tests themselves still passed.
//
// The request is asserted for a single cycle (the memory stage issues once and
// advances), so these are one-cycle pulses despite being combinational.
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
    end else begin
        rsp        <= memory_io_no_rsp;
        // A store to either address stops the machine. tohost is how the stock
        // riscv-tests `p` environment reports its result, and it then spins
        // forever, so without halting on it the watchdog would be the only thing
        // that ended the run and the result would be lost.
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
