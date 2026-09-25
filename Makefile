include site-config.sh

CC := $(RISCV_PREFIX)-gcc
AS := $(RISCV_PREFIX)-as
LD := $(RISCV_PREFIX)-ld
AR := $(RISCV_PREFIX)-ar
SHELL := /bin/bash

.DEFAULT_GOAL := test
.PHONY: test rv32ui rv32um rv32mi cosim-test cosim-test-rv32ui cosim-test-rv32um cosim-test-rv32mi \
        cosim-random cycle-check cycle-baseline latency-sweep dhrystone divider coverage spike help clean FORCE
.SECONDARY:

# Configuration for single-suite targets, dhrystone and cosim-random:
# core runs from IMEM/DMEM, system from SDRAM through the caches
CONFIG ?= core
ifeq ($(filter $(CONFIG),core system),)
$(error CONFIG must be core or system)
endif

# Random stalls out of 256, extra memory latency of 0..N cycles, and the watchdog in cycles
STALL_RATE  ?= 0
MEM_LATENCY ?= 0
SIM_TIMEOUT ?= 120000
SIM_ARGS := +stallrate=$(STALL_RATE) +memlatency=$(MEM_LATENCY) +timeout=$(SIM_TIMEOUT)

# Random programs for cosim-random
ITERS  ?= 50
SEED   ?= 1
LENGTH ?= 200

# Build steps keep their output in build/logs/ and show it only if they fail
QUIET = > build/logs/$(@F).log 2>&1 || { tail -20 build/logs/$(@F).log; echo "build failed, full log in build/logs/$(@F).log"; exit 1; }

define HELP
command                       options (default)             what it does
make [test]                   STALL_RATE=$(STALL_RATE)                  every riscv-test suite in both configurations, on Icarus
                              MEM_LATENCY=$(MEM_LATENCY)
                              SIM_TIMEOUT=$(SIM_TIMEOUT)
make rv32ui|rv32um|rv32mi     CONFIG=$(CONFIG)                   one suite, on Icarus
                              + the options of test
make cosim-test               the options of test           every suite in both configurations, checked against Spike
make cosim-test-rv32ui|um|mi  CONFIG=$(CONFIG)                   one suite, checked against Spike
                              + the options of test
make cosim-random             CONFIG=$(CONFIG) ITERS=$(ITERS)          random programs, checked against Spike
                              SEED=$(SEED) LENGTH=$(LENGTH)
                              + the options of test
make cycle-check              -                             cycle counts per test against tests/cycles/
make cycle-baseline           -                             record those cycle counts, overwriting them
make latency-sweep            -                             every suite at memory latency 1 to 16, then with stalls
make dhrystone                CONFIG=$(CONFIG) STALL_RATE=$(STALL_RATE)      Dhrystone on Icarus, in DMIPS/MHz
                              MEM_LATENCY=$(MEM_LATENCY)
make divider                  -                             the divider testbench
make coverage                 -                             Verilator coverage over every suite, per file
make clean                    -                             delete build/, including Spike
endef

help:
	$(info $(HELP))
	@:

clean:
	rm -rf build

FORCE:

# Simulators
ICARUS_SIM := build/sim/itop
COSIM        := build/cosim/Vcosim_top
COV_SIM      := build/cov/Vtop
DUMPHEX      := build/tools/dumphex
RUN          := tools/run-tests.sh
COSIM_RUN    := TRACE=build/trace $(RUN) $(COSIM)

RTL_INC := -Irtl/core -Irtl/mem -Irtl/bus -Isim
RTL_SRC := $(wildcard rtl/*/*.sv sim/*.sv)

$(ICARUS_SIM): $(RTL_SRC)
	@mkdir -p $(@D) build/logs; echo "building $@"
	@$(IVERILOG) -g2012 $(RTL_INC) -o $@ sim/itop.sv $(QUIET)

$(COV_SIM): $(RTL_SRC) sim/verilator-top.cpp
	@mkdir -p $(@D) build/logs; echo "building $@"
	@$(VERILATOR) -O0 --cc --build --exe --top-module top --coverage -Wno-fatal \
		--Mdir $(@D) $(RTL_INC) sim/top.sv sim/verilator-top.cpp -o Vtop $(QUIET)

$(DUMPHEX): tools/dumphex.c
	@mkdir -p $(@D) build/logs
	@gcc -o $@ $< $(QUIET)

# riscv-tests; fence_i needs self-modifying code, ma_data misaligned access, pmpaddr PMP
SUITES := rv32ui rv32um rv32mi
rv32ui_EXCLUDE := fence_i ma_data
rv32mi_EXCLUDE := pmpaddr

tests-of = $(filter-out $($(1)_EXCLUDE),$(basename $(notdir $(wildcard tests/riscv-tests/isa/$(1)/*.S))))
elfs     = $(foreach s,$(or $(2),$(SUITES)),$(patsubst %,build/$(1)/riscv-tests/$(s)/%.elf,$(call tests-of,$(s))))
ALL_ELFS := $(call elfs,core) $(call elfs,system)

RVENV := tests/riscv-tests-env
RVTEST_FLAGS := -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles -fno-builtin \
                -Itests/riscv-tests/env/p -Itests/riscv-tests/env -Itests/riscv-tests/isa/macros/scalar \
                -Wl,--no-warn-rwx-segments

# $(call elf-rules,config,linker script,boot stub): riscv-tests and random programs
define elf-rules
build/$(1)/riscv-tests/%.elf: tests/riscv-tests/isa/%.S $(2) $(3)
	@mkdir -p $$(@D)
	@$(CC) $(RVTEST_FLAGS) -T $(2) -o $$@ $$< $(3)
build/$(1)/rvgen/%.elf: build/rvgen/%.S $(2) $(3)
	@mkdir -p $$(@D)
	@$(CC) $(RVTEST_FLAGS) -T $(2) -o $$@ $$< $(3)
endef
$(eval $(call elf-rules,core,$(RVENV)/link.ld,))
$(eval $(call elf-rules,system,$(RVENV)/link-system.ld,$(RVENV)/boot.S))

test: $(DUMPHEX) $(ICARUS_SIM) $(ALL_ELFS)
	@$(RUN) $(ICARUS_SIM) $(SIM_ARGS) $(ALL_ELFS)

$(foreach s,$(SUITES),$(eval $(s) cosim-test-$(s): $(call elfs,$(CONFIG),$(s))))
$(SUITES): $(DUMPHEX) $(ICARUS_SIM)
	@$(RUN) $(ICARUS_SIM) $(SIM_ARGS) $(call elfs,$(CONFIG),$@)

# Cycle counts per test against tests/cycles/<config>.json; any difference means timing changed
define cycle-run
@$(RUN) $(ICARUS_SIM) $(call elfs,$(1)) > build/cycles/$(1).log
@echo "== $(1)"; python3 tools/cycle-report.py $(MODE) tests/cycles/$(1).json build/cycles/$(1).log
endef

cycle-baseline: MODE := --save
cycle-check:    MODE := --compare
cycle-baseline cycle-check: $(DUMPHEX) $(ICARUS_SIM) $(ALL_ELFS)
	@mkdir -p build/cycles
	$(call cycle-run,core)
	$(call cycle-run,system)

# Every suite against slow memory, then with stalls too; each run is latency:stall rate:watchdog
SWEEP := 1:0:300000 2:0:450000 4:0:750000 8:0:1350000 16:0:2550000 8:128:4000000

latency-sweep: $(DUMPHEX) $(ICARUS_SIM) $(ALL_ELFS)
	@rc=0; for r in $(SWEEP); do set -- $${r//:/ }; \
		log=build/sweep-$$1-$$2.log; printf 'MEM_LATENCY=%-3s STALL_RATE=%-4s ' $$1 $$2; \
		$(RUN) $(ICARUS_SIM) +memlatency=$$1 +stallrate=$$2 +timeout=$$3 $(ALL_ELFS) > $$log \
			&& echo ok || { echo "FAILED, see $$log"; rc=1; }; \
	done; exit $$rc

# libmc, the small C library Dhrystone links against
LIBMC     := build/libmc/libmc.a
LIBMC_OBJ := $(patsubst bench/libmc/%,build/libmc/%.o,$(basename $(sort $(wildcard bench/libmc/*.[cs]))))

build/libmc/%.o: bench/libmc/%.c bench/libmc/libmc.h bench/libmc/base.h
	@mkdir -p $(@D)
	$(CC) -march=$(MARCH) -mabi=$(MABI) -std=gnu99 -O1 -Wno-builtin-declaration-mismatch -c $< -o $@

build/libmc/%.o: bench/libmc/%.s
	@mkdir -p $(@D)
	$(AS) -march=$(MARCH) -mabi=$(MABI) $< -o $@

$(LIBMC): $(LIBMC_OBJ)
	$(AR) rcs $@ $^

# Dhrystone, unmodified from riscv-tests plus bench/dhrystone/port.c; DMIPS/MHz is 1e6 / cycles per run / 1757
DHRY       := build/$(CONFIG)/bench/dhrystone
DHRY_LD    := bench/$(if $(filter system,$(CONFIG)),link-system,link).ld
DHRY_OBJS  := $(addprefix $(DHRY)/,crt0.o dhrystone.o dhrystone_main.o port.o $(if $(filter system,$(CONFIG)),boot.o))
DHRY_FLAGS := -march=$(MARCH) -mabi=$(MABI) -std=gnu17 -O2 -Ibench/libmc -Ibench/dhrystone \
              -Wno-implicit-function-declaration -Wno-builtin-declaration-mismatch -Wno-implicit-int -Wno-return-type

$(DHRY)/%.o: bench/dhrystone/%.c bench/dhrystone/dhrystone.h bench/dhrystone/rv_env.h
	@mkdir -p $(@D)
	$(CC) $(DHRY_FLAGS) -c $< -o $@

$(DHRY)/%.o: bench/dhrystone/%.s
	@mkdir -p $(@D)
	$(CC) $(DHRY_FLAGS) -c $< -o $@

$(DHRY)/boot.o: $(RVENV)/boot.S
	@mkdir -p $(@D)
	$(CC) $(DHRY_FLAGS) -c $< -o $@

$(DHRY)/dhrystone.elf: $(DHRY_OBJS) $(LIBMC) $(DHRY_LD)
	$(LD) -m $(LDEMUL) --script $(DHRY_LD) --no-warn-rwx-segments -o $@ $(DHRY_OBJS) \
		-Lbuild/libmc -lmc -L$(RISCV_LIB) -lgcc

dhrystone: $(DHRY)/dhrystone.elf $(DUMPHEX) $(ICARUS_SIM)
	@tools/elftohex-$(CONFIG).sh $< build/hex/$(CONFIG)/dhrystone
	@cd build/hex/$(CONFIG)/dhrystone && $(CURDIR)/$(ICARUS_SIM) +timeout=5000000 \
		+stallrate=$(STALL_RATE) +memlatency=$(MEM_LATENCY) 2>/dev/null | \
	awk -F= '/^CYCLES=/ { c = $$2 } /^RUNS=/ { r = $$2 } \
		END { if (!r) { print "dhrystone did not finish"; exit 1 } \
		      printf "$(CONFIG): %d runs, %d cycles per run, %.3f DMIPS/MHz\n", r, c / r, 1e6 / (c / r) / 1757 }'

build/sim/tb-divider: tests/tb-divider.sv rtl/core/divider.sv rtl/core/system.sv
	@mkdir -p $(@D) build/logs
	@$(IVERILOG) -g2012 -Irtl/core -o $@ $< $(QUIET)

divider: build/sim/tb-divider
	@$<

# Spike, built from the cosim/riscv-isa-sim submodule into build/spike
SPIKE := $(CURDIR)/build/spike

spike: $(SPIKE)/bin/spike

$(SPIKE)/bin/spike:
	@mkdir -p build/spike-build build/logs; echo "building spike, which takes a few minutes"
	@(cd build/spike-build && $(CURDIR)/cosim/riscv-isa-sim/configure --prefix=$(SPIKE) && \
		MAKEFLAGS= $(MAKE) -j$(shell sysctl -n hw.ncpu 2>/dev/null || nproc) && \
		MAKEFLAGS= $(MAKE) install) $(QUIET)

$(COSIM): $(RTL_SRC) cosim/cosim-top.sv cosim/cosim.cpp $(SPIKE)/bin/spike
	@mkdir -p $(@D) build/logs; echo "building $@"
	@$(VERILATOR) -O3 --cc --build --exe --top-module cosim_top -Wno-fatal -DRVFI \
		--Mdir $(@D) $(RTL_INC) cosim/cosim-top.sv cosim/cosim.cpp -o Vcosim_top \
		-CFLAGS "-std=c++20 -I$(SPIKE)/include" \
		-LDFLAGS "-L$(SPIKE)/lib -Wl,-rpath,$(SPIKE)/lib -lriscv -lfesvr" $(QUIET)

cosim-test: $(DUMPHEX) $(COSIM) $(ALL_ELFS)
	@$(COSIM_RUN) $(SIM_ARGS) $(ALL_ELFS)

$(addprefix cosim-test-,$(SUITES)): $(DUMPHEX) $(COSIM)
	@$(COSIM_RUN) $(SIM_ARGS) $(call elfs,$(CONFIG),$(@:cosim-test-%=%))

# Random programs from tools/rvgen.py, regenerated on every run
RVGEN_ELFS := $(patsubst %,build/$(CONFIG)/rvgen/%.elf,$(shell seq $(SEED) $$(($(SEED) + $(ITERS) - 1))))

build/rvgen/%.S: tools/rvgen.py FORCE
	@mkdir -p $(@D)
	@python3 tools/rvgen.py $* $(LENGTH) > $@

cosim-random: $(DUMPHEX) $(COSIM) $(RVGEN_ELFS)
	@$(COSIM_RUN) $(SIM_ARGS) $(RVGEN_ELFS)

# Line, branch and toggle coverage over every suite in both configurations: plain, with stalls, and with slow memory
define coverage-run
@printf '%-8s ' $(1); COVERAGE=build/cov/dat/$(1) $(RUN) $(COV_SIM) +timeout=20000000 $(2) $(ALL_ELFS) \
	> build/cov/$(1).log && tail -1 build/cov/$(1).log || { grep ^FAIL build/cov/$(1).log; exit 1; }
endef

coverage: $(DUMPHEX) $(COV_SIM) $(ALL_ELFS)
	@rm -rf build/cov/dat build/cov/annotated
	$(call coverage-run,plain,)
	$(call coverage-run,stall,+stallrate=128)
	$(call coverage-run,latency,+memlatency=4 +stallrate=128)
	@verilator_coverage --write build/cov/merged.dat build/cov/dat/*/*.dat >/dev/null
	@verilator_coverage --annotate build/cov/annotated --annotate-min 1 build/cov/merged.dat >/dev/null
	@python3 tools/coverage-report.py build/cov/merged.dat
