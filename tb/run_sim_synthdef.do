vlib work
vmap work work
vlog -sv +define+SYNTHESIS+REMEDIATION+CFG_TOTAL_FRAMES=3 +libext+.v -y rtl/top -y rtl/entropy -y rtl/common -y rtl/partition -y rtl/transform -y rtl/intra -y rtl/recon -y rtl/inter -y rtl/rate_control -y rtl/inloop_filters -y rtl/quant -y rtl/input_output +incdir+rtl/common tb/tb_full_encoder/tb_b_frame_encoder.v rtl/common/parameter_pkg.vh
vsim -c -l transcript_synthdef.log -voptargs=+acc work.tb_b_frame_encoder
run -all
quit -f
