# pico2-ice build: sv2v -> yosys -> nextpnr -> icepack -> dfu-util.
# CLK_FREQ must match the firmware's ice_fpga_init()

TOP        := rv32_top
PCF        := $(TOP).pcf
ROOT       := ../..
RTL        := $(ROOT)/rtl

# Hash of the RTL, so the host can spot a stale bitstream
BUILD_ID   := $(shell cat $$(cat rtl-sources.txt) | shasum -a 256 | cut -c1-8)

CLK_FREQ   ?= 12000000
BAUD_RATE  ?= 1000000

BUILD      := build

# yosys can't parse this SystemVerilog, so sv2v converts it first
SV_SRC     := $(TOP).sv uart.sv memory_spram.sv \
              $(RTL)/core/cpu.sv $(RTL)/mem/memory_io.sv $(RTL)/core/base.sv \
              $(RTL)/core/system.sv $(RTL)/core/riscv.sv $(RTL)/core/riscv32_common.sv

INC        := -I$(RTL)/core -I$(RTL)/mem -I.

# SYNTHESIS drops the sim-only checkers. The UP5K has no room for the M extension
DEFS       := -DSYNTHESIS -Dext_m_disable

DFU_VID_PID := 1209:b1c0

.PHONY: all prog clean stat util time lint sim

all: $(BUILD)/$(TOP).bin

$(BUILD)/$(TOP).v: $(SV_SRC)
	@mkdir -p $(BUILD)
	sv2v $(INC) $(DEFS) --write=$@ $(TOP).sv

$(BUILD)/$(TOP).json: $(BUILD)/$(TOP).v
	yosys -q -p "read_verilog $<; \
		chparam -set CLK_FREQ $(CLK_FREQ) $(TOP); \
		chparam -set BAUD_RATE $(BAUD_RATE) $(TOP); \
		chparam -set BUILD_ID 32'h$(BUILD_ID) $(TOP); \
		synth_ice40 -top $(TOP) -abc9 -dff -json $@"

$(BUILD)/$(TOP).asc: $(BUILD)/$(TOP).json $(PCF)
	nextpnr-ice40 -q --up5k --package sg48 --freq $$(($(CLK_FREQ)/1000000)) \
		--pcf $(PCF) --json $< --asc $@

$(BUILD)/$(TOP).bin: $(BUILD)/$(TOP).asc
	icepack $< $@

# dfu-util always says "firmware is corrupt" here. It's a false alarm
prog: $(BUILD)/$(TOP).bin
	dfu-util -d $(DFU_VID_PID) -a 0 -D $< -R

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

# Falls back to the chipdb file when -d up5k isn't found
time: $(BUILD)/$(TOP).asc
	icetime -d up5k -c $$(($(CLK_FREQ)/1000000)) -t $< 2>/dev/null || \
	icetime -C $$(brew --prefix icestorm)/share/icestorm/chipdb/chipdb-5k.txt \
		-c $$(($(CLK_FREQ)/1000000)) -t $<

lint:
	verilator --lint-only -Wall --top-module $(TOP) $(INC) \
		$(TOP).sv uart.sv memory_spram.sv $(RTL)/core/cpu.sv 2>&1 | head -60

# Board-level simulation over the UART protocol, built without M like the bitstream
# make sim runs rv32ui and rv32mi; make sim TEST=riscv-tests/add runs one
IVERILOG   ?= iverilog
SIM_TB     := $(BUILD)/tb_rv32_top
TEST       ?=

$(SIM_TB): sim/tb_rv32_top.sv sim/sb_spram256ka.sv $(TOP).sv uart.sv memory_spram.sv \
           $(wildcard $(RTL)/core/*.sv) $(RTL)/mem/memory_io.sv
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 -Dext_m_disable -Isim $(INC) -o $@ sim/tb_rv32_top.sv

sim: $(SIM_TB)
	@$(MAKE) -s -C $(ROOT) riscv-tests riscv-tests-mi build/tools/dumphex
	@tests="$(TEST)"; \
	[ -n "$$tests" ] || tests=`cd $(ROOT)/build && ls riscv-tests/*.elf riscv-tests-mi/*.elf | sed 's/\.elf$$//'`; \
	pass=0; fail=0; \
	for t in $$tests; do \
		d=$(ROOT)/build/hex/ice40/$$t; \
		/bin/bash $(ROOT)/tools/elftohex.sh $(ROOT)/build/$$t.elf $$d >/dev/null; \
		out=`cd $$d && $(CURDIR)/$(SIM_TB) 2>&1`; \
		if echo "$$out" | grep -q "^TOHOST=1$$"; then \
			pass=$$((pass+1)); echo "PASS $$t"; \
		else \
			fail=$$((fail+1)); echo "FAIL $$t"; echo "$$out" | grep -aE "TOHOST|FATAL" | head -3; \
		fi; \
	done; \
	echo ""; echo "$$pass passed, $$fail failed, $$((pass+fail)) total"; \
	[ $$fail -eq 0 ]

clean:
	rm -rf $(BUILD)
