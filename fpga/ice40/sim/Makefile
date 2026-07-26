# Board-level simulation of rv32_top, driven over the real UART wire protocol.
#
#   make run                       -> runs tests/isa/add_sub
#   make run TEST=hazards/load_use -> runs that test
#   make run-all                   -> every test under tests/
#
# The hex images come from the normal build flow in the repo root, so this
# runs exactly the same programs as the pure-simulation regression.

ROOT   := ../../..
IVERILOG ?= iverilog
TEST   ?= isa/add_sub

INC    := -I. -I.. -I$(ROOT)
SIM    := tb_rv32_top

TESTS_DIRS := $(ROOT)/tests/isa $(ROOT)/tests/hazards
TESTS_S    := $(foreach d,$(TESTS_DIRS),$(wildcard $(d)/*.s))
TESTS_STEMS := $(patsubst $(ROOT)/tests/%.s,%,$(TESTS_S))

.PHONY: run run-all clean

$(SIM): tb_rv32_top.sv ../rv32_top.sv ../uart.sv ../memory_spram.sv \
        sb_spram256ka.sv $(ROOT)/cpu.sv $(ROOT)/riscv32_common.sv
	$(IVERILOG) -g2012 $(INC) -o $@ tb_rv32_top.sv

# Build the test image in the repo root, then run it here against the board top.
run: $(SIM)
	$(MAKE) -C $(ROOT) build/tests/$(TEST).elf
	cd $(ROOT) && /bin/bash ./elftohex.sh build/tests/$(TEST).elf . && \
		cp code0.hex code1.hex code2.hex code3.hex \
		   data0.hex data1.hex data2.hex data3.hex fpga/ice40/sim/
	./$(SIM)

run-all: $(SIM)
	@set -e; for t in $(TESTS_STEMS); do \
		echo ""; echo "########## $$t ##########"; \
		$(MAKE) --no-print-directory run TEST=$$t; \
	done

clean:
	rm -f $(SIM) *.hex *.vcd
