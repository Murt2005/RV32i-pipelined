`include "base.sv"
`include "memory.sv"
`include "cpu.sv"

// stall_rate drives the core's stall input from an LFSR, `stall_rate`/256 of
// the time. It mirrors what the pico2-ice top does with transmit-queue
// backpressure, and exists here because the stall and fetch-realign paths are
// otherwise unreachable in simulation -- coverage showed them at zero, which
// meant the fetch redirect fix had no fast regression behind it.
module top(input clk, input reset, input [7:0] stall_rate, output logic halt);

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
// The response is muxed over whatever the data memory returns, one cycle after
// the request, matching the memory's own latency.
// ---------------------------------------------------------------------------
logic [31:0] perf_cycles;
logic [31:0] perf_retired;
logic        perf_sel_cycles, perf_sel_retired;
logic        perf_sel_cycles_q, perf_sel_retired_q;
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


`memory #(
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
        perf_cycles  <= 32'd0;
        perf_retired <= 32'd0;
    end else begin
        perf_cycles  <= perf_cycles + 32'd1;
        if (retired) perf_retired <= perf_retired + 32'd1;
    end
    perf_sel_cycles_q  <= perf_sel_cycles;
    perf_sel_retired_q <= perf_sel_retired;
    perf_cycles_q      <= perf_cycles;
    perf_retired_q     <= perf_retired;
end

always @(*) begin
    data_mem_rsp = data_mem_rsp_raw;
    if (perf_sel_cycles_q)       data_mem_rsp.data = perf_cycles_q;
    else if (perf_sel_retired_q) data_mem_rsp.data = perf_retired_q;
end

`memory #(
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

always @(posedge clk)
	if (data_mem_req.valid && data_mem_req.addr == `word_address_size'h0002_FFFC &&
        data_mem_req.do_write != {(`word_address_size/8){1'b0}})
		halt <= true;
	else
		halt <= false;

endmodule
