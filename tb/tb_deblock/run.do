vlib work
if {[file exists "rtl/common/parameter_pkg.vh"]} {
    set rtl_path "rtl"
    set tb_path "tb/tb_deblock"
} else {
    set rtl_path "../../rtl"
    set tb_path "."
}
vlog -sv +define+REMEDIATION +incdir+$rtl_path/common $rtl_path/common/parameter_pkg.vh $rtl_path/inloop_filters/boundary_strength.v $rtl_path/inloop_filters/db_filter_luma.v $rtl_path/inloop_filters/db_filter_chroma.v $rtl_path/inloop_filters/deblock_top.v $tb_path/tb_deblock.sv
vsim -c -voptargs=+acc work.tb_deblock
run -all
quit -f
