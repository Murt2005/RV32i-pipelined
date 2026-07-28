`ifndef _bus_arbiter_sv
`define _bus_arbiter_sv

`include "system.sv"
`include "memory_io.sv"

// ---------------------------------------------------------------------------
// Two initiators, one target. The instruction and data sides both reach SDRAM,
// and SDRAM is one device.
//
// Two constraints shape this, and they pull in opposite directions.
//
// 1. Every port's `ready` must depend only on registers -- not on the address,
//    not on the other port's request. A decoder that answers ready for whichever
//    target the current address selects makes ready a function of the request,
//    and the core derives its request valid from ready. The value path is
//    harmless, since only the address is read, but a packed struct is one vector
//    and every tool sees the whole request feeding the decode. Verilator names
//    the cycle; Icarus just stops finishing.
//
// 2. The grant must not add a cycle. Fetch's stall for a slow instruction memory
//    holds one extra cycle across the arrival of a late response and re-fetches
//    it -- correct, and necessary, but it assumes the retry can be answered in a
//    single cycle. Against a target that is *always* slower than that, the retry
//    is late too, gets dropped again, and the sequence repeats identically
//    forever. A buffered grant costs exactly that extra cycle and turns fetching
//    from SDRAM into a deterministic livelock. It is not a hang the watchdog
//    explains: the machine is busy, fetching the same address forever.
//
// So the grant is combinational -- an idle bus forwards the request in the same
// cycle -- while `ready` is built only from registers and from the target's own
// registered response. `turn` stays with the port that is using the bus rather
// than rotating on every grant, so a stream of accesses runs at full rate and,
// critically, `ready` is high on the cycle the response comes back. Rotating on
// grant would drop the response for the same reason a buffered grant does.
//
// Fairness: the turn passes on any idle cycle the holder does not use it, so a
// port that goes quiet yields within a cycle and starvation is impossible by
// construction rather than by a counter -- which also leaves `liveness` nothing
// to trip over.
// ---------------------------------------------------------------------------
module bus_arbiter(
    input  logic clk,
    input  logic reset,

    input  memory_io_req  a_req,      // data side
    output memory_io_rsp  a_rsp,
    input  memory_io_req  b_req,      // instruction side
    output memory_io_rsp  b_rsp,

    output memory_io_req  t_req,
    input  memory_io_rsp  t_rsp
);

logic turn;      // whose offer it is
logic busy;      // an access is in flight to the target
logic owner;     // who it belongs to

// The bus is free either when nothing is in flight, or on the very cycle the
// outstanding access completes. Including the completion cycle is what lets a
// stream of accesses run at one per cycle, and what keeps ready high on the
// cycle a response arrives -- without it, fetch's stretch drops that response.
wire free = ~busy | t_rsp.valid;

wire a_ready = (turn == 1'b0) & free & t_rsp.ready;
wire b_ready = (turn == 1'b1) & free & t_rsp.ready;

wire a_take = a_req.valid & a_ready;
wire b_take = b_req.valid & b_ready;

// Combinational grant: an idle bus forwards the request the same cycle, so the
// target's latency is all the initiator sees.
always_comb begin
    t_req       = (turn == 1'b0) ? a_req : b_req;
    t_req.valid = a_take | b_take;
end

// Deliberately separate from the block above, which reads a_req and b_req.
// Combined, the block driving a_rsp would be sensitive to a_req -- and a_req's
// valid comes from a_rsp.ready, which closes an event loop and wedges the
// simulator in zero time with nothing ever changing.
always_comb begin
    a_rsp       = t_rsp;
    a_rsp.valid = t_rsp.valid & busy & (owner == 1'b0);
    a_rsp.ready = a_ready;

    b_rsp       = t_rsp;
    b_rsp.valid = t_rsp.valid & busy & (owner == 1'b1);
    b_rsp.ready = b_ready;
end

always_ff @(posedge clk) begin
    if (reset) begin
        turn  <= 1'b0;
        busy  <= 1'b0;
        owner <= 1'b0;
    end else begin
        if (a_take | b_take) begin
            busy  <= 1'b1;
            owner <= b_take;
            // The turn stays with whoever is using the bus.
        end else if (t_rsp.valid)
            busy <= 1'b0;

        // Idle and unused: offer it to the other side next cycle.
        if (free & ~(a_take | b_take))
            turn <= ~turn;
    end
end

`ifndef SYNTHESIS
always @(posedge clk)
    if (!reset && t_rsp.valid && !busy)
        $error("%m: target answered with nothing outstanding");
`endif

endmodule

`endif
