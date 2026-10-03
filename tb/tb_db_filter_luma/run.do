vlib work
vlog -sv +incdir+../../rtl/common ../../rtl/common/parameter_pkg.vh ../../rtl/inloop_filters/db_filter_luma.v tb_db_filter_luma.sv
vsim -c -voptargs=+acc work.tb_db_filter_luma
run -all
quit -f
