vlib work
if {[file exists "rtl/common/parameter_pkg.vh"]} {
    set rtl_path "rtl"
    set tb_path "tb/tb_flaw_deblock"
} else {
    set rtl_path "../../rtl"
    set tb_path "."
}
vlog -sv -work work +incdir+$rtl_path/common +incdir+$rtl_path/inloop_filters $rtl_path/common/parameter_pkg.vh $rtl_path/inloop_filters/boundary_strength.v $rtl_path/inloop_filters/db_filter_luma.v $rtl_path/inloop_filters/db_filter_chroma.v $rtl_path/inloop_filters/deblock_top.v $tb_path/tb_flaw_deblock_stages.sv
vsim -c work.tb_flaw_deblock_stages
run -all
quit -f
