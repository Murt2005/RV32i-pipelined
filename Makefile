include site-config.sh

CC := $(RISCV_PREFIX)-gcc
AS := $(RISCV_PREFIX)-as
LD := $(RISCV_PREFIX)-ld
AR := $(RISCV_PREFIX)-ar
SHELL := /bin/bash

.DEFAULT_GOAL := test
.PHONY: test rv32ui rv32um rv32mi riscv-arch-test cosim-test cosim-test-rv32ui cosim-test-rv32um cosim-test-rv32mi \
        cosim-random cycle-check cycle-baseline latency-sweep coremark spike help clean FORCE
.SECONDARY:

# Configuration for single-suite targets, coremark and cosim-random:
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

# Tests run at a time by tools/run-tests.sh
JOBS ?= $(shell sysctl -n hw.ncpu 2>/dev/null || nproc)
export JOBS

# CoreMark iterations, about 50 s each on Icarus
CM_ITERS ?= 3

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
                              JOBS=$(JOBS)                       tests at a time, for every target that runs tests
make rv32ui|rv32um|rv32mi     CONFIG=$(CONFIG)                   one suite, on Icarus
                              + the options of test
make riscv-arch-test          SIM_TIMEOUT=$(ACT_TIMEOUT)           every riscv-arch-test from SDRAM, on Icarus,
                              JOBS=$(JOBS)                       building the ELFs first; needs mise and Sail
make cosim-test               the options of test           every suite in both configurations, checked against Spike
make cosim-test-rv32ui|um|mi  CONFIG=$(CONFIG)                   one suite, checked against Spike
                              + the options of test
make cosim-random             CONFIG=$(CONFIG) ITERS=$(ITERS)          random programs, checked against Spike
                              SEED=$(SEED) LENGTH=$(LENGTH)
                              + the options of test
make cycle-check              -                             cycle counts per test against tests/cycles/
make cycle-baseline           -                             record those cycle counts, overwriting them
make latency-sweep            -                             every suite at memory latency 1 to 16, then with stalls and fixed latency
make coremark                 CONFIG=$(CONFIG) CM_ITERS=$(CM_ITERS)      CoreMark on Icarus, in CoreMark/MHz
                              STALL_RATE=$(STALL_RATE) MEM_LATENCY=$(MEM_LATENCY)
make clean                    -                             delete build/, including Spike and the riscv-arch-test tools
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
DUMPHEX      := build/tools/dumphex
RUN          := tools/run-tests.sh
COSIM_RUN    := TRACE=build/trace $(RUN) $(COSIM)

RTL_INC := -Irtl/core -Irtl/mem -Irtl/bus -Isim
RTL_SRC := $(wildcard rtl/*/*.sv sim/*.sv)

$(ICARUS_SIM): $(RTL_SRC)
	@mkdir -p $(@D) build/logs; echo "building $@"
	@$(IVERILOG) -g2012 $(RTL_INC) -o $@ sim/itop.sv $(QUIET)

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

# riscv-arch-test, from SDRAM since a test keeps code and data in one image; the
# framework rebuilds ELFs only when the config or the submodule changes
ACT_ELF_DIR := build/riscv-arch-test/rv32im-pipelined/elfs
ACT_TIMEOUT := $(if $(filter command line,$(origin SIM_TIMEOUT)),$(SIM_TIMEOUT),1000000)

riscv-arch-test: $(DUMPHEX) $(ICARUS_SIM)
	@tools/build-arch-tests.sh
	@$(RUN) $(ICARUS_SIM) +timeout=$(ACT_TIMEOUT) $$(find $(ACT_ELF_DIR) -name '*.elf' | sort)

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

# Every suite against slow memory, then with stalls too; each run is latency:stall rate:watchdog[:fixed]
# fixed makes every access wait the full latency, which random delays never do for long
SWEEP := 1:0:300000 2:0:450000 4:0:750000 8:0:1350000 16:0:2550000 8:128:4000000 \
         2:0:1500000:fixed 4:0:2500000:fixed 4:64:4000000:fixed

latency-sweep: $(DUMPHEX) $(ICARUS_SIM) $(ALL_ELFS)
	@rc=0; for r in $(SWEEP); do set -- $${r//:/ }; \
		fixed=$$([ "$$4" = fixed ] && echo 1 || echo 0); \
		log=build/sweep-$$1-$$2$${4:+-$$4}.log; printf 'MEM_LATENCY=%-3s STALL_RATE=%-4s %-6s' $$1 $$2 "$$4"; \
		$(RUN) $(ICARUS_SIM) +memlatency=$$1 +memfixed=$$fixed +stallrate=$$2 +timeout=$$3 $(ALL_ELFS) > $$log \
			&& echo ok || { echo "FAILED, see $$log"; rc=1; }; \
	done; exit $$rc

# CoreMark, unmodified from the bench/coremark submodule plus the port in
# bench/coremark-port; CoreMark/MHz is iterations * 1e6 / cycles. Simulation can't
# meet CoreMark's 10 s minimum, so only its CRC checks decide pass or fail
CM       := build/$(CONFIG)/bench/coremark
CM_LD    := bench/$(if $(filter system,$(CONFIG)),link-system,link).ld
CM_OBJS  := $(addprefix $(CM)/,crt0.o core_list_join.o core_main.o core_matrix.o core_state.o core_util.o \
            core_portme.o ee_printf.o $(if $(filter system,$(CONFIG)),boot.o))
CM_OPT   := -O2
CM_FLAGS := -march=$(MARCH) -mabi=$(MABI) $(CM_OPT) -Ibench/coremark -Ibench/coremark-port \
            -DITERATIONS=$(CM_ITERS) -DFLAGS_STR='"$(CM_OPT)"'

$(CM)/%.o: bench/coremark/%.c bench/coremark/coremark.h bench/coremark-port/core_portme.h
	@mkdir -p $(@D)
	$(CC) $(CM_FLAGS) -c $< -o $@

# Rebuilt every time, since ITERATIONS only reaches CoreMark through it
$(CM)/core_portme.o: bench/coremark-port/core_portme.c FORCE
	@mkdir -p $(@D)
	$(CC) $(CM_FLAGS) -c $< -o $@

$(CM)/%.o: bench/coremark-port/%.c bench/coremark/coremark.h bench/coremark-port/core_portme.h
	@mkdir -p $(@D)
	$(CC) $(CM_FLAGS) -c $< -o $@

$(CM)/%.o: bench/coremark-port/%.s
	@mkdir -p $(@D)
	$(CC) $(CM_FLAGS) -c $< -o $@

$(CM)/boot.o: $(RVENV)/boot.S
	@mkdir -p $(@D)
	$(CC) $(CM_FLAGS) -c $< -o $@

$(CM)/coremark.elf: $(CM_OBJS) $(CM_LD)
	$(LD) -m $(LDEMUL) --script $(CM_LD) --no-warn-rwx-segments -o $@ $(CM_OBJS) -L$(RISCV_LIB) -lgcc

coremark: $(CM)/coremark.elf $(DUMPHEX) $(ICARUS_SIM)
	@tools/elftohex-$(CONFIG).sh $< build/hex/$(CONFIG)/coremark
	@cd build/hex/$(CONFIG)/coremark && $(CURDIR)/$(ICARUS_SIM) +timeout=$$(( ($(CM_ITERS) + 2) * 1000000 )) \
		+stallrate=$(STALL_RATE) +memlatency=$(MEM_LATENCY) > $(CURDIR)/$(CM)/coremark.log 2>/dev/null; \
	awk -F': *' '/^Total ticks/ { t = $$2 } /^Iterations  / { n = $$2 } \
		/ERROR!/ && !/at least 10 secs/ { bad = 1 } \
		END { if (!n || !t || bad) { print "coremark failed, see $(CM)/coremark.log"; exit 1 } \
		      printf "$(CONFIG): %d iterations, %d cycles per iteration, %.3f CoreMark/MHz\n", n, t / n, n * 1e6 / t }' \
		$(CURDIR)/$(CM)/coremark.log

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
