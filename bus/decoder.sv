`ifndef _bus_decoder_sv
`define _bus_decoder_sv

`include "system.sv"
`include "memory_io.sv"
`include "bus/memory_map.sv"

// ---------------------------------------------------------------------------
// Address decode and response steering for one initiator port.
//
// Routing a request is the easy half: decode the address, present the request
// to that target and to no other. Steering the response back is the half that
// needs state, because a response no longer arrives in a known cycle -- so the
// selected target is latched when the request is *accepted* and the response
// muxed on that latch rather than on the current address.
//
// One outstanding access is all the core is permitted, which is why a single
// latched selector is enough. If that ever changes, this becomes a queue and
// the memory_io user_tag field is what it would be keyed on.
//
// Unmapped addresses answer in one cycle with zero rather than being dropped.
// A dropped response would hang the pipeline, and hanging is a much worse
// symptom than reading zero for something like a null dereference.
// ---------------------------------------------------------------------------
module bus_decoder #(
    // One bit per BUS_* index: which targets this port actually has. A region
    // that is not present decodes as unmapped, which answers in one cycle with
    // zero. Without this an instruction fetch that strayed into, say, the MMIO
    // range would select a target whose response is tied off, and the pipeline
    // would wait for it forever -- a hang, where the whole point of the unmapped
    // case is that nothing hangs.
    parameter logic [7:0] present = 8'hFF
) (
    input  logic clk,
    input  logic reset,

    input  memory_io_req  cpu_req,
    output memory_io_rsp  cpu_rsp,

    output memory_io_req  imem_req,
    input  memory_io_rsp  imem_rsp,
    output memory_io_req  dmem_req,
    input  memory_io_rsp  dmem_rsp,
    output memory_io_req  mmio_req,
    input  memory_io_rsp  mmio_rsp,
    output memory_io_req  fb_req,
    input  memory_io_rsp  fb_rsp,
    output memory_io_req  sdram_req,
    input  memory_io_rsp  sdram_rsp
);

wire [`BUS_SEL_W-1:0] raw_sel = bus_decode(cpu_req.addr);
wire [`BUS_SEL_W-1:0] sel     = present[raw_sel] ? raw_sel : `BUS_NONE;

// Which target is ready for the address currently being presented. This is
// combinational on the address, which is fine: the address does not depend on
// ready, so there is no loop, and each target's own ready is registered.
logic sel_ready;
always_comb begin
    case (sel)
        `BUS_IMEM:  sel_ready = imem_rsp.ready;
        `BUS_DMEM:  sel_ready = dmem_rsp.ready;
        `BUS_MMIO:  sel_ready = mmio_rsp.ready;
        `BUS_FB:    sel_ready = fb_rsp.ready;
        `BUS_SDRAM: sel_ready = sdram_rsp.ready;
        default:    sel_ready = 1'b1;          // unmapped, always accepts
    endcase
end

wire accepted = cpu_req.valid & sel_ready;

// Present the request only to the selected target.
always_comb begin
    imem_req  = cpu_req;  imem_req.valid  = cpu_req.valid & (sel == `BUS_IMEM);
    dmem_req  = cpu_req;  dmem_req.valid  = cpu_req.valid & (sel == `BUS_DMEM);
    mmio_req  = cpu_req;  mmio_req.valid  = cpu_req.valid & (sel == `BUS_MMIO);
    fb_req    = cpu_req;  fb_req.valid    = cpu_req.valid & (sel == `BUS_FB);
    sdram_req = cpu_req;  sdram_req.valid = cpu_req.valid & (sel == `BUS_SDRAM);
end

// The target that owns the outstanding access, and a one-cycle answer for the
// unmapped case which has no target to produce one.
logic [`BUS_SEL_W-1:0] sel_q;
logic                  none_valid_q;
logic [`word_address_size-1:0] none_addr_q;

// Accepts are latched even while reset is asserted. Fetch drives its request
// valid without regard to reset, so a request really does go out during reset
// and a target really does answer it -- and a steering latch that ignored that
// would drop the answer, leaving the core waiting on a response that already
// came and going. That costs a cycle at best and, once anything downstream
// tracks outstanding accesses, looks like a lost request.
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
        `BUS_FB:    cpu_rsp = fb_rsp;
        `BUS_SDRAM: cpu_rsp = sdram_rsp;
        default: begin
            cpu_rsp       = memory_io_no_rsp;
            cpu_rsp.valid = none_valid_q;
            cpu_rsp.addr  = none_addr_q;
        end
    endcase
    // ready always describes the target being addressed *now*, not the one
    // answering. They are different whenever a new request is presented while
    // the previous response is still coming back.
    cpu_rsp.ready = sel_ready;
end

endmodule

`endif
