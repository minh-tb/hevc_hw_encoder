#=============================================================================
# hevc_encoder_top.xdc
# Timing and Physical Constraints for HEVC Hardware Encoder
#
# Target Clock: 150 MHz (period: 6.667 ns)
#=============================================================================

# 1. Primary Clock Definition (150 MHz)
create_clock -period 6.667 -name clk [get_ports clk]

# Clock Uncertainty
set_clock_uncertainty 0.200 [get_clocks clk]

# 2. Input / Output Delay Constraints
# Assuming ~20% cycle time budget for external inter-die / board delay
set_input_delay -clock clk -max 1.333 [get_ports -filter {DIRECTION == IN && NAME !~ "*clk*"}]
set_input_delay -clock clk -min 0.250 [get_ports -filter {DIRECTION == IN && NAME !~ "*clk*"}]

set_output_delay -clock clk -max 1.333 [all_outputs]
set_output_delay -clock clk -min 0.250 [all_outputs]
