# DE1-SoC block-level simulations (synthesis is done in Quartus)
# make sim runs every testbench; make vga, ps2 or sdram runs one

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

$(BUILD)/sdram_tb: sim/sdram_tb.sv sim/sdram_model.sv sdram_ctrl.sv
	@mkdir -p $(BUILD)
	@$(IVERILOG) -g2012 -I$(ROOT)/rtl/core -I$(ROOT)/rtl/mem -o $@ $^

clean:
	rm -rf $(BUILD)
