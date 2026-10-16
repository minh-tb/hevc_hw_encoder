vlib work
if {[file exists "rtl/common/parameter_pkg.vh"]} {
    set rtl_path "rtl"
    set tb_path "tb"
} else {
    set rtl_path "../rtl"
    set tb_path "."
}
vlog -sv +define+REMEDIATION +libext+.v -y $rtl_path/top -y $rtl_path/entropy -y $rtl_path/common -y $rtl_path/partition -y $rtl_path/transform -y $rtl_path/intra -y $rtl_path/recon -y $rtl_path/inter -y $rtl_path/rate_control -y $rtl_path/inloop_filters -y $rtl_path/quant -y $rtl_path/input_output +incdir+$rtl_path/common +incdir+$rtl_path/top $rtl_path/common/parameter_pkg.vh $rtl_path/top/hevc_encoder_top.v $rtl_path/top/hevc_encoder_axi_top.v $tb_path/tb_axi_top/tb_hevc_encoder_axi_top.sv
vsim -c work.tb_hevc_encoder_axi_top
run -all
quit -f
