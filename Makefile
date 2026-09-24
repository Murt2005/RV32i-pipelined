#

include site-config.sh

# Without this the first rule in the file, sw/libmc/libmc.a, would be the default.
.DEFAULT_GOAL := test

CC=$(RISCV_PREFIX)-gcc
AS=$(RISCV_PREFIX)-as
LD=$(RISCV_PREFIX)-ld

# MARCH/MABI come from site-config.sh, so this file and sw/libmc/Makefile cannot
# drift apart. -mabi is now explicit everywhere: it is the default for rv32i so
# omitting it happened to work, but RISCV_LIB points at one specific multilib
# directory and the two have to agree.
# GCC 15 defaults to C23, where bool/true/false are keywords -- and sw/libmc/base.h
# has `typedef unsigned int bool`, which C23 rejects outright. Pinning the
# standard keeps this legacy C compiling with exactly the semantics it was
# written against, including a 4-byte bool, rather than quietly changing type
# sizes underneath it. sw/libmc/Makefile already pins gnu99 for the same reason.
# Nothing caught this until a C program was built, because every test in the
# regression suite is hand-written assembly.
CSTD=-std=gnu17

SSFLAGS=-march=$(MARCH) -mabi=$(MABI)
LDPOSTFLAGS= -Lsw/libmc -lmc -L$(RISCV_LIB) -lgcc
TOOLS=build/tools/dumphex

# ELF to hex images: the core configuration (IMEM and DMEM) and the system
# configuration (a boot stub in IMEM, the program in SDRAM through the caches)
HEX_CORE   := /bin/bash tools/elftohex-core.sh
HEX_SYSTEM := /bin/bash tools/elftohex-system.sh
LIBS=sw/libmc/libmc.a

SIM_IVERILOG := build/sim/result-iverilog

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
LIBMC_SRC := $(wildcard sw/libmc/*.c) $(wildcard sw/libmc/*.s) $(wildcard sw/libmc/*.h) \
             sw/libmc/Makefile site-config.sh Makefile

sw/libmc/libmc.a: $(LIBMC_SRC)
	$(MAKE) -C sw/libmc clean
	$(MAKE) -C sw/libmc

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

# Same design with the RVFI commit port enabled. Separate binary so the normal
# simulator, and the synthesised build, carry none of the instrumentation.
build/sim/result-rvfi: $(RTL_SRC)
	mkdir -p $(dir $@)
	$(IVERILOG) -g2012 $(RTL_INC) -DRVFI -o $@ sim/itop.sv

# RVFI_LATENCY sweeps the commit record against a slow memory as well as a fast
# one. The record has to be right in both cases and, until this existed, only the
# fast one was ever checked.
RVFI_LATENCY ?= 0

.PHONY: rvfi-check rvfi-check-slow
rvfi-check: build/sim/result-rvfi $(TOOLS) riscv-tests riscv-tests-m riscv-tests-mi
	python3 tools/rvfi_check.py --all --mem-latency $(RVFI_LATENCY)

rvfi-check-slow: build/sim/result-rvfi $(TOOLS) riscv-tests riscv-tests-m riscv-tests-mi
	@rc=0; for d in 1 4 8; do \
		printf 'rvfi mem-latency %-3s ' $$d; \
		python3 tools/rvfi_check.py --all --mem-latency $$d > build/rvfi-$$d.log 2>&1 \
			&& echo ok || { echo "FAILED -- build/rvfi-$$d.log"; rc=1; }; \
	done; exit $$rc


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
CYCLE_SUITES := rv32ui:run-riscv-tests-iverilog \
                sdram:run-riscv-tests-sdram-iverilog

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
	$(MAKE) -C sw/libmc clean


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
RVTESTS_ELF   := $(addprefix build/riscv-tests/,$(addsuffix .elf,$(RVTESTS)))

RVTEST_LD    := tests/riscv-tests-env/link.ld
RVTEST_FLAGS := -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles -fno-builtin \
                -Itests/riscv-tests/env/p -Itests/riscv-tests/env \
                -Itests/riscv-tests/isa/macros/scalar -T $(RVTEST_LD)

# $(call run-rvtests,suite,tests,elf-dir,hex-converter)
define run-rvtests
@pass=0; fail=0; \
	for t in $(2); do \
		d=$(HEX)/$(3)/$$t; \
		if ! $(4) build/$(3)/$$t.elf $$d >/dev/null 2>&1; then \
			fail=$$((fail+1)); echo "FAIL $(1)-$$t  (hex conversion)"; continue; \
		fi; \
		raw=`cd $$d && $(CURDIR)/$(SIM_IVERILOG) $(SIM_ARGS) 2>/dev/null`; \
		th=`echo "$$raw" | sed -n 's/^TOHOST=\([0-9]*\).*/\1/p' | head -1`; \
		cyc=`echo "$$raw" | sed -n 's/.*finish called at \([0-9]*\).*/\1/p' | head -1`; \
		if [ "$$th" = "1" ]; then \
			pass=$$((pass+1)); echo "PASS $(1)-$$t  finish=$$cyc"; \
		elif [ -n "$$th" ]; then \
			fail=$$((fail+1)); echo "FAIL $(1)-$$t  (test $$((th >> 1)))"; \
		else \
			fail=$$((fail+1)); echo "FAIL $(1)-$$t  (no tohost write)"; \
		fi; \
	done; \
	echo ""; echo "$$pass passed, $$fail failed, `echo $(2) | wc -w | tr -d ' '` total"; \
	[ $$fail -eq 0 ]
endef

.PHONY: riscv-tests run-riscv-tests-iverilog

build/riscv-tests/%.elf: $(RVTESTS_DIR)/%.S $(RVTEST_LD)
	mkdir -p $(dir $@)
	$(CC) $(RVTEST_FLAGS) -o $@ $<

riscv-tests: $(RVTESTS_ELF)

run-riscv-tests-iverilog: $(TOOLS) $(SIM_IVERILOG) riscv-tests
	$(call run-rvtests,rv32ui,$(RVTESTS),riscv-tests,$(HEX_CORE))

# --------------------------------------------------------------------
# Programs that run from SDRAM, linked against newlib.
#
# Anything with a C library in it is far too large for the 64 KiB IMEM, so these
# link .text, .rodata, .data and .bss into SDRAM and leave only a reset stub at
# 0x00010000.
#
# newlib rather than libmc: libmc has no malloc, no file I/O and no memcpy, and
# its printf drops the `l` in %ld. libmc is untouched and Dhrystone still uses it.
#
# sw/runtime is the reset stub, syscalls and linker script every such program
# shares; sw/examples holds the small programs that exercise it.
# --------------------------------------------------------------------
RUNTIME_DIR  := sw/runtime
RUNTIME_OUT  := build/sw/runtime
EXAMPLES_DIR := sw/examples
EXAMPLES_OUT := build/sw/examples

# -mstrict-align is not optional on this core. RISC-V leaves misaligned access
# implementation-defined and GCC assumes it works, so it will happily emit an
# unaligned word load to copy a struct. This core traps instead, and mtvec is
# zero, so the trap lands on unmapped memory and the machine wedges executing
# illegal instructions -- a long way from the store that caused it.
SDRAM_CFLAGS := -march=$(MARCH) -mabi=$(MABI) $(CSTD) -O2 -Wall -mstrict-align \
                -ffunction-sections -fdata-sections
SDRAM_LDFLAGS := -m $(LDEMUL) -T $(RUNTIME_DIR)/link.ld --gc-sections

# newlib and libgcc for this multilib. Order matters: libc needs libgcc, and the
# syscalls object has to come before libc so the linker resolves _write and the
# rest from here rather than pulling in newlib's stubs.
NEWLIB_DIR := $(shell $(CC) -march=$(MARCH) -mabi=$(MABI) -print-sysroot)/lib/rv32im/ilp32
SDRAM_LIBS := -L$(NEWLIB_DIR) -lc -lm -L$(RISCV_LIB) -lgcc

.PHONY: sdram-progs run-sdram-hello

RUNTIME_OBJS := $(RUNTIME_OUT)/boot.o $(RUNTIME_OUT)/syscalls.o

$(RUNTIME_OUT)/%.o: $(RUNTIME_DIR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(SDRAM_CFLAGS) -c $< -o $@

$(RUNTIME_OUT)/%.o: $(RUNTIME_DIR)/%.s
	@mkdir -p $(dir $@)
	$(AS) -march=$(MARCH) -mabi=$(MABI) -c $< -o $@

$(EXAMPLES_OUT)/%.o: $(EXAMPLES_DIR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(SDRAM_CFLAGS) -c $< -o $@

$(EXAMPLES_OUT)/hello.elf: $(RUNTIME_OBJS) $(EXAMPLES_OUT)/hello.o $(RUNTIME_DIR)/link.ld
	@mkdir -p $(dir $@)
	$(LD) $(SDRAM_LDFLAGS) -o $@ $(RUNTIME_OBJS) $(EXAMPLES_OUT)/hello.o $(SDRAM_LIBS)

sdram-progs: $(EXAMPLES_OUT)/hello.elf

# hello runs for about 1.5M cycles, well past the default watchdog
HELLO_TIMEOUT ?= 5000000

run-sdram-hello: $(EXAMPLES_OUT)/hello.elf $(TOOLS) $(SIM_IVERILOG)
	$(HEX_SYSTEM) $(EXAMPLES_OUT)/hello.elf $(HEX)/examples/hello
	cd $(HEX)/examples/hello && $(CURDIR)/$(SIM_IVERILOG) \
		+stallrate=$(STALL_RATE) +memlatency=$(MEM_LATENCY) +timeout=$(HELLO_TIMEOUT)

# --------------------------------------------------------------------
# Official riscv-tests rv32um suite (M extension).
# --------------------------------------------------------------------
RVTESTS_M_DIR := tests/riscv-tests/isa/rv32um
RVTESTS_M     := $(basename $(notdir $(wildcard $(RVTESTS_M_DIR)/*.S)))
RVTESTS_M_ELF := $(addprefix build/riscv-tests-m/,$(addsuffix .elf,$(RVTESTS_M)))

.PHONY: riscv-tests-m run-riscv-tests-m-iverilog

build/riscv-tests-m/%.elf: $(RVTESTS_M_DIR)/%.S $(RVTEST_LD)
	mkdir -p $(dir $@)
	$(CC) $(RVTEST_FLAGS) -o $@ $<

riscv-tests-m: $(RVTESTS_M_ELF)

run-riscv-tests-m-iverilog: $(TOOLS) $(SIM_IVERILOG) riscv-tests-m
	$(call run-rvtests,rv32um,$(RVTESTS_M),riscv-tests-m,$(HEX_CORE))

# --------------------------------------------------------------------
# Official riscv-tests rv32mi suite (machine-mode CSRs and exceptions).
# --------------------------------------------------------------------
RVTESTS_MI_DIR := tests/riscv-tests/isa/rv32mi

# pmpaddr: assumes physical memory protection, which this core does not have.
RVTESTS_MI_EXCLUDE := pmpaddr

RVTESTS_MI     := $(filter-out $(RVTESTS_MI_EXCLUDE),$(basename $(notdir $(wildcard $(RVTESTS_MI_DIR)/*.S))))
RVTESTS_MI_ELF := $(addprefix build/riscv-tests-mi/,$(addsuffix .elf,$(RVTESTS_MI)))

.PHONY: riscv-tests-mi run-riscv-tests-mi-iverilog

build/riscv-tests-mi/%.elf: $(RVTESTS_MI_DIR)/%.S $(RVTEST_LD)
	mkdir -p $(dir $@)
	$(CC) $(RVTEST_FLAGS) -o $@ $<

riscv-tests-mi: $(RVTESTS_MI_ELF)

run-riscv-tests-mi-iverilog: $(TOOLS) $(SIM_IVERILOG) riscv-tests-mi
	$(call run-rvtests,rv32mi,$(RVTESTS_MI),riscv-tests-mi,$(HEX_CORE))

# --------------------------------------------------------------------
# The same three suites run from SDRAM, so every fetch goes through the
# instruction cache and every load and store through the data cache
# --------------------------------------------------------------------
RVTEST_SDRAM_LD    := tests/riscv-tests-env/link-sdram.ld
RVTEST_SDRAM_BOOT  := tests/riscv-tests-env/boot.S
RVTEST_SDRAM_FLAGS := $(filter-out -T $(RVTEST_LD),$(RVTEST_FLAGS)) -T $(RVTEST_SDRAM_LD) \
                      -Wl,--no-warn-rwx-segments
RVTEST_SDRAM_OUT   := build/riscv-tests-sdram

RVTESTS_SDRAM_ELF := $(addprefix $(RVTEST_SDRAM_OUT)/rv32ui/,$(addsuffix .elf,$(RVTESTS))) \
                     $(addprefix $(RVTEST_SDRAM_OUT)/rv32um/,$(addsuffix .elf,$(RVTESTS_M))) \
                     $(addprefix $(RVTEST_SDRAM_OUT)/rv32mi/,$(addsuffix .elf,$(RVTESTS_MI)))

define rvtest-sdram-rule
$(RVTEST_SDRAM_OUT)/$(1)/%.elf: $(2)/%.S $(RVTEST_SDRAM_LD) $(RVTEST_SDRAM_BOOT)
	mkdir -p $$(dir $$@)
	$(CC) $(RVTEST_SDRAM_FLAGS) -o $$@ $$< $(RVTEST_SDRAM_BOOT)
endef
$(eval $(call rvtest-sdram-rule,rv32ui,$(RVTESTS_DIR)))
$(eval $(call rvtest-sdram-rule,rv32um,$(RVTESTS_M_DIR)))
$(eval $(call rvtest-sdram-rule,rv32mi,$(RVTESTS_MI_DIR)))

.PHONY: riscv-tests-sdram run-riscv-tests-sdram-iverilog

riscv-tests-sdram: $(RVTESTS_SDRAM_ELF)

run-riscv-tests-sdram-iverilog: $(TOOLS) $(SIM_IVERILOG) riscv-tests-sdram
	$(call run-rvtests,rv32ui-sdram,$(RVTESTS),riscv-tests-sdram/rv32ui,$(HEX_SYSTEM))
	$(call run-rvtests,rv32um-sdram,$(RVTESTS_M),riscv-tests-sdram/rv32um,$(HEX_SYSTEM))
	$(call run-rvtests,rv32mi-sdram,$(RVTESTS_MI),riscv-tests-sdram/rv32mi,$(HEX_SYSTEM))

# Every riscv-tests suite, in the core configuration and from SDRAM; the default target
.PHONY: test
test: run-riscv-tests-iverilog run-riscv-tests-m-iverilog run-riscv-tests-mi-iverilog \
      run-riscv-tests-sdram-iverilog

# --------------------------------------------------------------------
# Dhrystone. The benchmark sources are copied unmodified from
# tests/riscv-tests/benchmarks/dhrystone (a number is only comparable if the
# benchmark is); sw/bench/dhrystone/port.c supplies what this bare-metal
# machine does not already have, and rv_env.h replaces the riscv-tests util.h.
#
# Timing comes from the mcycle CSR, which dhrystone.h already selects for
# __riscv. -O2 with the source's own no-inline pragma is the conventional
# Dhrystone build.
# --------------------------------------------------------------------
DHRY_DIR  := sw/bench/dhrystone
DHRY_OUT  := build/sw/bench/dhrystone
DHRY_FLAGS := -march=$(MARCH) -mabi=$(MABI) $(CSTD) -O2 -Isw/libmc -I$(DHRY_DIR) \
              -Wno-implicit-function-declaration -Wno-builtin-declaration-mismatch \
              -Wno-implicit-int -Wno-return-type
DHRY_OBJS := $(DHRY_OUT)/crt0.o $(DHRY_OUT)/dhrystone.o \
             $(DHRY_OUT)/dhrystone_main.o $(DHRY_OUT)/port.o

.PHONY: dhrystone

$(DHRY_OUT)/crt0.o: $(DHRY_DIR)/crt0.s Makefile
	mkdir -p $(dir $@)
	$(AS) $(SSFLAGS) -c $< -o $@

$(DHRY_OUT)/%.o: $(DHRY_DIR)/%.c $(DHRY_DIR)/dhrystone.h $(DHRY_DIR)/rv_env.h Makefile
	mkdir -p $(dir $@)
	$(CC) $(DHRY_FLAGS) -c $< -o $@

$(DHRY_OUT)/dhrystone.elf: $(DHRY_OBJS) $(LIBS) sw/bench/link.ld
	$(LD) -m $(LDEMUL) --script sw/bench/link.ld -o $@ $(DHRY_OBJS) $(LDPOSTFLAGS)

dhrystone: $(DHRY_OUT)/dhrystone.elf

# Dhrystone in simulation; DMIPS/MHz is 1e6 / (cycles per run) / 1757
DHRY_TIMEOUT ?= 5000000

.PHONY: run-dhrystone
run-dhrystone: $(DHRY_OUT)/dhrystone.elf $(TOOLS) $(SIM_IVERILOG)
	@$(HEX_CORE) $< $(HEX)/dhrystone
	@cd $(HEX)/dhrystone && $(CURDIR)/$(SIM_IVERILOG) +timeout=$(DHRY_TIMEOUT) \
		+stallrate=$(STALL_RATE) +memlatency=$(MEM_LATENCY) 2>/dev/null | \
	awk -F= '/^CYCLES=/ { c = $$2 } /^RUNS=/ { r = $$2 } \
		END { if (!r) { print "dhrystone did not finish"; exit 1 } \
		      printf "%d runs, %d cycles per run, %.3f DMIPS/MHz\n", r, c / r, 1e6 / (c / r) / 1757 }'

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

coverage: build/cov/Vtop $(TOOLS) riscv-tests riscv-tests-m riscv-tests-mi riscv-tests-sdram
	@rm -rf build/cov/dat; mkdir -p build/cov/dat
	@set -e; n=0; \
	for e in $(RVTESTS_ELF) $(RVTESTS_M_ELF) $(RVTESTS_MI_ELF) $(RVTESTS_SDRAM_ELF); do \
		t=`echo $$e | sed 's#^build/##; s#\.elf$$##'`; \
		d=$(HEX)/$$t; c=$(CURDIR)/build/cov/dat/`echo $$t | tr / -`; \
		case $$e in $(RVTEST_SDRAM_OUT)/*) $(HEX_SYSTEM) $$e $$d ;; \
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

