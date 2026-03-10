#

include site-config.sh
goal: result-iverilog
CC=$(RISCV_PREFIX)-gcc
AS=$(RISCV_PREFIX)-as
LD=$(RISCV_PREFIX)-ld

SSFLAGS=-march=rv32i
CCFLAGS=-march=rv32i -Wno-builtin-declaration-mismatch -Ilibmc
LDFLAGS=--script ld.script
LDPOSTFLAGS= -Llibmc -lmc  -Llibmc -lmc -L$(RISCV_LIB) -lgcc
TOOLS=dumphex
LIBS=libmc/libmc.a

TEST_S=start.s
TEST_C=test.c

# Minimal hardware bring-up start file (no C runtime needed)
HW_TEST_S=start_hw.s

# --------------------------------------------------------------------
# Per-file RV32I assembly tests (each builds to its own ELF/hex images)
# --------------------------------------------------------------------
TESTS_DIRS := tests/isa tests/hazards
TESTS_S := $(foreach d,$(TESTS_DIRS),$(wildcard $(d)/*.s))
TESTS_STEMS := $(patsubst tests/%.s,%,$(TESTS_S))
TESTS_RUN_NAMES := $(subst /,-,$(TESTS_STEMS))

SIM_IVERILOG := build/sim/result-iverilog
HW_SIM_IVERILOG := build/sim/hw-result-iverilog

.PHONY: run-tests-iverilog run-one-iverilog run-legacy-iverilog

.c.o:
	$(CC) $(CCFLAGS) -c $*.c

.s.o:
	$(AS) $(SSFLAGS) -c $*.s -o $*.o

build/%.o: %.s tests/common/test_macros.s tests/common/test_runtime.s
	mkdir -p $(dir $@)
	$(AS) $(SSFLAGS) -c $< -o $@

build/%.elf: build/%.o
	mkdir -p $(dir $@)
	$(LD) $(LDFLAGS) -o $@ $<


libmc/libmc.a:
	cd libmc; make clean; make; cd ..

dumphex: dumphex.c
	gcc -o dumphex dumphex.c

test: $(TEST_S:.s=.o) $(TEST_C:.c=.o) $(LIBS) $(TOOLS)
	$(LD) $(LDFLAGS) -o test $(TEST_S:.s=.o) $(TEST_C:.c=.o) $(LDPOSTFLAGS)
	/bin/bash ./elftohex.sh test .

# Minimal hardware test: assemble start_hw.s only, link, and generate hex.
# This is intended for FPGA bring-up (UART + HALT MMIO check).
hw-test: $(HW_TEST_S:.s=.o) $(TOOLS)
	$(LD) $(LDFLAGS) -o hw-test $(HW_TEST_S:.s=.o)
	/bin/bash ./elftohex.sh hw-test .

# --------------------------------------------------------------------
# Minimal hardware test simulation
# --------------------------------------------------------------------
# hw-result-iverilog:
#   - Uses the minimal `start_hw.s` program (via hw-test -> code*.hex/data*.hex)
#   - Builds and runs an Icarus Verilog simulation using the usual itop/top/cpu.
$(HW_SIM_IVERILOG): itop.sv top.sv cpu.sv hw-test
	mkdir -p $(dir $@)
	$(IVERILOG) -g2012 -DIVERILOG -o $@ itop.sv

hw-result-iverilog: $(HW_SIM_IVERILOG)
	./$(HW_SIM_IVERILOG)
	rm $(HW_SIM_IVERILOG)

$(SIM_IVERILOG): itop.sv top.sv cpu.sv memory.sv memory_io.sv riscv.sv riscv32_common.sv base.sv system.sv
	mkdir -p $(dir $@)
	$(IVERILOG) -g2012 -DIVERILOG -o $@ itop.sv

run-legacy-iverilog: result-iverilog

# Run one test by stem under tests/ (e.g. TEST_STEM=isa/add_sub)
run-one-iverilog: $(TOOLS) $(SIM_IVERILOG)
	/bin/bash ./elftohex.sh build/tests/$(TEST_STEM).elf .
	mkdir -p build/hex/$(TEST_STEM)
	cp code0.hex code1.hex code2.hex code3.hex data0.hex data1.hex data2.hex data3.hex build/hex/$(TEST_STEM)/
	./$(SIM_IVERILOG)

# Friendly per-test targets, e.g. run-test-isa-add_sub-iverilog
run-test-%-iverilog: $(TOOLS) $(SIM_IVERILOG)
	$(MAKE) build/tests/$(subst -,/,$*).elf
	$(MAKE) run-one-iverilog TEST_STEM=$(subst -,/,$*)

run-tests-iverilog: $(TOOLS) $(SIM_IVERILOG)
	@set -e; for t in $(TESTS_RUN_NAMES); do \
		echo ""; \
		echo "===== Running $$t ====="; \
		$(MAKE) run-test-$$t-iverilog; \
	done


result-verilator: top.sv verilator_top.cpp cpu.sv test
	 $(VERILATOR) -O0 --cc --build --top-module top top.sv verilator_top.cpp --exe
	 cp obj_dir/Vtop ./result-verilator
	 rm -rf obj_dir
	 ./result-verilator

result-iverilog: itop.sv top.sv cpu.sv test
	 $(IVERILOG) -g2012 -DIVERILOG -o result-iverilog itop.sv
	 ./result-iverilog
	 rm result-iverilog

clean:
	rm -rf dumphex test.vcd obj_dir/ *.o result-verilator result-iverilog *.hex test.bin test build

