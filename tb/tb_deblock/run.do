vlib work
vlog -sv +incdir+../../rtl/common ../../rtl/common/parameter_pkg.vh ../../rtl/inloop_filters/boundary_strength.v ../../rtl/inloop_filters/db_filter_luma.v ../../rtl/inloop_filters/db_filter_chroma.v ../../rtl/inloop_filters/deblock_top.v tb_deblock.sv
vsim -c -voptargs=+acc work.tb_deblock
run -all
quit -f
