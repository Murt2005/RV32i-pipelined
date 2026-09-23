# riscv-formal checks for the core
# make run-insn, make run-consistency, make run-m, or make one CHECK=reg_ch0

ROOT     := ..
RTL      := $(ROOT)/rtl
# rf/ is the cores/<core> layout genchecks.py expects, built from symlinks
BASEDIR  := rf
CORE     := rv32
CHECKDIR := $(BASEDIR)/cores/$(CORE)

# SYNTHESIS drops the $error protocol checkers, which mean nothing to a solver
SV2V_DEFS := -DRVFI -DRISCV_FORMAL -DRISCV_FORMAL_NRET=1 \
             -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_ILEN=32 \
             -DRISCV_FORMAL_ALIGNED_MEM -DSYNTHESIS
SV2V_INC  := -I$(RTL)/core -I$(RTL)/mem -I. -Iriscv-formal/checks

.PHONY: checks run run-insn list clean one

# yosys can't read the core's SystemVerilog, so sv2v flattens wrapper and core first
$(ROOT)/build/formal/rvfi_top.v: wrapper.sv $(wildcard $(RTL)/core/*.sv) \
                                 $(RTL)/mem/memory_io.sv
	mkdir -p $(ROOT)/build/formal
	sv2v $(SV2V_DEFS) $(SV2V_INC) --write=$@ wrapper.sv $(RTL)/core/cpu.sv

riscv-formal/insns/isa_rv32i.txt:
	cd riscv-formal/insns && python3 generate.py

checks: $(ROOT)/build/formal/rvfi_top.v riscv-formal/insns/isa_rv32i.txt
	mkdir -p $(CHECKDIR)
	ln -sfn ../riscv-formal/insns  $(BASEDIR)/insns
	ln -sfn ../riscv-formal/checks $(BASEDIR)/checks
	cp checks.cfg $(CHECKDIR)/
	cd $(CHECKDIR) && python3 ../../checks/genchecks.py
	@echo "generated `ls $(CHECKDIR)/checks/*.sby | wc -l | tr -d ' '` checks"

list: checks
	@ls $(CHECKDIR)/checks/*.sby | xargs -n1 basename | sed 's/.sby//'

one: checks
	cd $(CHECKDIR)/checks && sby -f $(CHECK).sby

run: checks
	$(MAKE) -C $(CHECKDIR)/checks -j4

# The M checks are slow or intractable, so they only run under make run-m
M_CHECKS := insn_(mul|mulh|mulhsu|mulhu|div|divu|rem|remu)_

# Take the verdict from the status file: sby exits 0 even when a check fails
# ERROR means the harness broke, not the core
define run_check
	n=`basename $$c .sby`; printf "%-24s " $$n; \
	sby -f $$c > /dev/null 2>&1; \
	s=`awk '{print $$1; exit}' $$n/status 2>/dev/null`; \
	case "$$s" in \
		PASS) echo PASS ;; \
		FAIL) echo "FAIL  (counterexample: $$n/engine_0/trace.vcd)" ;; \
		*)    echo "ERROR (no status; see $$n/logfile.txt)" ;; \
	esac
endef

run-insn: checks
	@cd $(CHECKDIR)/checks && for c in `ls insn_*.sby 2>/dev/null | grep -vE '$(M_CHECKS)'`; do \
		$(run_check); \
	done

# Expect hours, and the multiply checks not to finish
run-m: checks
	@cd $(CHECKDIR)/checks && for c in `ls insn_*.sby 2>/dev/null | grep -E '$(M_CHECKS)'`; do \
		$(run_check); \
	done

# Everything that isn't a per-instruction check
run-consistency: checks
	@cd $(CHECKDIR)/checks && for c in `ls *.sby 2>/dev/null | grep -v '^insn_'`; do \
		$(run_check); \
	done

clean:
	rm -rf $(BASEDIR) $(ROOT)/build/formal
