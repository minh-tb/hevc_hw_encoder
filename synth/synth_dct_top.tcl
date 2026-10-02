#=============================================================================
# synth_dct_top.tcl
# Out-of-Context Synthesis of Row-Serial dct_top on ZU9EG
#=============================================================================

set top_module "dct_top"
set target_part "xczu9eg-ffvb1156-2-e"
set output_dir "synth/vivado_output_dct"

file mkdir $output_dir

puts "================================================================="
puts " Synthesizing $top_module on $target_part..."
puts "================================================================="

create_project -in_memory -part $target_part

read_verilog -sv [list \
    "rtl/common/parameter_pkg.vh" \
    "rtl/transform/transform_1d_core.v" \
    "rtl/transform/transpose_ram_32x32.v" \
    "rtl/transform/dct_top.v" \
]

# Run Out-of-Context Synthesis
synth_design -top $top_module -part $target_part -mode out_of_context

# Constraints on open synthesized design
create_clock -period 10.000 -name clk [get_ports clk]

# Generate Utilization & Timing Reports
report_utilization -file "$output_dir/utilization_synth.rpt" -pb "$output_dir/utilization_synth.pb"
report_timing_summary -file "$output_dir/timing_summary_synth.rpt" -delay_type max -max_paths 10

puts "================================================================="
puts " dct_top Synthesis Finished!"
puts " Reports saved to: $output_dir"
puts "================================================================="
exit
