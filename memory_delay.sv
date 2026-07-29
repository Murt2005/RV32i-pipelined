`ifndef _memory_delay_sv
`define _memory_delay_sv

`include "system.sv"
`include "memory_io.sv"
`include "memory.sv"

// ---------------------------------------------------------------------------
// A memory32 that does not answer in one cycle. Simulation only.
//
// This exists so the pipeline's stall paths can be exercised long before there
// is a cache or an SDRAM controller to exercise them with. Simulation is by far
// the cheapest place to find the bugs those paths contain, and every one of them
// is invisible against the single-cycle memories the core has always had.
//
// It models the two things a real cache does that memory32 does not:
//
//   * refuses a request  -- rsp.ready drops while an access is being held,
//                           which is what a cache does during a line fill.
//   * answers late       -- rsp.valid comes back max_delay+1 cycles after the
//                           request was accepted, where the delay is drawn per
//                           access from an LFSR.
//
// The access is genuinely deferred, not just its response: the request is held
// and only presented to the real memory when the countdown expires, so a store
// lands at the time the response claims it did.
//
// max_delay = 0 is a pure passthrough, bit-for-bit memory32, so this can sit in
// the design permanently and be turned on per run. The delay is random rather
// than fixed because a constant latency lets the pipeline settle into one
// repeating pattern, and the failures worth finding are interactions -- a miss
// landing on the cycle a branch resolves, or on the cycle an external stall
// lifts. Same reasoning as the existing stall injection, and the two are meant
// to be run together.
//
// Holds exactly one access. The core is allowed one outstanding request per
// port, and refusing a second is how that gets checked rather than tolerated.
// ---------------------------------------------------------------------------
// verilator coverage_off
// This is a test fixture, not part of the design. Its points would otherwise be
// counted in the coverage figure and quietly dilute it -- the number is supposed
// to say how much of the core the tests reach.
module memory_delay #(
    parameter size = 4096
    ,parameter initialize_mem = 0
    ,parameter byte0 = "data0.hex"
    ,parameter byte1 = "data1.hex"
    ,parameter byte2 = "data2.hex"
    ,parameter byte3 = "data3.hex"
    ,parameter enable_rsp_addr = 1
    ) (
    input   clk
    ,input  reset
    ,input  [7:0] max_delay          // extra cycles beyond the base 1; 0 = passthrough

    ,input memory_io_req32  req
    ,output memory_io_rsp32 rsp
    );

    memory_io_req32 inner_req;
    memory_io_rsp32 inner_rsp;

    memory32 #(
        .size(size)
        ,.initialize_mem(initialize_mem)
        ,.byte0(byte0)
        ,.byte1(byte1)
        ,.byte2(byte2)
        ,.byte3(byte3)
        ,.enable_rsp_addr(enable_rsp_addr)
    ) mem (
        .clk(clk)
        ,.reset(reset)
        ,.req(inner_req)
        ,.rsp(inner_rsp)
    );

    // Free-running, so the delay an access gets does not correlate with the
    // access itself. Seeding off the address would make the pattern repeat in
    // lockstep with whatever loop the access sits in.
    logic [15:0] lfsr;

    logic           holding;      // an accepted access is waiting out its delay
    logic [7:0]     delay_left;
    memory_io_req32 pending;

    wire passthrough = (max_delay == 8'd0);

    // ready is a registered output, as the memory_io contract requires: it is a
    // function of `holding` and reset, never of the live request.
    //
    // Refusing during reset matters once an access can be held. Fetch drives its
    // request valid without regard to reset, so requests do go out while reset is
    // asserted; the stateless memory32 answered them harmlessly, but anything
    // that holds an access swallows them and then looks like it lost a request.
    //
    // Passthrough has to be exempt, and exactly so. memory32 has no reset input
    // and accepts during reset, so refusing there would delay the very first
    // fetch by a cycle -- which showed up as every single test taking one extra
    // cycle, in a gate whose entire value is that it is exact.
    wire can_accept = passthrough ? 1'b1 : (~holding & ~reset);
    wire accept_now = req.valid & can_accept;

    wire [7:0] this_delay = passthrough ? 8'd0 : (lfsr[7:0] % (max_delay + 8'd1));

    // Present the held access once its countdown reaches zero; otherwise pass a
    // zero-delay access straight through.
    always_comb begin
        inner_req       = holding ? pending : req;
        inner_req.valid = (accept_now & (this_delay == 8'd0))
                        | (holding   & (delay_left == 8'd0));
    end

    // Deliberately a separate block from the one above, which reads `req`.
    // Combining them makes the block that drives `rsp` sensitive to `req` -- and
    // the core derives req.valid from rsp.ready, so that closes an event loop
    // and wedges the simulator in zero time, with no value actually changing.
    // The watchdog cannot save you from that: simulation time never advances, so
    // it never fires. Same failure the BTB training path produced once already.
    always_comb begin
        rsp       = inner_rsp;
        rsp.ready = can_accept;
    end

    always @(posedge clk) begin
        if (reset) begin
            lfsr       <= 16'hACE1;
            holding    <= 1'b0;
            delay_left <= 8'd0;
        end else begin
            // Standard 16-bit Galois LFSR, taps 16,14,13,11.
            lfsr <= {1'b0, lfsr[15:1]} ^ (lfsr[0] ? 16'hB400 : 16'h0000);

            if (accept_now && this_delay != 8'd0) begin
                holding    <= 1'b1;
                pending    <= req;
                // -1 so that delay 1 costs one extra cycle rather than two:
                // total latency is this_delay + 1, continuous with the
                // passthrough case above.
                delay_left <= this_delay - 8'd1;
            end else if (holding) begin
                if (delay_left == 8'd0)
                    holding <= 1'b0;
                else
                    delay_left <= delay_left - 8'd1;
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk)
        if (!reset && req.valid && !can_accept)
            $error("%m: request presented while not ready (addr %08x)", req.addr);
`endif

endmodule
// verilator coverage_on

`endif
