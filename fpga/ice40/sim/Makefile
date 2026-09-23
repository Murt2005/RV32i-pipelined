# Board-level simulation over the UART protocol.
# make run TEST=hazards/load_use runs one test; make run-all runs them all

ROOT   := ../../..
IVERILOG ?= iverilog
TEST   ?= isa/add_sub

INC    := -I. -I.. -I$(ROOT)/rtl/core -I$(ROOT)/rtl/mem
SIM    := tb_rv32_top
HEX    := $(ROOT)/build/hex/ice40/$(TEST)

TESTS_DIRS := $(ROOT)/tests/isa $(ROOT)/tests/hazards
TESTS_S    := $(foreach d,$(TESTS_DIRS),$(wildcard $(d)/*.s))
TESTS_STEMS := $(patsubst $(ROOT)/tests/%.s,%,$(TESTS_S))

.PHONY: run run-all clean

$(SIM): tb_rv32_top.sv ../rv32_top.sv ../uart.sv ../memory_spram.sv \
        sb_spram256ka.sv $(wildcard $(ROOT)/rtl/core/*.sv) $(ROOT)/rtl/mem/memory_io.sv
	$(IVERILOG) -g2012 $(INC) -o $@ tb_rv32_top.sv

run: $(SIM)
	$(MAKE) -C $(ROOT) build/tests/$(TEST).elf build/tools/dumphex
	/bin/bash $(ROOT)/tools/elftohex.sh $(ROOT)/build/tests/$(TEST).elf $(HEX)
	cd $(HEX) && $(CURDIR)/$(SIM)

run-all: $(SIM)
	@set -e; for t in $(TESTS_STEMS); do \
		echo ""; echo "########## $$t ##########"; \
		$(MAKE) --no-print-directory run TEST=$$t; \
	done

clean:
	rm -f $(SIM) *.hex *.vcd
