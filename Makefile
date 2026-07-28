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
# GCC 15 defaults to C23, where bool/true/false are keywords -- and libmc/base.h
# has `typedef unsigned int bool`, which C23 rejects outright. Pinning the
# standard keeps this legacy C compiling with exactly the semantics it was
# written against, including a 4-byte bool, rather than quietly changing type
# sizes underneath it. libmc/Makefile already pins gnu99 for the same reason.
# Nothing caught this until a C program was built, because every test in the
# regression suite is hand-written assembly.
CSTD=-std=gnu17

SSFLAGS=-march=$(MARCH) -mabi=$(MABI)
CCFLAGS=-march=$(MARCH) -mabi=$(MABI) $(CSTD) -Wno-builtin-declaration-mismatch -Ilibmc
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

# Extra memory latency, 0..N cycles drawn per access; 0 is a single-cycle
# memory and reproduces the original behaviour exactly.
#   make run-tests-iverilog MEM_LATENCY=8
# Worth running together with STALL_RATE rather than instead of it -- the two
# perturb different parts of the machine and the interesting bugs are where they
# overlap.
MEM_LATENCY ?= 0

# Simulator watchdog in cycles. Matches itop.sv's own default, but has to be
# raised when the memory is slowed down: at MEM_LATENCY=16 a directed test takes
# ~85x the cycles it does at 0, so the default turns a passing run into a
# timeout that looks like a hang.
SIM_TIMEOUT ?= 120000

SIM_ARGS := +stallrate=$(STALL_RATE) +memlatency=$(MEM_LATENCY) +timeout=$(SIM_TIMEOUT)

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


# Rebuilt when its sources *or the ISA* change. It had no prerequisites at all,
# so it was only ever built when missing -- and `make clean` does not remove it.
# Switching MARCH therefore left a stale rv32i archive to be linked against
# rv32im objects, which silently reintroduced libgcc's soft multiply and divide
# into a build that has hardware for both.
LIBMC_SRC := $(wildcard libmc/*.c) $(wildcard libmc/*.s) $(wildcard libmc/*.h) \
             libmc/Makefile site-config.sh

libmc/libmc.a: $(LIBMC_SRC)
	$(MAKE) -C libmc clean
	$(MAKE) -C libmc

dumphex: dumphex.c
	gcc -o dumphex dumphex.c

test: $(TEST_S:.s=.o) $(TEST_C:.c=.o) $(LIBS) $(TOOLS)
	$(LD) $(LDFLAGS) -o test $(TEST_S:.s=.o) $(TEST_C:.c=.o) $(LDPOSTFLAGS)
	/bin/bash ./elftohex.sh test .

# Every RTL file the simulator pulls in, in one list. It was previously spelled
# out per target and had already fallen behind -- a missing entry means make
# reports "up to date" and silently runs the old binary, which looks exactly like
# the edit having no effect.
RTL_CORE := top.sv cpu.sv memory.sv memory_delay.sv memory_io.sv \
            riscv.sv riscv32_common.sv base.sv system.sv divider.sv \
            bus/memory_map.sv bus/decoder.sv bus/mmio.sv bus/arbiter.sv
RTL_SRC  := itop.sv $(RTL_CORE)

$(SIM_IVERILOG): $(RTL_SRC)
	mkdir -p $(dir $@)
	$(IVERILOG) -g2012 -o $@ itop.sv

# Same design with the RVFI commit port enabled. Separate binary so the normal
# simulator, and the synthesised build, carry none of the instrumentation.
build/sim/result-rvfi: $(RTL_SRC)
	mkdir -p $(dir $@)
	$(IVERILOG) -g2012 -DRVFI -o $@ itop.sv

# RVFI_LATENCY sweeps the commit record against a slow memory as well as a fast
# one. The record has to be right in both cases and, until this existed, only the
# fast one was ever checked.
RVFI_LATENCY ?= 0

.PHONY: rvfi-check rvfi-check-slow
rvfi-check: build/sim/result-rvfi $(TOOLS) riscv-tests
	python3 host/rvfi_check.py --all --mem-latency $(RVFI_LATENCY)

rvfi-check-slow: build/sim/result-rvfi $(TOOLS) riscv-tests
	@rc=0; for d in 1 4 8; do \
		printf 'rvfi mem-latency %-3s ' $$d; \
		python3 host/rvfi_check.py --all --mem-latency $$d > build/rvfi-$$d.log 2>&1 \
			&& echo ok || { echo "FAILED -- build/rvfi-$$d.log"; rc=1; }; \
	done; exit $$rc

run-legacy-iverilog: result-iverilog

# Run one test by stem under tests/ (e.g. TEST_STEM=isa/add_sub)
run-one-iverilog: $(TOOLS) $(SIM_IVERILOG)
	/bin/bash ./elftohex.sh build/tests/$(TEST_STEM).elf .
	mkdir -p build/hex/$(TEST_STEM)
	cp code0.hex code1.hex code2.hex code3.hex data0.hex data1.hex data2.hex data3.hex build/hex/$(TEST_STEM)/
	./$(SIM_IVERILOG) $(SIM_ARGS)

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

# --------------------------------------------------------------------
# Memory-latency sweep.
#
# Runs the directed suite against memories that answer late, then again with
# external stall injection on top. Both perturbations are needed: the front end's
# instruction-miss handling and the memory stage's outstanding-access tracking
# are unreachable with a single-cycle memory, and their failure mode is a
# silently skipped instruction -- no assertion, no timeout, just a program that
# executes garbage.
#
#   make latency-sweep
# --------------------------------------------------------------------
# The watchdog is scaled per run rather than just set huge, so a genuine hang
# still fails in seconds instead of grinding through millions of cycles.
LATENCIES := 1 2 4 8 16

.PHONY: latency-sweep
latency-sweep: $(TOOLS) $(SIM_IVERILOG)
	@mkdir -p build; rc=0; \
	run() { \
		printf '%-32s ' "$$1"; \
		$(MAKE) --no-print-directory run-tests-iverilog \
			MEM_LATENCY=$$2 STALL_RATE=$$3 SIM_TIMEOUT=$$4 > "build/$$5" 2>&1 \
			&& ! grep -qE 'FAIL|ERROR|TIMEOUT' "build/$$5" \
			&& echo ok || { echo "FAILED -- build/$$5"; rc=1; }; \
	}; \
	for d in $(LATENCIES); do \
		run "MEM_LATENCY=$$d" $$d 0 $$((150000 * ($$d + 1))) "latency-$$d.log"; \
	done; \
	run "MEM_LATENCY=8 STALL_RATE=128" 8 128 4000000 "latency-8-stall.log"; \
	exit $$rc

# -Wno-fatal for the same reason the coverage build has it: Verilator reports
# circular combinational logic through the control block's advance signals, which
# is a false positive at struct granularity -- it merges every field of
# stage_control_signal_t into one node. The loop predates all of this and the
# declarations in `core` already carry a lint_off for it. Without the flag this
# target simply fails to build, which is how it had been sitting.
result-verilator: $(RTL_CORE) verilator_top.cpp test
	 $(VERILATOR) -O0 --cc --build --top-module top -Wno-fatal top.sv verilator_top.cpp --exe
	 cp obj_dir/Vtop ./result-verilator
	 rm -rf obj_dir
	 ./result-verilator

result-iverilog: itop.sv top.sv cpu.sv test
	 $(IVERILOG) -g2012 -o result-iverilog itop.sv
	 ./result-iverilog
	 rm result-iverilog

clean:
	rm -rf dumphex test.vcd obj_dir/ *.o result-verilator result-iverilog *.hex test.bin test build
	$(MAKE) -C libmc clean


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
		raw=`./$(SIM_IVERILOG) $(SIM_ARGS) 2>/dev/null`; \
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
		raw=`./$(SIM_IVERILOG) $(SIM_ARGS) 2>/dev/null`; \
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
# Official riscv-tests rv32um suite (M extension).
#
# Built with its own -march rather than the global one, so the M tests can be
# brought up while every other program in the tree is still plain rv32i. Once the
# extension is finished MARCH in site-config.sh moves to rv32im_zicsr and this
# override becomes redundant -- but the two must stay separable until then, or a
# half-finished multiplier breaks every existing test at once.
# --------------------------------------------------------------------
RVTESTS_M_DIR := tests/riscv-tests/isa/rv32um
RVTESTS_M     := $(basename $(notdir $(wildcard $(RVTESTS_M_DIR)/*.S)))
RVTESTS_M_ELF := $(addprefix build/riscv-tests-m/,$(addsuffix .elf,$(RVTESTS_M)))

MARCH_M := rv32im_zicsr

RVTEST_M_FLAGS := -march=$(MARCH_M) -mabi=$(MABI) -nostdlib -nostartfiles -fno-builtin \
                  -Itests/riscv-tests-env -Itests/riscv-tests/isa/macros/scalar \
                  -T tests/riscv-tests-env/link.ld

.PHONY: riscv-tests-m run-riscv-tests-m-iverilog

build/riscv-tests-m/%.elf: $(RVTESTS_M_DIR)/%.S tests/riscv-tests-env/riscv_test.h
	mkdir -p $(dir $@)
	$(CC) $(RVTEST_M_FLAGS) -o $@ $<

riscv-tests-m: $(RVTESTS_M_ELF)

run-riscv-tests-m-iverilog: $(TOOLS) $(SIM_IVERILOG) riscv-tests-m
	@pass=0; fail=0; \
	for t in $(RVTESTS_M); do \
		/bin/bash ./elftohex.sh build/riscv-tests-m/$$t.elf . >/dev/null 2>&1; \
		raw=`./$(SIM_IVERILOG) $(SIM_ARGS) 2>/dev/null`; \
		out=`echo "$$raw" | grep -E '^(PASS|FAIL)'`; \
		cyc=`echo "$$raw" | sed -n 's/.*finish called at \([0-9]*\).*/\1/p' | head -1`; \
		if [ "$$out" = "PASS" ]; then \
			pass=$$((pass+1)); echo "PASS rv32um-$$t  finish=$$cyc"; \
		else \
			fail=$$((fail+1)); echo "FAIL rv32um-$$t  ($$out)"; \
		fi; \
	done; \
	echo ""; echo "$$pass passed, $$fail failed, `echo $(RVTESTS_M) | wc -w | tr -d ' '` total"; \
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
DHRY_FLAGS := -march=$(MARCH) -mabi=$(MABI) $(CSTD) -O2 -Ilibmc -I$(DHRY_DIR) \
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
	$(LD) -m $(LDEMUL) --script tests/bench/link.ld -o $@ $(DHRY_OBJS) $(LDPOSTFLAGS)

dhrystone: $(DHRY_OUT)/dhrystone.elf

# --------------------------------------------------------------------
# Line/toggle coverage over both suites, via Verilator.
# --------------------------------------------------------------------
.PHONY: coverage

build/cov/Vtop: $(RTL_CORE) verilator_top.cpp
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
		RV32_MEM_LATENCY=4 RV32_STALL_RATE=128 RV32_MAX_CYCLES=20000000 \
		RV32_COVERAGE_FILE=build/cov/dat/`echo $$t | tr / -`-lat.dat \
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

