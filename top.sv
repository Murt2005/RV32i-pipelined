`include "base.sv"
`include "memory.sv"
`include "memory_delay.sv"
`include "cpu.sv"

// stall_rate drives the core's stall input from an LFSR, `stall_rate`/256 of
// the time. It mirrors what the pico2-ice top does with transmit-queue
// backpressure, and exists here because the stall and fetch-realign paths are
// otherwise unreachable in simulation -- coverage showed them at zero, which
// meant the fetch redirect fix had no fast regression behind it.
// mem_delay makes both memories answer late and refuse requests while busy, so
// the pipeline's cache-miss stall paths are reachable before there is a cache.
// 0 is a pure passthrough and reproduces the single-cycle behaviour exactly.
// Meant to be run together with stall_rate, not instead of it: the two perturb
// different parts of the machine and the bugs are in the overlap.
module top(input clk, input reset, input [7:0] stall_rate, input [7:0] mem_delay,
           output logic halt);

logic [15:0] stall_lfsr;
logic        cpu_stall;

always @(posedge clk) begin
    if (reset)
        stall_lfsr <= 16'hACE1;
    else
        stall_lfsr <= stall_lfsr[0] ? ((stall_lfsr >> 1) ^ 16'hB400)
                                    : (stall_lfsr >> 1);
end

assign cpu_stall = (stall_lfsr[7:0] < stall_rate);


logic retired;

// ---------------------------------------------------------------------------
// Performance counters, readable as memory-mapped words.
//   0x0002FFF0  cycles elapsed
//   0x0002FFF4  instructions committed
// The counter value is sampled when the request goes out and the selection is
// held until the response comes back. It used to be a single-cycle shadow,
// which silently assumed the memory always answered in exactly one cycle -- with
// mem_delay set, that put the counter on the wrong response, or on none at all.
// Only one access is ever outstanding, so a single held flag is enough.
// ---------------------------------------------------------------------------
logic [31:0] perf_cycles;
logic [31:0] perf_retired;
logic        perf_sel_cycles, perf_sel_retired;
logic        perf_sel_cycles_p, perf_sel_retired_p;
logic [31:0] perf_cycles_q, perf_retired_q;

memory_io_req 	inst_mem_req;
memory_io_rsp 	inst_mem_rsp;
memory_io_req   data_mem_req;
memory_io_rsp   data_mem_rsp;

core the_core(
	.clk(clk)
	,.reset(reset)
	,.stall(cpu_stall)
	,.clear_regs(1'b0)          // the register file's `initial` block covers this
	,.retired(retired)
    ,.reset_pc(32'h0001_0000)
	,.inst_mem_req(inst_mem_req)
	,.inst_mem_rsp(inst_mem_rsp)

	,.data_mem_req(data_mem_req)
	,.data_mem_rsp(data_mem_rsp)
);


memory_delay #(
    .size(32'h0001_0000)
    ,.initialize_mem(true)
    ,.byte0("code0.hex")
    ,.byte1("code1.hex")
    ,.byte2("code2.hex")
    ,.byte3("code3.hex")
    ,.enable_rsp_addr(true)
    ) code_mem (
    .clk(clk)
    ,.reset(reset)
    ,.max_delay(mem_delay)
    ,.req(inst_mem_req)
    ,.rsp(inst_mem_rsp)
    );

memory_io_rsp   data_mem_rsp_raw;

assign perf_sel_cycles  = data_mem_req.valid && data_mem_req.addr == `word_address_size'h0002_FFF0
                          && is_any_byte(data_mem_req.do_read);
assign perf_sel_retired = data_mem_req.valid && data_mem_req.addr == `word_address_size'h0002_FFF4
                          && is_any_byte(data_mem_req.do_read);

always @(posedge clk) begin
    if (reset) begin
        perf_cycles       <= 32'd0;
        perf_retired      <= 32'd0;
        perf_sel_cycles_p <= 1'b0;
        perf_sel_retired_p<= 1'b0;
    end else begin
        perf_cycles  <= perf_cycles + 32'd1;
        if (retired) perf_retired <= perf_retired + 32'd1;

        if (perf_sel_cycles) begin
            perf_sel_cycles_p <= 1'b1;
            perf_cycles_q     <= perf_cycles;
        end else if (data_mem_rsp_raw.valid)
            perf_sel_cycles_p <= 1'b0;

        if (perf_sel_retired) begin
            perf_sel_retired_p <= 1'b1;
            perf_retired_q     <= perf_retired;
        end else if (data_mem_rsp_raw.valid)
            perf_sel_retired_p <= 1'b0;
    end
end

always @(*) begin
    data_mem_rsp = data_mem_rsp_raw;
    if (data_mem_rsp_raw.valid) begin
        if (perf_sel_cycles_p)       data_mem_rsp.data = perf_cycles_q;
        else if (perf_sel_retired_p) data_mem_rsp.data = perf_retired_q;
    end
end

memory_delay #(
    .size(32'h0001_0000)
    ,.initialize_mem(true)
    ,.byte0("data0.hex")
    ,.byte1("data1.hex")
    ,.byte2("data2.hex")
    ,.byte3("data3.hex")
    ,.enable_rsp_addr(true)
    ) data_mem (
    .clk(clk)
    ,.reset(reset)
    ,.max_delay(mem_delay)
    ,.req(data_mem_req)
    ,.rsp(data_mem_rsp_raw)
    );



/* helpful for debugging
always @(posedge clk) begin
    if (data_mem_req.valid && data_mem_req.do_write != 0)
        $display("%x write: %x do_write: %x data: %x", inst_mem_req.addr, data_mem_req.addr, data_mem_req.do_write, data_mem_req.data);
    if (data_mem_req.valid && data_mem_req.do_read != 0)
        $display("%x read: %x do_read:", inst_mem_req.addr, data_mem_req.addr, data_mem_req.do_read);

end
*/

always @(posedge clk)
	if (data_mem_req.valid && data_mem_req.addr == `word_address_size'h0002_FFF8 &&
        data_mem_req.do_write != {(`word_address_size/8){1'b0}}) begin
		//$display("Ouptut data: %x and do_write %x", data_mem_req.data, data_mem_req.do_write);
		$write("%c", data_mem_req.data[7:0]);
	end

// Halt on the usual register, or on `tohost`. The stock riscv-tests `p`
// environment reports its result by storing to tohost and then spinning
// forever, so without this the watchdog would be the only thing that stopped
// it and the result would be lost.
wire halt_write = data_mem_req.valid
                && data_mem_req.do_write != {(`word_address_size/8){1'b0}}
                && (data_mem_req.addr == `word_address_size'h0002_FFFC
                 || data_mem_req.addr == `word_address_size'h0002_FFC0);

always @(posedge clk)
	if (halt_write)
		halt <= true;
	else
		halt <= false;

// tohost: 1 means pass, anything else is (failing test number << 1) | 1.
always @(posedge clk)
	if (data_mem_req.valid && data_mem_req.addr == `word_address_size'h0002_FFC0
	    && data_mem_req.do_write != {(`word_address_size/8){1'b0}})
		$write("\nTOHOST=%0d\n", data_mem_req.data);

endmodule
