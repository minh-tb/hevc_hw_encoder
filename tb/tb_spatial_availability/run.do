vlib work
if {[file exists "rtl/common/parameter_pkg.vh"]} {
    set tb_path "tb/tb_spatial_availability"
} else {
    set tb_path "."
}
vlog -sv -work work $tb_path/tb_spatial_availability.sv
vsim -c work.tb_spatial_availability
run -all
quit -f
