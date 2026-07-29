# Timing constraints. Without these the fitter has no target and reports a
# meaningless Fmax, which is the same as not knowing whether the design works.

create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_pll_clocks
derive_clock_uncertainty

# The DRAM clock leaves the chip and comes back in through the part, so the
# board round trip has to be told to the analyser rather than assumed.
set_output_delay -clock [get_clocks {pll|*outclk_2}] -max 1.5 [get_ports DRAM_*]
set_output_delay -clock [get_clocks {pll|*outclk_2}] -min -0.8 [get_ports DRAM_*]
set_input_delay  -clock [get_clocks {pll|*outclk_2}] -max 5.4 [get_ports DRAM_DQ[*]]
set_input_delay  -clock [get_clocks {pll|*outclk_2}] -min 2.7 [get_ports DRAM_DQ[*]]

# Buttons, switches, LEDs and PS/2 are not timing-critical; constraining them
# only produces failures that mean nothing.
set_false_path -from [get_ports {KEY[*] SW[*] PS2_CLK PS2_DAT}]
set_false_path -to   [get_ports {LEDR[*]}]
