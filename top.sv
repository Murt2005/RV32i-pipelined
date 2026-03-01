`include "base.sv"
`include "memory.sv"
`include "cpu.sv"

module top(input clk, input reset, output logic halt);


memory_io_req 	inst_mem_req;
memory_io_rsp 	inst_mem_rsp;
memory_io_req   data_mem_req;
memory_io_rsp   data_mem_rsp;

core the_core(
	.clk(clk)
	,.reset(reset)
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
    ,.rsp(data_mem_rsp)
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
