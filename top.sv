`include "base.sv"
`include "memory.sv"
`include "memory_delay.sv"
`include "bus/memory_map.sv"
`include "bus/decoder.sv"
`include "bus/mmio.sv"
`include "bus/arbiter.sv"
`include "bus/icache.sv"
`include "cpu.sv"

// stall_rate drives the core's stall input from an LFSR, `stall_rate`/256 of
// the time. It mirrors what the pico2-ice top does with transmit-queue
// backpressure, and exists here because the stall and fetch-realign paths are
// otherwise unreachable in simulation -- coverage showed them at zero, which
// meant the fetch redirect fix had no fast regression behind it.
//
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

// Free-running while the core runs, readable through the MMIO target.
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
	,.clear_regs(1'b0)          // the register file's `initial` block covers this
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

// ---------------------------------------------------------------------------
// Bus.
//
// Two decoders, one per core port. The instruction side reaches instruction
// memory; the data side reaches data memory, MMIO and the framebuffer. Anything
// else is unmapped and answers zero in one cycle, which is how a stray access
// stays inert instead of aliasing onto real memory the way it used to -- every
// region used to be a 64 KiB alias of every other, because both memories simply
// discarded the top sixteen address bits.
//
// Both legacy regions are still single-cycle memories at their original
// addresses, so the whole existing suite runs through this without taking an
// extra cycle -- which is what makes the cycle gate meaningful here.
// ---------------------------------------------------------------------------
memory_io_req i_imem_req, i_dmem_req, i_mmio_req, i_fb_req, i_sdram_req;
memory_io_rsp i_imem_rsp, i_sdram_rsp;
memory_io_req d_imem_req, d_dmem_req, d_mmio_req, d_fb_req, d_sdram_req;
memory_io_rsp d_dmem_rsp, d_mmio_rsp, d_fb_rsp, d_sdram_rsp;

// Ports a given decoder does not use. Driven from a wire rather than wired to
// the localparam directly, so nothing depends on a tool accepting a struct
// constant in a port connection.
memory_io_rsp tie_off_rsp;
assign tie_off_rsp = memory_io_no_rsp;

// Instruction side: instruction memory and SDRAM.
bus_decoder #(
    .present((8'd1 << `BUS_IMEM) | (8'd1 << `BUS_SDRAM))
) ibus (
    .clk(clk), .reset(reset),
    .cpu_req(inst_mem_req), .cpu_addr(inst_mem_addr), .cpu_rsp(inst_mem_rsp),
    .imem_req(i_imem_req),   .imem_rsp(i_imem_rsp),
    .dmem_req(i_dmem_req),   .dmem_rsp(tie_off_rsp),
    .mmio_req(i_mmio_req),   .mmio_rsp(tie_off_rsp),
    .fb_req(i_fb_req),       .fb_rsp(tie_off_rsp),
    .sdram_req(i_sdram_req), .sdram_rsp(i_sdram_rsp)
);

// Data side: everything except instruction memory. A store into the instruction
// region is not a thing any program here does -- the loader on hardware writes
// it through a separate path -- and letting it decode as unmapped means such a
// store is dropped rather than silently landing in data memory, which is what
// the old aliasing map did.
bus_decoder #(
    .present((8'd1 << `BUS_DMEM) | (8'd1 << `BUS_MMIO)
           | (8'd1 << `BUS_FB)   | (8'd1 << `BUS_SDRAM))
) dbus (
    .clk(clk), .reset(reset),
    .cpu_req(data_mem_req), .cpu_addr(data_mem_addr), .cpu_rsp(data_mem_rsp),
    .imem_req(d_imem_req),   .imem_rsp(tie_off_rsp),
    .dmem_req(d_dmem_req),   .dmem_rsp(d_dmem_rsp),
    .mmio_req(d_mmio_req),   .mmio_rsp(d_mmio_rsp),
    .fb_req(d_fb_req),       .fb_rsp(d_fb_rsp),
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

// Framebuffer, 64 KiB. No display in simulation; it exists so the software side
// of the port can be written and tested against the real address.
memory_delay #(
    .size(32'h0001_0000)
    ,.enable_rsp_addr(true)
    ) fb_mem (
    .clk(clk)
    ,.reset(reset)
    ,.max_delay(mem_delay)
    ,.req(d_fb_req)
    ,.rsp(d_fb_rsp)
    );

// SDRAM, shared by both ports through the arbiter. The real device is 64 MiB;
// this models 1 MiB, which is all a simulation test needs and all iverilog
// wants to allocate. Addresses alias within it, exactly as the legacy memories
// do within their 64 KiB.
memory_io_req sdram_req;
memory_io_rsp sdram_rsp;
logic         icache_invalidate;

// The instruction side reaches SDRAM through a cache; the data side does not
// yet. The cache is behind the decoder on purpose, so on-chip instruction memory
// keeps its single-cycle path and pays nothing for a lookup it does not need.
memory_io_req ic_mem_req;
memory_io_rsp ic_mem_rsp;

icache icache_m(
    .clk(clk), .reset(reset),
    .invalidate(icache_invalidate),
    .cpu_req(i_sdram_req), .cpu_rsp(i_sdram_rsp),
    .mem_req(ic_mem_req),  .mem_rsp(ic_mem_rsp)
);

bus_arbiter sdram_arb(
    .clk(clk), .reset(reset),
    .a_req(d_sdram_req), .a_rsp(d_sdram_rsp),
    .b_req(ic_mem_req),  .b_rsp(ic_mem_rsp),
    .t_req(sdram_req),   .t_rsp(sdram_rsp)
);

memory_delay #(
    .size(32'h0010_0000)
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

// tohost: 1 means pass, anything else is (failing test number << 1) | 1.
always @(posedge clk) if (tohost_valid) $write("\nTOHOST=%0d\n", tohost_data);

assign halt = halt_pulse;

endmodule
