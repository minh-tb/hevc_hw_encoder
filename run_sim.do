vlib work
vlog -sv -y rtl/top -y rtl/entropy -y rtl/common -y rtl/partition -y rtl/transform -y rtl/intra -y rtl/recon -y rtl/inter -y rtl/rate_control -y rtl/inloop_filters +incdir+rtl/common tb/tb_full_encoder/tb_b_frame_encoder.v rtl/common/parameter_pkg.vh tb/init_vals.v
vsim -c -voptargs=+acc work.tb_b_frame_encoder
run -all
quit -f
