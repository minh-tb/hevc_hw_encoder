#=============================================================================
# synth_dct_hier.tcl
# Generate Hierarchical Utilization Report for dct_top on ZU9EG
#=============================================================================

set top_module "dct_top"
set target_part "xczu9eg-ffvb1156-2-e"
set output_dir "synth/vivado_output_dct"

file mkdir $output_dir

create_project -in_memory -part $target_part

read_verilog -sv [list \
    "rtl/common/parameter_pkg.vh" \
    "rtl/transform/transform_1d_core.v" \
    "rtl/transform/transpose_ram_32x32.v" \
    "rtl/transform/dct_top.v" \
]

synth_design -top $top_module -part $target_part -mode out_of_context

# Generate Hierarchical Utilization
report_utilization -hierarchical -file "$output_dir/utilization_hierarchical.rpt"
report_utilization -hierarchical -hierarchical_depth 3 -file "$output_dir/utilization_hier_depth3.rpt"

puts "================================================================="
puts " Hierarchical report generated: $output_dir/utilization_hierarchical.rpt"
puts "================================================================="
exit
