# riscv-formal harness for the RV32I pipelined core.
#
#   make checks     generate the .sby files
#   make run        run them all (slow; see `make list`)
#   make run-insn   just the per-instruction checks
#   make CHECK=reg_ch0 one
#
# genchecks.py derives its base directory from the working directory and
# expects a <basedir>/cores/<core>/ layout, so `rf/` below is that layout built
# out of symlinks into the vendored riscv-formal rather than a copy of it.

ROOT     := ..
BASEDIR  := rf
CORE     := rv32
CHECKDIR := $(BASEDIR)/cores/$(CORE)

# SYNTHESIS drops the core's simulation-only memory_io protocol checkers. They
# are $error-based, which means nothing to a solver, and their state would only
# widen the search space -- the formal checks make the stronger statement anyway.
SV2V_DEFS := -DRVFI -DRISCV_FORMAL -DRISCV_FORMAL_NRET=1 \
             -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_ILEN=32 \
             -DRISCV_FORMAL_ALIGNED_MEM -DSYNTHESIS
SV2V_INC  := -I$(ROOT) -I. -Iriscv-formal/checks

.PHONY: checks run run-insn list clean one

# yosys cannot read the core's SystemVerilog, so flatten wrapper + core first
# and point riscv-formal at the result.
$(ROOT)/build/formal/rvfi_top.v: wrapper.sv $(ROOT)/cpu.sv $(ROOT)/riscv32_common.sv \
                                 $(ROOT)/memory_io.sv $(ROOT)/base.sv $(ROOT)/system.sv
	mkdir -p $(ROOT)/build/formal
	sv2v $(SV2V_DEFS) $(SV2V_INC) --write=$@ wrapper.sv $(ROOT)/cpu.sv

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

run-insn: checks
	@cd $(CHECKDIR)/checks && for c in `ls insn_*.sby 2>/dev/null`; do \
		n=`basename $$c .sby`; printf "%-24s " $$n; \
		sby -f $$c > /dev/null 2>&1 && echo PASS || echo FAIL; \
	done

clean:
	rm -rf $(BASEDIR) $(ROOT)/build/formal
