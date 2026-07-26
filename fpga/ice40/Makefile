# ---------------------------------------------------------------------------
# pico2-ice gateware build: sv2v -> yosys -> nextpnr-ice40 -> icepack -> dfu-util
#
# CLK_FREQ MUST equal the frequency the firmware passes to ice_fpga_init().
# The UART divisor is a synthesis-time constant, so a mismatch garbles bytes
# rather than producing silence (gotcha G4). Both are 12 MHz here; if you change
# one, change the other and reflash both images.
# ---------------------------------------------------------------------------

TOP        := rv32_top
PCF        := $(TOP).pcf
ROOT       := ../..

# Identifies exactly which RTL this bitstream was built from, so the host can
# refuse to talk to a stale one. The file list is shared with rv32_host.py.
BUILD_ID   := $(shell cat $$(cat rtl-sources.txt) | shasum -a 256 | cut -c1-8)

CLK_FREQ   ?= 6000000
BAUD_RATE  ?= 500000

BUILD      := build

# yosys cannot parse this RTL directly: its Verilog frontend has no `return`
# statement, no $bits(type_name), and does not resolve package typedefs used as
# declaration types. sv2v lowers all of that to Verilog-2005.
SV_SRC     := $(TOP).sv uart.sv memory_spram.sv \
              $(ROOT)/cpu.sv $(ROOT)/memory_io.sv $(ROOT)/base.sv \
              $(ROOT)/system.sv $(ROOT)/riscv.sv $(ROOT)/riscv32_common.sv

INC        := -I$(ROOT) -I.

DFU_VID_PID := 1209:b1c0

.PHONY: all prog clean stat util time lint sim

all: $(BUILD)/$(TOP).bin

# ---- 1. SystemVerilog -> Verilog-2005 -------------------------------------
$(BUILD)/$(TOP).v: $(TOP).sv uart.sv memory_spram.sv $(ROOT)/cpu.sv \
                   $(ROOT)/riscv32_common.sv $(ROOT)/memory_io.sv \
                   $(ROOT)/base.sv $(ROOT)/system.sv $(ROOT)/riscv.sv
	@mkdir -p $(BUILD)
	sv2v $(INC) --write=$@ $(TOP).sv

# ---- 2. synthesis ---------------------------------------------------------
$(BUILD)/$(TOP).json: $(BUILD)/$(TOP).v
	yosys -q -p "read_verilog $<; \
		chparam -set CLK_FREQ $(CLK_FREQ) $(TOP); \
		chparam -set BAUD_RATE $(BAUD_RATE) $(TOP); \
		chparam -set BUILD_ID 32'h$(BUILD_ID) $(TOP); \
		synth_ice40 -top $(TOP) -abc9 -dff -json $@"

# ---- 3. place and route ---------------------------------------------------
$(BUILD)/$(TOP).asc: $(BUILD)/$(TOP).json $(PCF)
	nextpnr-ice40 -q --up5k --package sg48 --freq $$(($(CLK_FREQ)/1000000)) \
		--pcf $(PCF) --json $< --asc $@

# ---- 4. bitstream ---------------------------------------------------------
$(BUILD)/$(TOP).bin: $(BUILD)/$(TOP).asc
	icepack $< $@

# ---- 5. flash -------------------------------------------------------------
# dfu-util prints "Device's firmware is corrupt" on every successful flash.
# It is a false alarm: the SDK's DFU manifest callback reports the result of
# ice_fpga_start(), which unconditionally returns 0 without polling CDONE.
prog: $(BUILD)/$(TOP).bin
	dfu-util -d $(DFU_VID_PID) -a 0 -D $< -R

# ---- diagnostics ----------------------------------------------------------
stat: $(BUILD)/$(TOP).v
	yosys -q -p "read_verilog $<; \
		chparam -set CLK_FREQ $(CLK_FREQ) $(TOP); \
		chparam -set BAUD_RATE $(BAUD_RATE) $(TOP); \
		synth_ice40 -top $(TOP) -abc9 -dff; stat"

util: $(BUILD)/$(TOP).asc
	@grep -A20 "Info: Device utilisation" $(BUILD)/pnr.log 2>/dev/null || \
	nextpnr-ice40 --up5k --package sg48 --pcf $(PCF) \
		--json $(BUILD)/$(TOP).json --asc /dev/null 2>&1 | \
		grep -A20 "Device utilisation"

# Some Homebrew icestorm installs cannot resolve -d up5k; fall back to the
# chipdb file directly.
time: $(BUILD)/$(TOP).asc
	icetime -d up5k -c $$(($(CLK_FREQ)/1000000)) -t $< 2>/dev/null || \
	icetime -C $$(brew --prefix icestorm)/share/icestorm/chipdb/chipdb-5k.txt \
		-c $$(($(CLK_FREQ)/1000000)) -t $<

lint:
	verilator --lint-only -Wall --top-module $(TOP) $(INC) \
		$(TOP).sv uart.sv memory_spram.sv $(ROOT)/cpu.sv 2>&1 | head -60

# ---- board-level simulation ----------------------------------------------
# Simulates the same RTL that gets synthesized, including a behavioural model
# of the SPRAM hard block and a UART host model.
sim:
	$(MAKE) -C sim run

clean:
	rm -rf $(BUILD)
	$(MAKE) -C sim clean
