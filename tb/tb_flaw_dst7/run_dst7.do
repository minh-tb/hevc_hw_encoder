# ModelSim DO script for tb_flaw_dst7
vlib work
vmap work work
vlog -sv -work work +acc +incdir+rtl/common rtl/common/parameter_pkg.vh rtl/transform/transpose_ram_32x32.v rtl/transform/transform_1d_core.v rtl/transform/dct_top.v tb/tb_flaw_dst7/tb_flaw_dst7.sv

# 1. Run in Buggy Mode (Demonstrates Flaw D-02 failure)
echo "=== RUNNING BUGGY MODE (Should Fail & Confirm Flaw D-02) ==="
vsim -c -do "run -all; quit -f" work.tb_flaw_dst7

# 2. Run in Remediated Mode (Demonstrates Pass when DST-VII is enabled)
echo "=== RUNNING REMEDIATED MODE (Should Pass 100%) ==="
vsim -c +REMEDIATED -do "run -all; quit -f" work.tb_flaw_dst7
