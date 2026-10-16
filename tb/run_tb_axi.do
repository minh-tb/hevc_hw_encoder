vlib work
vlog -sv +define+REMEDIATION +libext+.v -y rtl/top -y rtl/entropy -y rtl/common -y rtl/partition -y rtl/transform -y rtl/intra -y rtl/recon -y rtl/inter -y rtl/rate_control -y rtl/inloop_filters -y rtl/quant -y rtl/input_output +incdir+rtl/common +incdir+rtl/top rtl/common/parameter_pkg.vh rtl/top/hevc_encoder_top.v rtl/top/hevc_encoder_axi_top.v tb/tb_axi_top/tb_hevc_encoder_axi_top.sv
vsim -c work.tb_hevc_encoder_axi_top
run -all
quit -f
