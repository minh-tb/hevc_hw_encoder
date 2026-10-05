vlib work
vlog -sv -work work +incdir+../../rtl/common +incdir+../../rtl/inter ../../rtl/common/parameter_pkg.vh ../../rtl/inter/hpel_filter_luma.v ../../rtl/inter/hpel_filter_chroma.v tb_flaw_hpel_ports.sv
vsim -c work.tb_flaw_hpel_ports -do "run -all; quit -f"
