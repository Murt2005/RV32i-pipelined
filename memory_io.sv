`ifndef _memory_io_
`define _memory_io_
`include "system.sv"

// ---------------------------------------------------------------------------
// memory_io: the request/response contract between the core and a memory-like
// target (a RAM, an MMIO block, a cache, a bus decoder).
//
// Historically every target answered in exactly one cycle and always accepted,
// so the protocol was never written down: `ready` was tied high and `valid`
// arrived on cycle N+1 without exception. A cache backed by external DRAM
// cannot do either, so the contract is stated here explicitly. It is deliberately
// expressed in the fields that already exist rather than new ones -- the MMIO
// response mux in top.sv and fpga/ice40/rv32_top.sv muxes the whole struct, and
// a signal carried outside it would drift out of sync with the response it
// describes.
//
//   req.valid   The initiator is presenting a request this cycle.
//
//   rsp.ready   The target can accept a request this cycle. MUST be a registered
//               output of the target: it feeds back into req.valid (see fetch,
//               cpu.sv), so a combinational dependency on the live request closes
//               a loop through the target.
//
//               A request is *accepted* on a cycle where req.valid & rsp.ready.
//
//   rsp.valid   The response to the oldest accepted request. Asserted exactly
//               once per accepted request, at least one cycle after acceptance,
//               with no upper bound. rsp.data is only meaningful on that cycle.
//
//   rsp.addr    Echoes the address of the request being answered, so an initiator
//               can tell which request a late response belongs to. Optional in
//               principle, but fetch relies on it to discard responses for
//               addresses it no longer wants.
//
//   req.user_tag / rsp.user_tag
//               Carried end to end, echoed by the target. Currently tied to zero
//               by the core. The extension point for more than one outstanding
//               request; nothing in the contract above permits that yet.
//
// The two existing targets, memory32 (memory.sv) and memory_spram
// (fpga/ice40/memory_spram.sv), satisfy this as written: both can always accept,
// so a constant ready is correct, and both answer in exactly one cycle, which is
// the minimum the contract allows.
// ---------------------------------------------------------------------------

typedef struct packed {
    logic [`word_address_size-1:0]    addr;
    logic [31:0]    data;
    logic [3:0]     do_read;
    logic [3:0]     do_write;
    logic           valid;
    logic [2:0]     dummy;
    logic [`user_tag_size-1:0] user_tag;
}   memory_io_req32;

localparam memory_io_no_req32 = { {(`word_address_size){1'b0}}, 32'b0, 4'b0, 4'b0, 1'b0, 3'b000, {(`user_tag_size){1'b0}} };

typedef struct packed {
    logic [`word_address_size-1:0]    addr;
    logic [31:0]    data;
    logic           valid;
    logic           ready;
    logic [1:0]     dummy;
    logic [`user_tag_size - 1:0] user_tag;
}   memory_io_rsp32;

localparam memory_io_no_rsp32 = { {(`word_address_size){1'b0}}, 32'd0, 1'b0, 1'b1, 2'b00, {(`user_tag_size){1'b0}} };

`define whole_word32  4'b1111

function automatic logic is_whole_word32(logic [3:0] control);
    return control[0] & control[1] & control[2] & control[3];
endfunction

function automatic logic is_any_byte32(logic [3:0] control);
    return control[0] | control[1] | control[2] | control[3];
endfunction


typedef memory_io_req32     memory_io_req;
typedef memory_io_rsp32     memory_io_rsp;
localparam memory_io_no_req = memory_io_no_req32;
localparam memory_io_no_rsp = memory_io_no_rsp32;
function automatic logic is_any_byte(logic [3:0] control);
    return is_any_byte32(control);
endfunction
function automatic logic is_whole_word(logic [3:0] control);
    return is_whole_word32(control);
endfunction


`endif
