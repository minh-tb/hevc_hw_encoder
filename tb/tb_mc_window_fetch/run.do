vlib work
vmap work work
vlog -sv rtl/inter/mc_window_fetch.v tb/tb_mc_window_fetch/tb_mc_window_fetch.sv
vsim -c -voptargs=+acc work.tb_mc_window_fetch
run -all
quit -f
