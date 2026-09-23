`include "base.sv"
`include "memory.sv"
`include "memory_delay.sv"
`include "memory_map.sv"
`include "decoder.sv"
`include "mmio.sv"
`include "arbiter.sv"
`include "icache.sv"
`include "dcache.sv"
`include "cpu.sv"

module top #(
    parameter sdram_bytes = 32'h0010_0000
) (input clk, input reset, input [7:0] stall_rate, input [7:0] mem_delay,
   output logic halt
   );

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

logic [31:0] perf_cycles;
logic [31:0] perf_retired;

memory_io_req 	inst_mem_req;
memory_io_rsp 	inst_mem_rsp;
memory_io_req   data_mem_req;
memory_io_rsp   data_mem_rsp;
riscv::word     inst_mem_addr;
riscv::word     data_mem_addr;

core the_core(
	.clk(clk)
	,.reset(reset)
	,.stall(cpu_stall)
	,.clear_regs(1'b0)
	,.retired(retired)
    ,.reset_pc(32'h0001_0000)
	,.inst_mem_req(inst_mem_req)
	,.inst_mem_rsp(inst_mem_rsp)

	,.data_mem_req(data_mem_req)
	,.data_mem_rsp(data_mem_rsp)
	,.inst_mem_addr(inst_mem_addr)
	,.data_mem_addr(data_mem_addr)
);

always @(posedge clk) begin
    if (reset) begin
        perf_cycles  <= 32'd0;
        perf_retired <= 32'd0;
    end else begin
        perf_cycles  <= perf_cycles + 32'd1;
        if (retired) perf_retired <= perf_retired + 32'd1;
    end
end

memory_io_req i_imem_req, i_dmem_req, i_mmio_req, i_sdram_req;
memory_io_rsp i_imem_rsp, i_sdram_rsp;
memory_io_req d_imem_req, d_dmem_req, d_mmio_req, d_sdram_req;
memory_io_rsp d_dmem_rsp, d_mmio_rsp, d_sdram_rsp;

memory_io_rsp tie_off_rsp;
assign tie_off_rsp = memory_io_no_rsp;

bus_decoder #(
    .present((8'd1 << `BUS_IMEM) | (8'd1 << `BUS_SDRAM))
) ibus (
    .clk(clk), .reset(reset),
    .cpu_req(inst_mem_req), .cpu_addr(inst_mem_addr), .cpu_rsp(inst_mem_rsp),
    .imem_req(i_imem_req),   .imem_rsp(i_imem_rsp),
    .dmem_req(i_dmem_req),   .dmem_rsp(tie_off_rsp),
    .mmio_req(i_mmio_req),   .mmio_rsp(tie_off_rsp),
    .sdram_req(i_sdram_req), .sdram_rsp(i_sdram_rsp)
);

bus_decoder #(
    .present((8'd1 << `BUS_DMEM) | (8'd1 << `BUS_MMIO) | (8'd1 << `BUS_SDRAM))
) dbus (
    .clk(clk), .reset(reset),
    .cpu_req(data_mem_req), .cpu_addr(data_mem_addr), .cpu_rsp(data_mem_rsp),
    .imem_req(d_imem_req),   .imem_rsp(tie_off_rsp),
    .dmem_req(d_dmem_req),   .dmem_rsp(d_dmem_rsp),
    .mmio_req(d_mmio_req),   .mmio_rsp(d_mmio_rsp),
    .sdram_req(d_sdram_req), .sdram_rsp(d_sdram_rsp)
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
    ,.req(i_imem_req)
    ,.rsp(i_imem_rsp)
    );

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
    ,.req(d_dmem_req)
    ,.rsp(d_dmem_rsp)
    );

memory_io_req sdram_req;
memory_io_rsp sdram_rsp;
logic         icache_invalidate;

memory_io_req ic_mem_req, dc_mem_req;
memory_io_rsp ic_mem_rsp, dc_mem_rsp;

icache icache_m(
    .clk(clk), .reset(reset),
    .invalidate(icache_invalidate),
    .cpu_req(i_sdram_req), .cpu_rsp(i_sdram_rsp),
    .mem_req(ic_mem_req),  .mem_rsp(ic_mem_rsp)
);

dcache dcache_m(
    .clk(clk), .reset(reset),
    .cpu_req(d_sdram_req), .cpu_rsp(d_sdram_rsp),
    .mem_req(dc_mem_req),  .mem_rsp(dc_mem_rsp)
);

bus_arbiter sdram_arb(
    .clk(clk), .reset(reset),
    .a_req(dc_mem_req), .a_rsp(dc_mem_rsp),
    .b_req(ic_mem_req), .b_rsp(ic_mem_rsp),
    .t_req(sdram_req),  .t_rsp(sdram_rsp)
);

memory_delay #(
    .size(sdram_bytes)
    ,.initialize_mem(true)
    ,.byte0("sdram0.hex")
    ,.byte1("sdram1.hex")
    ,.byte2("sdram2.hex")
    ,.byte3("sdram3.hex")
    ,.enable_rsp_addr(true)
    ) sdram (
    .clk(clk)
    ,.reset(reset)
    ,.max_delay(mem_delay)
    ,.req(sdram_req)
    ,.rsp(sdram_rsp)
    );

logic        putchar_valid;
logic [7:0]  putchar_data;
logic        halt_pulse;
logic        tohost_valid;
logic [31:0] tohost_data;

mmio mmio_m(
    .clk(clk), .reset(reset),
    .req(d_mmio_req), .rsp(d_mmio_rsp),
    .perf_cycles(perf_cycles), .perf_retired(perf_retired),
    .putchar_valid(putchar_valid), .putchar_data(putchar_data),
    .halt_pulse(halt_pulse),
    .tohost_valid(tohost_valid), .tohost_data(tohost_data),
    .icache_invalidate(icache_invalidate)
);

always @(posedge clk) if (putchar_valid) $write("%c", putchar_data);

always @(posedge clk) if (tohost_valid) $write("\nTOHOST=%0d\n", tohost_data);

assign halt = halt_pulse;

endmodule
