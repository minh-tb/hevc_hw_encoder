#=============================================================================
# hevc_encoder_top.xdc
# Timing and Physical Constraints for HEVC Hardware Encoder
#
# Target Clock: 180 MHz (period: 5.555 ns)
#=============================================================================

# 1. Primary Clock Definition (180 MHz)
create_clock -period 5.555 -name clk [get_ports clk]

# Clock Uncertainty
set_clock_uncertainty 0.200 [get_clocks clk]

# 2. Input / Output Delay Constraints
# Assuming ~20% cycle time budget for external inter-die / board delay
set_input_delay -clock clk -max 1.111 [get_ports -filter {DIRECTION == IN && NAME !~ "*clk*"}]
set_input_delay -clock clk -min 0.250 [get_ports -filter {DIRECTION == IN && NAME !~ "*clk*"}]

set_output_delay -clock clk -max 1.111 [all_outputs]
set_output_delay -clock clk -min 0.250 [all_outputs]
