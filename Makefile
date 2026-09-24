#

include site-config.sh

# Without this the first rule in the file, bench/libmc/libmc.a, would be the default.
.DEFAULT_GOAL := test

CC=$(RISCV_PREFIX)-gcc
AS=$(RISCV_PREFIX)-as
LD=$(RISCV_PREFIX)-ld

# MARCH/MABI come from site-config.sh, so this file and bench/libmc/Makefile cannot
# drift apart. -mabi is now explicit everywhere: it is the default for rv32i so
# omitting it happened to work, but RISCV_LIB points at one specific multilib
# directory and the two have to agree.
# GCC 15 defaults to C23, where bool/true/false are keywords -- and bench/libmc/base.h
# has `typedef unsigned int bool`, which C23 rejects outright. Pinning the
# standard keeps this legacy C compiling with exactly the semantics it was
# written against, including a 4-byte bool, rather than quietly changing type
# sizes underneath it. bench/libmc/Makefile already pins gnu99 for the same reason.
# Nothing caught this until a C program was built, because every test in the
# regression suite is hand-written assembly.
CSTD=-std=gnu17

SSFLAGS=-march=$(MARCH) -mabi=$(MABI)
LDPOSTFLAGS= -Lbench/libmc -lmc -L$(RISCV_LIB) -lgcc
TOOLS=build/tools/dumphex

# ELF to hex images: the core configuration (IMEM and DMEM) and the system
# configuration (a boot stub in IMEM, the program in SDRAM through the caches)
HEX_CORE   := /bin/bash tools/elftohex-core.sh
HEX_SYSTEM := /bin/bash tools/elftohex-system.sh

# Which configuration programs are built and run in, each with its own build folder
#   make CONFIG=core    IMEM and DMEM, for developing and benchmarking the core
#   make CONFIG=system  a boot stub in IMEM and the program in SDRAM, through the caches
# System test names keep the -sdram suffix that tests/cycles/system.json is keyed on
CONFIG ?= core
ifeq ($(CONFIG),core)
HEX_CONFIG   := $(HEX_CORE)
RVTEST_LD    := tests/riscv-tests-env/link.ld
BENCH_LD     := bench/link.ld
CONFIG_BOOT  :=
SUITE_SUFFIX :=
else ifeq ($(CONFIG),system)
HEX_CONFIG   := $(HEX_SYSTEM)
RVTEST_LD    := tests/riscv-tests-env/link-system.ld
BENCH_LD     := bench/link-system.ld
CONFIG_BOOT  := tests/riscv-tests-env/boot.S
SUITE_SUFFIX := -sdram
else
$(error CONFIG must be core or system)
endif
LIBS=bench/libmc/libmc.a

SIM_IVERILOG := build/sim/result-iverilog
COSIM        := build/cosim/Vcosim_top

# Which simulator runs the tests: iverilog, or cosim to check every instruction against Spike
SIM ?= iverilog
ifeq ($(SIM),iverilog)
SIM_BIN := $(SIM_IVERILOG)
else ifeq ($(SIM),cosim)
SIM_BIN := $(COSIM)
else
$(error SIM must be iverilog or cosim)
endif

# memory.sv reads code0.hex..data3.hex (and sdram0..3.hex) from the simulator's
# working directory. Each program's images go in their own directory here and
# the simulator runs from it, so nothing is written to the repo root and runs
# never pick up each other's images.
HEX := build/hex

# Pipeline stall rate out of 256 for simulation runs; 0 disables.
#   make test STALL_RATE=128
STALL_RATE ?= 0

# Extra memory latency, 0..N cycles drawn per access; 0 is a single-cycle
# memory and reproduces the original behaviour exactly.
#   make test MEM_LATENCY=8
# Worth running together with STALL_RATE rather than instead of it -- the two
# perturb different parts of the machine and the interesting bugs are where they
# overlap.
MEM_LATENCY ?= 0

# Simulator watchdog in cycles. Matches sim/itop.sv's own default, but has to be
# raised when the memory is slowed down: at MEM_LATENCY=16 a program takes
# ~85x the cycles it does at 0, so the default turns a passing run into a
# timeout that looks like a hang.
SIM_TIMEOUT ?= 120000

SIM_ARGS := +stallrate=$(STALL_RATE) +memlatency=$(MEM_LATENCY) +timeout=$(SIM_TIMEOUT)


# Rebuilt when its sources or its ISA change, so a stale archive is never linked
LIBMC_SRC := $(wildcard bench/libmc/*.c) $(wildcard bench/libmc/*.s) $(wildcard bench/libmc/*.h) \
             bench/libmc/Makefile site-config.sh Makefile

bench/libmc/libmc.a: $(LIBMC_SRC)
	$(MAKE) -C bench/libmc clean
	$(MAKE) -C bench/libmc

build/tools/dumphex: tools/dumphex.c
	mkdir -p $(dir $@)
	gcc -o $@ $<

# Every RTL file the simulator pulls in, in one list. It was previously spelled
# out per target and had already fallen behind -- a missing entry means make
# reports "up to date" and silently runs the old binary, which looks exactly like
# the edit having no effect. A wildcard cannot fall behind.
#
# Every `include names a bare file, so the include path is what resolves them.
RTL_DIRS := rtl rtl/core rtl/mem rtl/bus
RTL_INC  := $(addprefix -I,$(RTL_DIRS))
RTL_CORE := $(foreach d,$(RTL_DIRS),$(wildcard $(d)/*.sv))
RTL_SRC  := sim/itop.sv $(RTL_CORE)

$(SIM_IVERILOG): $(RTL_SRC)
	mkdir -p $(dir $@)
	$(IVERILOG) -g2012 $(RTL_INC) -o $@ sim/itop.sv

# Same design with the RVFI commit port enabled; sim/itop.sv then prints a record
# for every retired instruction, which helps when debugging a cosim mismatch
build/sim/result-rvfi: $(RTL_SRC)
	mkdir -p $(dir $@)
	$(IVERILOG) -g2012 $(RTL_INC) -DRVFI -o $@ sim/itop.sv


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
# name:config:target, where "all" is every suite
CYCLE_SUITES := rv32ui:core:run-riscv-tests-iverilog \
                system:system:all

.PHONY: cycle-baseline cycle-check

cycle-baseline: MODE := --save
cycle-check:    MODE := --compare
cycle-baseline cycle-check:
	@mkdir -p $(CYCLE_DIR) $(CYCLE_LOG); rc=0; \
	for s in $(CYCLE_SUITES); do \
		name=$${s%%:*}; rest=$${s#*:}; config=$${rest%%:*}; target=$${rest#*:}; \
		if [ "$$target" = all ]; then target="$(RVTEST_RUNS)"; fi; \
		echo "===== $$name ====="; \
		$(MAKE) --no-print-directory CONFIG=$$config $$target > $(CYCLE_LOG)/$$name.log 2>&1 \
			|| { echo "  suite FAILED -- see $(CYCLE_LOG)/$$name.log"; rc=1; continue; }; \
		python3 tools/cycle_report.py $(MODE) $(CYCLE_DIR)/$$name.json \
			$(CYCLE_LOG)/$$name.log || rc=1; \
	done; \
	exit $$rc

# --------------------------------------------------------------------
# Memory-latency sweep.
#
# Runs every riscv-tests suite against memories that answer late, then again with
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
		$(MAKE) --no-print-directory test \
			MEM_LATENCY=$$2 STALL_RATE=$$3 SIM_TIMEOUT=$$4 > "build/$$5" 2>&1 \
			&& echo ok || { echo "FAILED -- build/$$5"; rc=1; }; \
	}; \
	for d in $(LATENCIES); do \
		run "MEM_LATENCY=$$d" $$d 0 $$((150000 * ($$d + 1))) "latency-$$d.log"; \
	done; \
	run "MEM_LATENCY=8 STALL_RATE=128" 8 128 4000000 "latency-8-stall.log"; \
	exit $$rc

clean:
	rm -rf build
	$(MAKE) -C bench/libmc clean


# --------------------------------------------------------------------
# Official riscv-tests rv32ui suite
#
# Built against the suite's own stock `p` environment. It boots through
# mtvec/PMP/mstatus setup and an MRET, and reports through an ECALL trap handler
# writing `tohost`, so every test also exercises the trap machinery. The only
# local piece is the link script, which fits the tests to this memory map and
# puts .tohost where the tops treat a write as a halt.
#
# tohost is (TESTNUM << 1) | 1: 1 is a pass, anything else names the failing
# test number.
# --------------------------------------------------------------------
RVTESTS_DIR := tests/riscv-tests/isa/rv32ui

# fence_i: self-modifying code. This is a Harvard machine with a separate
#          instruction memory, so a store can never reach the fetch stream.
# ma_data: misaligned load/store. The core neither supports nor traps them.
RVTESTS_EXCLUDE := fence_i ma_data

RVTESTS_ALL   := $(basename $(notdir $(wildcard $(RVTESTS_DIR)/*.S)))
RVTESTS       := $(filter-out $(RVTESTS_EXCLUDE),$(RVTESTS_ALL))
RVTEST_OUT    := build/$(CONFIG)/riscv-tests
RVTESTS_ELF   := $(addprefix $(RVTEST_OUT)/rv32ui/,$(addsuffix .elf,$(RVTESTS)))

RVTEST_FLAGS := -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles -fno-builtin \
                -Itests/riscv-tests/env/p -Itests/riscv-tests/env \
                -Itests/riscv-tests/isa/macros/scalar -T $(RVTEST_LD) \
                -Wl,--no-warn-rwx-segments

# $(call rvtest-rule,suite,source-dir): build one suite for the current configuration
define rvtest-rule
$(RVTEST_OUT)/$(1)/%.elf: $(2)/%.S $(RVTEST_LD) $(CONFIG_BOOT)
	mkdir -p $$(dir $$@)
	$(CC) $(RVTEST_FLAGS) -o $$@ $$< $(CONFIG_BOOT)
endef

# Every riscv-tests ELF for one configuration, for the targets that cover both
rvtest-elfs = $(addprefix build/$(1)/riscv-tests/rv32ui/,$(addsuffix .elf,$(RVTESTS))) \
              $(addprefix build/$(1)/riscv-tests/rv32um/,$(addsuffix .elf,$(RVTESTS_M))) \
              $(addprefix build/$(1)/riscv-tests/rv32mi/,$(addsuffix .elf,$(RVTESTS_MI)))

define build-rvtests-both
@$(MAKE) --no-print-directory CONFIG=core riscv-tests riscv-tests-m riscv-tests-mi
@$(MAKE) --no-print-directory CONFIG=system riscv-tests riscv-tests-m riscv-tests-mi
endef

# $(call run-rvtests,suite,tests,elf-dir,hex-converter)
define run-rvtests
@pass=0; fail=0; \
	for t in $(2); do \
		d=$(HEX)/$(3)/$$t; \
		if ! $(4) build/$(3)/$$t.elf $$d >/dev/null 2>&1; then \
			fail=$$((fail+1)); echo "FAIL $(1)-$$t  (hex conversion)"; continue; \
		fi; \
		raw=`cd $$d && $(CURDIR)/$(SIM_BIN) $(if $(filter cosim,$(SIM)),$(CURDIR)/build/$(3)/$$t.elf) $(SIM_ARGS) 2>/dev/null`; \
		th=`echo "$$raw" | sed -n 's/^TOHOST=\([0-9]*\).*/\1/p' | head -1`; \
		cyc=`echo "$$raw" | sed -n 's/.*finish called at \([0-9]*\).*/\1/p' | head -1`; \
		if [ "$$th" = "1" ]; then \
			pass=$$((pass+1)); echo "PASS $(1)-$$t  finish=$$cyc"; \
		elif [ -n "$$th" ]; then \
			fail=$$((fail+1)); echo "FAIL $(1)-$$t  (test $$((th >> 1)))"; \
		else \
			fail=$$((fail+1)); echo "FAIL $(1)-$$t  (no tohost write)"; \
			echo "$$raw" | grep -E "^(MISMATCH|TIMEOUT)" | head -1; \
		fi; \
	done; \
	echo ""; echo "$$pass passed, $$fail failed, `echo $(2) | wc -w | tr -d ' '` total"; \
	[ $$fail -eq 0 ]
endef

.PHONY: riscv-tests run-riscv-tests-iverilog

riscv-tests: $(RVTESTS_ELF)

run-riscv-tests-iverilog: $(TOOLS) $(SIM_BIN) riscv-tests
	$(call run-rvtests,rv32ui$(SUITE_SUFFIX),$(RVTESTS),$(CONFIG)/riscv-tests/rv32ui,$(HEX_CONFIG))

# --------------------------------------------------------------------
# Official riscv-tests rv32um suite (M extension).
# --------------------------------------------------------------------
RVTESTS_M_DIR := tests/riscv-tests/isa/rv32um
RVTESTS_M     := $(basename $(notdir $(wildcard $(RVTESTS_M_DIR)/*.S)))
RVTESTS_M_ELF := $(addprefix $(RVTEST_OUT)/rv32um/,$(addsuffix .elf,$(RVTESTS_M)))

.PHONY: riscv-tests-m run-riscv-tests-m-iverilog

riscv-tests-m: $(RVTESTS_M_ELF)

run-riscv-tests-m-iverilog: $(TOOLS) $(SIM_BIN) riscv-tests-m
	$(call run-rvtests,rv32um$(SUITE_SUFFIX),$(RVTESTS_M),$(CONFIG)/riscv-tests/rv32um,$(HEX_CONFIG))

# --------------------------------------------------------------------
# Official riscv-tests rv32mi suite (machine-mode CSRs and exceptions).
# --------------------------------------------------------------------
RVTESTS_MI_DIR := tests/riscv-tests/isa/rv32mi

# pmpaddr: assumes physical memory protection, which this core does not have.
RVTESTS_MI_EXCLUDE := pmpaddr

RVTESTS_MI     := $(filter-out $(RVTESTS_MI_EXCLUDE),$(basename $(notdir $(wildcard $(RVTESTS_MI_DIR)/*.S))))
RVTESTS_MI_ELF := $(addprefix $(RVTEST_OUT)/rv32mi/,$(addsuffix .elf,$(RVTESTS_MI)))

.PHONY: riscv-tests-mi run-riscv-tests-mi-iverilog

riscv-tests-mi: $(RVTESTS_MI_ELF)

run-riscv-tests-mi-iverilog: $(TOOLS) $(SIM_BIN) riscv-tests-mi
	$(call run-rvtests,rv32mi$(SUITE_SUFFIX),$(RVTESTS_MI),$(CONFIG)/riscv-tests/rv32mi,$(HEX_CONFIG))

$(eval $(call rvtest-rule,rv32ui,$(RVTESTS_DIR)))
$(eval $(call rvtest-rule,rv32um,$(RVTESTS_M_DIR)))
$(eval $(call rvtest-rule,rv32mi,$(RVTESTS_MI_DIR)))

# Every riscv-tests suite in the current configuration
RVTEST_RUNS := run-riscv-tests-iverilog run-riscv-tests-m-iverilog run-riscv-tests-mi-iverilog

# Every suite in the core configuration, then the system configuration; the default target
.PHONY: test
test:
	@$(MAKE) --no-print-directory CONFIG=core $(RVTEST_RUNS)
	@$(MAKE) --no-print-directory CONFIG=system $(RVTEST_RUNS)

# --------------------------------------------------------------------
# Dhrystone. The benchmark sources are copied unmodified from
# tests/riscv-tests/benchmarks/dhrystone (a number is only comparable if the
# benchmark is); bench/dhrystone/port.c supplies what this bare-metal
# machine does not already have, and rv_env.h replaces the riscv-tests util.h.
#
# Timing comes from the mcycle CSR, which dhrystone.h already selects for
# __riscv. -O2 with the source's own no-inline pragma is the conventional
# Dhrystone build.
# --------------------------------------------------------------------
DHRY_DIR  := bench/dhrystone
DHRY_OUT  := build/$(CONFIG)/bench/dhrystone
DHRY_FLAGS := -march=$(MARCH) -mabi=$(MABI) $(CSTD) -O2 -Ibench/libmc -I$(DHRY_DIR) \
              -Wno-implicit-function-declaration -Wno-builtin-declaration-mismatch \
              -Wno-implicit-int -Wno-return-type
DHRY_OBJS := $(DHRY_OUT)/crt0.o $(DHRY_OUT)/dhrystone.o \
             $(DHRY_OUT)/dhrystone_main.o $(DHRY_OUT)/port.o \
             $(if $(CONFIG_BOOT),$(DHRY_OUT)/boot.o)

.PHONY: dhrystone

$(DHRY_OUT)/crt0.o: $(DHRY_DIR)/crt0.s Makefile
	mkdir -p $(dir $@)
	$(AS) $(SSFLAGS) -c $< -o $@

$(DHRY_OUT)/%.o: $(DHRY_DIR)/%.c $(DHRY_DIR)/dhrystone.h $(DHRY_DIR)/rv_env.h Makefile
	mkdir -p $(dir $@)
	$(CC) $(DHRY_FLAGS) -c $< -o $@

$(DHRY_OUT)/boot.o: tests/riscv-tests-env/boot.S Makefile
	mkdir -p $(dir $@)
	$(CC) $(SSFLAGS) -c $< -o $@

$(DHRY_OUT)/dhrystone.elf: $(DHRY_OBJS) $(LIBS) $(BENCH_LD)
	$(LD) -m $(LDEMUL) --script $(BENCH_LD) --no-warn-rwx-segments -o $@ $(DHRY_OBJS) $(LDPOSTFLAGS)

dhrystone: $(DHRY_OUT)/dhrystone.elf

# Dhrystone in simulation; DMIPS/MHz is 1e6 / (cycles per run) / 1757
DHRY_TIMEOUT ?= 5000000

.PHONY: run-dhrystone
run-dhrystone: $(DHRY_OUT)/dhrystone.elf $(TOOLS) $(SIM_IVERILOG)
	@$(HEX_CONFIG) $< $(HEX)/$(CONFIG)/dhrystone
	@cd $(HEX)/$(CONFIG)/dhrystone && $(CURDIR)/$(SIM_IVERILOG) +timeout=$(DHRY_TIMEOUT) \
		+stallrate=$(STALL_RATE) +memlatency=$(MEM_LATENCY) 2>/dev/null | \
	awk -F= '/^CYCLES=/ { c = $$2 } /^RUNS=/ { r = $$2 } \
		END { if (!r) { print "dhrystone did not finish"; exit 1 } \
		      printf "$(CONFIG): %d runs, %d cycles per run, %.3f DMIPS/MHz\n", r, c / r, 1e6 / (c / r) / 1757 }'

# --------------------------------------------------------------------
# Spike, the reference simulator for co-simulation, built from the pinned
# sim/riscv-isa-sim submodule into build/spike
# --------------------------------------------------------------------
SPIKE_SRC    := sim/riscv-isa-sim
SPIKE_PREFIX := $(CURDIR)/build/spike
SPIKE_JOBS   := $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

.PHONY: spike
spike: $(SPIKE_PREFIX)/bin/spike

$(SPIKE_PREFIX)/bin/spike:
	mkdir -p build/spike-build
	cd build/spike-build && $(CURDIR)/$(SPIKE_SRC)/configure --prefix=$(SPIKE_PREFIX)
	MAKEFLAGS= $(MAKE) -C build/spike-build -j$(SPIKE_JOBS)
	MAKEFLAGS= $(MAKE) -C build/spike-build install

# --------------------------------------------------------------------
# Lockstep co-simulation against Spike: sim/cosim.cpp steps Spike once for
# every instruction the core retires and stops at the first difference
# --------------------------------------------------------------------
$(COSIM): $(RTL_CORE) sim/cosim_top.sv sim/cosim.cpp $(SPIKE_PREFIX)/bin/spike
	mkdir -p build/cosim
	$(VERILATOR) -O3 --cc --build --exe --top-module cosim_top -Wno-fatal -DRVFI \
		--Mdir build/cosim $(RTL_INC) sim/cosim_top.sv sim/cosim.cpp -o Vcosim_top \
		-CFLAGS "-std=c++20 -I$(SPIKE_PREFIX)/include" \
		-LDFLAGS "-L$(SPIKE_PREFIX)/lib -Wl,-rpath,$(SPIKE_PREFIX)/lib -lriscv -lfesvr"

# Every riscv-test in both configurations, in lockstep with Spike
.PHONY: cosim-check
cosim-check:
	@$(MAKE) --no-print-directory CONFIG=core SIM=cosim $(RVTEST_RUNS)
	@$(MAKE) --no-print-directory CONFIG=system SIM=cosim $(RVTEST_RUNS)

# Random programs in lockstep with Spike, in CONFIG; a failing one is kept with its seed
#   make cosim-random ITERS=100 SEED=1 LENGTH=200
ITERS  ?= 50
SEED   ?= 1
LENGTH ?= 200
RVGEN_OUT := build/$(CONFIG)/rvgen

.PHONY: cosim-random
cosim-random: $(COSIM) $(TOOLS)
	@pass=0; for i in `seq $(SEED) $$(($(SEED) + $(ITERS) - 1))`; do \
		d=$(RVGEN_OUT)/$$i; mkdir -p $$d; \
		python3 tools/rvgen.py $$i $(LENGTH) > $$d/prog.S; \
		$(CC) $(RVTEST_FLAGS) -o $$d/prog.elf $$d/prog.S $(CONFIG_BOOT) || exit 1; \
		$(HEX_CONFIG) $$d/prog.elf $$d >/dev/null 2>&1 || exit 1; \
		out=`cd $$d && $(CURDIR)/$(COSIM) prog.elf $(SIM_ARGS) 2>/dev/null`; \
		if echo "$$out" | grep -q "^TOHOST=1$$"; then pass=$$((pass+1)); rm -rf $$d; \
		else echo "FAIL seed $$i: `echo "$$out" | grep -E '^(MISMATCH|TIMEOUT)'`"; \
			echo "  program kept in $$d"; exit 1; fi; \
	done; echo "$(CONFIG): $$pass random programs match"

# --------------------------------------------------------------------
# The divider's arithmetic on its own: every spec corner plus random pairs
# --------------------------------------------------------------------
.PHONY: divider-tb

build/sim/tb_divider: sim/tb_divider.sv rtl/core/divider.sv rtl/core/system.sv
	mkdir -p $(dir $@)
	$(IVERILOG) -g2012 -Irtl/core -o $@ sim/tb_divider.sv

divider-tb: build/sim/tb_divider
	./build/sim/tb_divider

# --------------------------------------------------------------------
# Line/toggle coverage over the riscv-tests suites, via Verilator
# --------------------------------------------------------------------
.PHONY: coverage

build/cov/Vtop: $(RTL_CORE) sim/verilator_top.cpp
	mkdir -p build/cov
	$(VERILATOR) -O0 --cc --build --top-module top --coverage \
		--Mdir build/cov -Wno-fatal $(RTL_INC) rtl/top.sv sim/verilator_top.cpp --exe \
		-o Vtop

coverage: build/cov/Vtop $(TOOLS)
	$(build-rvtests-both)
	@rm -rf build/cov/dat; mkdir -p build/cov/dat
	@set -e; n=0; \
	for e in $(call rvtest-elfs,core) $(call rvtest-elfs,system); do \
		t=`echo $$e | sed 's#^build/##; s#\.elf$$##'`; \
		d=$(HEX)/$$t; c=$(CURDIR)/build/cov/dat/`echo $$t | tr / -`; \
		case $$e in build/system/*) $(HEX_SYSTEM) $$e $$d ;; \
			*) $(HEX_CORE) $$e $$d ;; esac >/dev/null; \
		(cd $$d && RV32_COVERAGE_FILE=$$c.dat \
			$(CURDIR)/build/cov/Vtop >/dev/null 2>&1); n=$$((n+1)); \
		(cd $$d && RV32_STALL_RATE=128 RV32_COVERAGE_FILE=$$c-stall.dat \
			$(CURDIR)/build/cov/Vtop >/dev/null 2>&1); n=$$((n+1)); \
		(cd $$d && RV32_MEM_LATENCY=4 RV32_STALL_RATE=128 RV32_MAX_CYCLES=20000000 \
			RV32_COVERAGE_FILE=$$c-lat.dat \
			$(CURDIR)/build/cov/Vtop >/dev/null 2>&1); n=$$((n+1)); \
	done; \
	echo "ran $$n programs"
	@verilator_coverage --write build/cov/merged.dat build/cov/dat/*.dat >/dev/null
	@verilator_coverage --annotate build/cov/annotated --annotate-min 1 \
		build/cov/merged.dat 2>&1 | tail -20
	@echo ""
	@echo "uncovered points (marked %000000 in build/cov/annotated/):"
	@grep -rc "^%000000" build/cov/annotated/ 2>/dev/null | grep -v ":0$$" || \
		echo "  none"

