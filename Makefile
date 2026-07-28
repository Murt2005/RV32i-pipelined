#

include site-config.sh
goal: result-iverilog
CC=$(RISCV_PREFIX)-gcc
AS=$(RISCV_PREFIX)-as
LD=$(RISCV_PREFIX)-ld

# MARCH/MABI come from site-config.sh, so this file and libmc/Makefile cannot
# drift apart. -mabi is now explicit everywhere: it is the default for rv32i so
# omitting it happened to work, but RISCV_LIB points at one specific multilib
# directory and the two have to agree.
SSFLAGS=-march=$(MARCH) -mabi=$(MABI)
CCFLAGS=-march=$(MARCH) -mabi=$(MABI) -Wno-builtin-declaration-mismatch -Ilibmc
LDFLAGS=-m $(LDEMUL) --script ld.script
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

# Pipeline stall rate out of 256 for simulation runs; 0 disables.
#   make run-tests-iverilog STALL_RATE=128
STALL_RATE ?= 0

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

# Same design with the RVFI commit port enabled. Separate binary so the normal
# simulator, and the synthesised build, carry none of the instrumentation.
build/sim/result-rvfi: itop.sv top.sv cpu.sv memory.sv memory_io.sv riscv.sv riscv32_common.sv base.sv system.sv
	mkdir -p $(dir $@)
	$(IVERILOG) -g2012 -DRVFI -o $@ itop.sv

.PHONY: rvfi-check
rvfi-check: build/sim/result-rvfi $(TOOLS) riscv-tests
	python3 host/rvfi_check.py --all

run-legacy-iverilog: result-iverilog

# Run one test by stem under tests/ (e.g. TEST_STEM=isa/add_sub)
run-one-iverilog: $(TOOLS) $(SIM_IVERILOG)
	/bin/bash ./elftohex.sh build/tests/$(TEST_STEM).elf .
	mkdir -p build/hex/$(TEST_STEM)
	cp code0.hex code1.hex code2.hex code3.hex data0.hex data1.hex data2.hex data3.hex build/hex/$(TEST_STEM)/
	./$(SIM_IVERILOG) +stallrate=$(STALL_RATE)

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


# --------------------------------------------------------------------
# Cycle-count gate.
#
# Several changes on the way to a cache-backed memory are supposed to be
# *invisible* while the memory still answers in one cycle -- decoupling the
# memory stage's request generation from its advance signal, for instance,
# introduces stall conditions that a single-cycle memory can never assert. So
# every test must take exactly the same number of cycles as before, and a delta
# is the cheapest available signal that the fast path was perturbed. It shows up
# well before any test starts failing.
#
#   make cycle-baseline     # record, before the change
#   make cycle-check        # compare, after it; non-zero exit on any delta
# --------------------------------------------------------------------
# The baselines are checked in, not left in build/, for two reasons: `make clean`
# would otherwise silently disarm the gate, and every test feeding it is
# assembly, so the counts depend only on the RTL. That makes them a property of
# the design rather than of one machine, and a diff in review shows exactly which
# tests a pipeline change moved and by how much.
CYCLE_DIR := tests/cycles
CYCLE_LOG := build/cycles
CYCLE_SUITES := directed:run-tests-iverilog \
                rv32ui:run-riscv-tests-iverilog \
                rv32ui-p:run-riscv-tests-p-iverilog

.PHONY: cycle-baseline cycle-check

cycle-baseline: MODE := --save
cycle-check:    MODE := --compare
cycle-baseline cycle-check:
	@mkdir -p $(CYCLE_DIR) $(CYCLE_LOG); rc=0; \
	for s in $(CYCLE_SUITES); do \
		name=$${s%%:*}; target=$${s#*:}; \
		echo "===== $$name ====="; \
		$(MAKE) --no-print-directory $$target > $(CYCLE_LOG)/$$name.log 2>&1 \
			|| { echo "  suite FAILED -- see $(CYCLE_LOG)/$$name.log"; rc=1; continue; }; \
		python3 host/cycle_report.py $(MODE) $(CYCLE_DIR)/$$name.json \
			$(CYCLE_LOG)/$$name.log || rc=1; \
	done; \
	exit $$rc

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

RVTEST_FLAGS := -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles -fno-builtin \
                -Itests/riscv-tests-env -Itests/riscv-tests/isa/macros/scalar \
                -T tests/riscv-tests-env/link.ld

.PHONY: riscv-tests run-riscv-tests-iverilog riscv-tests-p run-riscv-tests-p-iverilog

build/riscv-tests/%.elf: $(RVTESTS_DIR)/%.S tests/riscv-tests-env/riscv_test.h
	mkdir -p $(dir $@)
	$(CC) $(RVTEST_FLAGS) -o $@ $<

riscv-tests: $(RVTESTS_ELF)

run-riscv-tests-iverilog: $(TOOLS) $(SIM_IVERILOG) riscv-tests
	@pass=0; fail=0; \
	for t in $(RVTESTS); do \
		/bin/bash ./elftohex.sh build/riscv-tests/$$t.elf . >/dev/null 2>&1; \
		raw=`./$(SIM_IVERILOG) +stallrate=$(STALL_RATE) 2>/dev/null`; \
		out=`echo "$$raw" | grep -E '^(PASS|FAIL)'`; \
		cyc=`echo "$$raw" | sed -n 's/.*finish called at \([0-9]*\).*/\1/p' | head -1`; \
		if [ "$$out" = "PASS" ]; then \
			pass=$$((pass+1)); echo "PASS rv32ui-$$t  finish=$$cyc"; \
		else \
			fail=$$((fail+1)); echo "FAIL rv32ui-$$t  ($$out)"; \
		fi; \
	done; \
	echo ""; echo "$$pass passed, $$fail failed, `echo $(RVTESTS) | wc -w | tr -d ' '` total"; \
	[ $$fail -eq 0 ]

# The same test bodies against the suite's *stock* `p` environment, which
# reports results through an ECALL trap handler and the `tohost` location
# rather than through this project's MMIO registers. It therefore exercises
# mtvec/mepc/mcause/ECALL/MRET on every single test.
RVTEST_P_FLAGS := -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles -fno-builtin \
                  -Itests/riscv-tests/env/p -Itests/riscv-tests/env \
                  -Itests/riscv-tests/isa/macros/scalar \
                  -T tests/riscv-tests-env/link-p.ld

RVTESTS_P_ELF := $(addprefix build/riscv-tests-p/,$(addsuffix .elf,$(RVTESTS)))

build/riscv-tests-p/%.elf: $(RVTESTS_DIR)/%.S tests/riscv-tests-env/link-p.ld
	mkdir -p $(dir $@)
	$(CC) $(RVTEST_P_FLAGS) -o $@ $<

riscv-tests-p: $(RVTESTS_P_ELF)

run-riscv-tests-p-iverilog: $(TOOLS) $(SIM_IVERILOG) riscv-tests-p
	@pass=0; fail=0; \
	for t in $(RVTESTS); do \
		/bin/bash ./elftohex.sh build/riscv-tests-p/$$t.elf . >/dev/null 2>&1; \
		raw=`./$(SIM_IVERILOG) +stallrate=$(STALL_RATE) 2>/dev/null`; \
		out=`echo "$$raw" | grep -oE 'TOHOST=[0-9]+' | head -1`; \
		cyc=`echo "$$raw" | sed -n 's/.*finish called at \([0-9]*\).*/\1/p' | head -1`; \
		if [ "$$out" = "TOHOST=1" ]; then \
			pass=$$((pass+1)); echo "PASS rv32ui-p-$$t  finish=$$cyc"; \
		else \
			fail=$$((fail+1)); echo "FAIL rv32ui-p-$$t  ($$out)"; \
		fi; \
	done; \
	echo ""; echo "$$pass passed, $$fail failed, `echo $(RVTESTS) | wc -w | tr -d ' '` total"; \
	[ $$fail -eq 0 ]

# --------------------------------------------------------------------
# Dhrystone. The benchmark sources are copied unmodified from
# tests/riscv-tests/benchmarks/dhrystone (a number is only comparable if the
# benchmark is); tests/bench/dhrystone/port.c supplies what this bare-metal
# machine does not already have, and rv_env.h replaces the riscv-tests util.h.
#
# Timing comes from the mcycle CSR, which dhrystone.h already selects for
# __riscv. -O2 with the source's own no-inline pragma is the conventional
# Dhrystone build.
# --------------------------------------------------------------------
DHRY_DIR  := tests/bench/dhrystone
DHRY_OUT  := build/tests/bench/dhrystone
DHRY_FLAGS := -march=$(MARCH) -mabi=$(MABI) -O2 -Ilibmc -I$(DHRY_DIR) \
              -Wno-implicit-function-declaration -Wno-builtin-declaration-mismatch \
              -Wno-implicit-int -Wno-return-type
DHRY_OBJS := $(DHRY_OUT)/start.o $(DHRY_OUT)/dhrystone.o \
             $(DHRY_OUT)/dhrystone_main.o $(DHRY_OUT)/port.o

.PHONY: dhrystone

$(DHRY_OUT)/start.o: start.s
	mkdir -p $(dir $@)
	$(AS) $(SSFLAGS) -c $< -o $@

$(DHRY_OUT)/%.o: $(DHRY_DIR)/%.c $(DHRY_DIR)/dhrystone.h $(DHRY_DIR)/rv_env.h
	mkdir -p $(dir $@)
	$(CC) $(DHRY_FLAGS) -c $< -o $@

$(DHRY_OUT)/dhrystone.elf: $(DHRY_OBJS) $(LIBS) tests/bench/link.ld
	$(LD) --script tests/bench/link.ld -o $@ $(DHRY_OBJS) $(LDPOSTFLAGS)

dhrystone: $(DHRY_OUT)/dhrystone.elf

# --------------------------------------------------------------------
# Line/toggle coverage over both suites, via Verilator.
# --------------------------------------------------------------------
.PHONY: coverage

build/cov/Vtop: top.sv cpu.sv memory.sv memory_io.sv riscv.sv riscv32_common.sv \
                base.sv system.sv verilator_top.cpp
	mkdir -p build/cov
	$(VERILATOR) -O0 --cc --build --top-module top --coverage \
		--Mdir build/cov -Wno-fatal top.sv verilator_top.cpp --exe \
		-o Vtop

coverage: build/cov/Vtop $(TOOLS) riscv-tests
	@rm -rf build/cov/dat; mkdir -p build/cov/dat
	@set -e; n=0; \
	for t in $(TESTS_STEMS); do \
		$(MAKE) -s build/tests/$$t.elf >/dev/null; \
		/bin/bash ./elftohex.sh build/tests/$$t.elf . >/dev/null 2>&1; \
		RV32_COVERAGE_FILE=build/cov/dat/`echo $$t | tr / -`.dat \
			./build/cov/Vtop >/dev/null 2>&1; n=$$((n+1)); \
		RV32_STALL_RATE=128 \
		RV32_COVERAGE_FILE=build/cov/dat/`echo $$t | tr / -`-stall.dat \
			./build/cov/Vtop >/dev/null 2>&1; n=$$((n+1)); \
	done; \
	for t in $(RVTESTS); do \
		/bin/bash ./elftohex.sh build/riscv-tests/$$t.elf . >/dev/null 2>&1; \
		RV32_COVERAGE_FILE=build/cov/dat/rv32ui-$$t.dat \
			./build/cov/Vtop >/dev/null 2>&1; n=$$((n+1)); \
	done; \
	echo "ran $$n programs"
	@verilator_coverage --write build/cov/merged.dat build/cov/dat/*.dat >/dev/null
	@verilator_coverage --annotate build/cov/annotated --annotate-min 1 \
		build/cov/merged.dat 2>&1 | tail -20
	@echo ""
	@echo "uncovered points (marked %000000 in build/cov/annotated/):"
	@grep -rc "^%000000" build/cov/annotated/ 2>/dev/null | grep -v ":0$$" || \
		echo "  none"

