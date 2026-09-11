# SDC Timing Constraint for HEVC Hardware Encoder
# Target Clock: 200 MHz (Period: 5.000 ns)
create_clock -name clk -period 5.000 [get_ports clk]
derive_clock_uncertainty
