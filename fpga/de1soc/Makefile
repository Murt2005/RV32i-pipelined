# DE1-SoC gateware. Synthesis happens on EC2 (see infra/); this Makefile is for
# the parts that can be simulated locally, which is most of them.
#
#   make sim        every block-level testbench
#   make vga ps2    one at a time
#
# Quartus reads SystemVerilog natively, so unlike the iCE40 flow there is no
# sv2v step on this path.

ROOT    := ../..
BUILD   := $(ROOT)/build/de1soc
IVERILOG?= iverilog

TESTS := vga ps2 sdram

.PHONY: sim $(TESTS) clean

sim: $(TESTS)
	@echo ""
	@echo "all de1soc block tests passed"

vga: $(BUILD)/vga_tb
	@$(BUILD)/vga_tb

ps2: $(BUILD)/ps2_tb
	@$(BUILD)/ps2_tb

sdram: $(BUILD)/sdram_tb
	@$(BUILD)/sdram_tb

$(BUILD)/vga_tb: sim/vga_tb.sv vga.sv
	@mkdir -p $(BUILD)
	@$(IVERILOG) -g2012 -o $@ $^

$(BUILD)/ps2_tb: sim/ps2_tb.sv ps2_keyboard.sv
	@mkdir -p $(BUILD)
	@$(IVERILOG) -g2012 -o $@ $^

# -I$(ROOT) so the shared memory_io.sv / system.sv are found.
$(BUILD)/sdram_tb: sim/sdram_tb.sv sim/sdram_model.sv sdram_ctrl.sv
	@mkdir -p $(BUILD)
	@$(IVERILOG) -g2012 -I$(ROOT) -o $@ $^

clean:
	rm -rf $(BUILD)
