# =============================================================================
# Synopsys Design Constraints (`base.sdc`) for YT-AI NPU @ 100 MHz (SKY130)
# =============================================================================
set clk_period 10.0
set clk_port   "clk"

create_clock -name core_clk -period $clk_period [get_ports $clk_port]
set_clock_uncertainty 0.25 [get_clocks core_clk]
set_clock_transition  0.15 [get_clocks core_clk]

set all_in_no_clk [remove_from_collection [all_inputs] [get_ports "$clk_port rst_n"]]
set_input_delay  -max 2.00 -clock core_clk $all_in_no_clk
set_input_delay  -min 0.50 -clock core_clk $all_in_no_clk
set_output_delay -max 2.00 -clock core_clk [all_outputs]
set_output_delay -min 0.50 -clock core_clk [all_outputs]

set_false_path -from [get_ports rst_n]
set_max_fanout 16 [current_design]
set_load 0.05 [all_outputs]
