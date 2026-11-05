vlib work
if {[file exists "rtl/common/parameter_pkg.vh"]} {
    set rtl_path "rtl"
    set tb_path "tb/tb_inter"
} else {
    set rtl_path "../../rtl"
    set tb_path "."
}
vlog -sv -work work +define+REMEDIATION +libext+.v -y $rtl_path/inter -y $rtl_path/common +incdir+$rtl_path/common +incdir+$rtl_path/inter $rtl_path/common/parameter_pkg.vh $rtl_path/inter/subpel_interpolation_core.v $rtl_path/inter/mc_window_fetch.v $rtl_path/inter/inter_pred_top.v $tb_path/tb_b_prediction.v
vsim -c work.tb_b_prediction
run -all
quit -f
