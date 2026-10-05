# ModelSim DO script for tb_flaw_mdcs
vlib work
vmap work work
vlog -sv -work work +acc +incdir+rtl/common rtl/common/parameter_pkg.vh rtl/top/address_generator.v tb/tb_flaw_mdcs/tb_flaw_mdcs.sv

# 1. Run in Buggy Mode (Demonstrates Flaw D-14 / D-04 failure)
echo "=== RUNNING BUGGY MODE (Should Fail & Confirm Flaw D-14 / D-04) ==="
vsim -c -do "run -all; quit -f" work.tb_flaw_mdcs

# 2. Run in Remediated Mode (Demonstrates Pass when MDCS is synchronized)
echo "=== RUNNING REMEDIATED MODE (Should Pass 100%) ==="
vsim -c +REMEDIATED -do "run -all; quit -f" work.tb_flaw_mdcs
