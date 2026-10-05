vlib work
vlog -sv -work work +incdir+../../rtl/common +incdir+../../rtl/inter ../../rtl/common/parameter_pkg.vh ../../rtl/inter/mvp_predictor.v tb_flaw_amvp.sv
vsim -c work.tb_flaw_amvp -do "run -all; quit -f"
