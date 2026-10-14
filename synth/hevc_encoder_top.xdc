#=============================================================================
# hevc_encoder_top.xdc
# Timing and Physical Constraints for HEVC Hardware Encoder
#
# Target Clock: 50 MHz baseline (period: 20.0 ns)
# High-Performance Target: 100 MHz (period: 10.0 ns) - uncomment if targeting 100MHz
#=============================================================================

# 1. Primary Clock Definition (50 MHz baseline)
create_clock -period 20.000 -name clk [get_ports clk]

# Clock Uncertainty
set_clock_uncertainty 0.200 [get_clocks clk]

# 2. Input / Output Delay Constraints
# Assuming ~20% cycle time budget for external inter-die / board delay
set_input_delay -clock clk -max 4.000 [get_ports -filter {DIRECTION == IN && NAME !~ "*clk*"}]
set_input_delay -clock clk -min 0.500 [get_ports -filter {DIRECTION == IN && NAME !~ "*clk*"}]

set_output_delay -clock clk -max 4.000 [all_outputs]
set_output_delay -clock clk -min 0.500 [all_outputs]
