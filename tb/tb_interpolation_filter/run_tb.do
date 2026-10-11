vlib work
vlog -sv -work work +define+REMEDIATION +incdir+../../rtl/common +incdir+../../rtl/inter ../../rtl/common/parameter_pkg.vh ../../rtl/inter/hpel_filter_luma.v ../../rtl/inter/hpel_filter_chroma.v tb_interpolation_filter.sv
vsim -c work.tb_interpolation_filter -do "run -all; quit -f"
