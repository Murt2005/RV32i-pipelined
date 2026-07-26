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

# --------------------------------------------------------------------
# Per-file RV32I assembly tests (each builds to its own ELF/hex images)
# --------------------------------------------------------------------
TESTS_DIRS := tests/isa tests/hazards
TESTS_S := $(foreach d,$(TESTS_DIRS),$(wildcard $(d)/*.s))
TESTS_STEMS := $(patsubst tests/%.s,%,$(TESTS_S))
TESTS_RUN_NAMES := $(subst /,-,$(TESTS_STEMS))

SIM_IVERILOG := build/sim/result-iverilog

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

$(SIM_IVERILOG): itop.sv top.sv cpu.sv memory.sv memory_io.sv riscv.sv riscv32_common.sv base.sv system.sv
	mkdir -p $(dir $@)
	$(IVERILOG) -g2012 -o $@ itop.sv

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
	 $(IVERILOG) -g2012 -o result-iverilog itop.sv
	 ./result-iverilog
	 rm result-iverilog

clean:
	rm -rf dumphex test.vcd obj_dir/ *.o result-verilator result-iverilog *.hex test.bin test build


# --------------------------------------------------------------------
# Official riscv-tests rv32ui suite
#
# Uses a local environment (tests/riscv-tests-env) instead of the suite's own
# `p` environment, which reports results through machine-mode CSRs and ECALL
# that this core does not implement.
# --------------------------------------------------------------------
RVTESTS_DIR := tests/riscv-tests/isa/rv32ui

# fence_i: self-modifying code. This is a Harvard machine with a separate
#          instruction memory, so a store can never reach the fetch stream.
# ma_data: misaligned load/store. The core neither supports nor traps them.
RVTESTS_EXCLUDE := fence_i ma_data

RVTESTS_ALL   := $(basename $(notdir $(wildcard $(RVTESTS_DIR)/*.S)))
RVTESTS       := $(filter-out $(RVTESTS_EXCLUDE),$(RVTESTS_ALL))
RVTESTS_ELF   := $(addprefix build/riscv-tests/,$(addsuffix .elf,$(RVTESTS)))

RVTEST_FLAGS := -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles -fno-builtin \
                -Itests/riscv-tests-env -Itests/riscv-tests/isa/macros/scalar \
                -T tests/riscv-tests-env/link.ld

.PHONY: riscv-tests run-riscv-tests-iverilog

build/riscv-tests/%.elf: $(RVTESTS_DIR)/%.S tests/riscv-tests-env/riscv_test.h
	mkdir -p $(dir $@)
	$(CC) $(RVTEST_FLAGS) -o $@ $<

riscv-tests: $(RVTESTS_ELF)

run-riscv-tests-iverilog: $(TOOLS) $(SIM_IVERILOG) riscv-tests
	@pass=0; fail=0; \
	for t in $(RVTESTS); do \
		/bin/bash ./elftohex.sh build/riscv-tests/$$t.elf . >/dev/null 2>&1; \
		out=`./$(SIM_IVERILOG) 2>/dev/null | grep -E '^(PASS|FAIL)'`; \
		if [ "$$out" = "PASS" ]; then \
			pass=$$((pass+1)); echo "PASS rv32ui-$$t"; \
		else \
			fail=$$((fail+1)); echo "FAIL rv32ui-$$t  ($$out)"; \
		fi; \
	done; \
	echo ""; echo "$$pass passed, $$fail failed, `echo $(RVTESTS) | wc -w | tr -d ' '` total"; \
	[ $$fail -eq 0 ]
