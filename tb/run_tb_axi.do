vlib work
do compile.do
vlog -sv +incdir+rtl/common +incdir+rtl/top rtl/top/hevc_encoder_axi_top.v tb/tb_axi_top/tb_hevc_encoder_axi_top.sv
vsim -c work.tb_hevc_encoder_axi_top
run -all
quit -f
