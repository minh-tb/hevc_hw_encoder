# ==============================================================================
# tb/modelsim_regression.do
# HEVC / H.265 Main10 Hardware Video Encoder - Algorithmic Flaw Testbench Suite
# ModelSim Altera 10.1d Headless Batch Regression Macro
#
# Normative Specification: ITU-T H.265 (HEVC) / ISO/IEC 23008-2 Main10
# Executes all 14 algorithmic flaw verification testbenches in dual states:
#   - Buggy Mode: Proves flaw detection & failure condition ($finish(1))
#   - Remediated Mode: Confirms 100% normative compliance ($finish(0))
# ==============================================================================

transcript on
onerror {resume}

vlib work

puts "================================================================================"
puts " HEVC Main10 Hardware Video Encoder - Algorithmic Flaw Verification Suite"
puts " ModelSim Altera 10.1d Native DO Macro Regression"
puts "================================================================================"

# ------------------------------------------------------------------------------
# 1. Flaw D-01: AMVP Candidate Zero Vector Tie-off
# ------------------------------------------------------------------------------
puts "\n>>> \[D-01\] Inter / AMVP: tb_flaw_amvp - Buggy Mode"
vlog -sv -work work +incdir+rtl/common +incdir+rtl/inter \
    rtl/common/parameter_pkg.vh rtl/inter/mvp_predictor.v tb/tb_flaw_amvp/tb_flaw_amvp.sv
vsim -c work.tb_flaw_amvp -do "run -all; quit -f"

puts "\n>>> \[D-01\] Inter / AMVP: tb_flaw_amvp - Remediated Mode"
vlog -sv -work work +define+REMEDIATION +incdir+rtl/common +incdir+rtl/inter \
    rtl/common/parameter_pkg.vh rtl/inter/mvp_predictor.v tb/tb_flaw_amvp/tb_flaw_amvp.sv
vsim -c work.tb_flaw_amvp -do "run -all; quit -f"

# ------------------------------------------------------------------------------
# 2. Flaw D-13: Sub-Pel Interpolation Filter Floating Ports
# ------------------------------------------------------------------------------
puts "\n>>> \[D-13\] Inter / MC: tb_flaw_hpel_ports - Buggy Mode"
vlog -sv -work work +incdir+rtl/common +incdir+rtl/inter \
    rtl/common/parameter_pkg.vh rtl/inter/hpel_filter_luma.v rtl/inter/hpel_filter_chroma.v \
    tb/tb_flaw_hpel/tb_flaw_hpel_ports.sv
vsim -c work.tb_flaw_hpel_ports -do "run -all; quit -f"

puts "\n>>> \[D-13\] Inter / MC: tb_flaw_hpel_ports - Remediated Mode"
vlog -sv -work work +define+REMEDIATION +incdir+rtl/common +incdir+rtl/inter \
    rtl/common/parameter_pkg.vh rtl/inter/hpel_filter_luma.v rtl/inter/hpel_filter_chroma.v \
    tb/tb_flaw_hpel/tb_flaw_hpel_ports.sv
vsim -c work.tb_flaw_hpel_ports -do "run -all; quit -f"

# ------------------------------------------------------------------------------
# 3. Flaw D-02: 4x4 Intra Luma DST-VII Tie-off
# ------------------------------------------------------------------------------
puts "\n>>> \[D-02\] Transform: tb_flaw_dst7 - Buggy Mode"
vlog -sv -work work +incdir+rtl/common \
    rtl/common/parameter_pkg.vh rtl/transform/transpose_ram_32x32.v rtl/transform/transform_1d_core.v \
    rtl/transform/dct_top.v tb/tb_flaw_dst7/tb_flaw_dst7.sv
vsim -c work.tb_flaw_dst7 -do "run -all; quit -f"

puts "\n>>> \[D-02\] Transform: tb_flaw_dst7 - Remediated Mode"
vsim -c +REMEDIATED work.tb_flaw_dst7 -do "run -all; quit -f"

# ------------------------------------------------------------------------------
# 4. Flaw D-14: Mode-Dependent Scan (MDCS) Desynchronization
# ------------------------------------------------------------------------------
puts "\n>>> \[D-14\] Transform / Entropy: tb_flaw_mdcs - Buggy Mode"
vlog -sv -work work +incdir+rtl/common \
    rtl/common/parameter_pkg.vh rtl/top/address_generator.v tb/tb_flaw_mdcs/tb_flaw_mdcs.sv
vsim -c work.tb_flaw_mdcs -do "run -all; quit -f"

puts "\n>>> \[D-14\] Transform / Entropy: tb_flaw_mdcs - Remediated Mode"
vsim -c +REMEDIATED work.tb_flaw_mdcs -do "run -all; quit -f"

# ------------------------------------------------------------------------------
# 5. Flaw D-07: Deblocking Edge Stage Truncation
# ------------------------------------------------------------------------------
puts "\n>>> \[D-07\] In-Loop / Deblock: tb_flaw_deblock_stages - Buggy Mode"
vlog -sv -work work +incdir+rtl/common +incdir+rtl/inloop_filters \
    rtl/common/parameter_pkg.vh rtl/inloop_filters/db_filter_luma.v rtl/inloop_filters/db_filter_chroma.v \
    rtl/inloop_filters/boundary_strength.v rtl/inloop_filters/deblock_top.v \
    tb/tb_flaw_deblock/tb_flaw_deblock_stages.sv
vsim -c work.tb_flaw_deblock_stages -do "run -all; quit -f"

puts "\n>>> \[D-07\] In-Loop / Deblock: tb_flaw_deblock_stages - Remediated Mode"
vlog -sv -work work +define+REMEDIATION +incdir+rtl/common +incdir+rtl/inloop_filters \
    rtl/common/parameter_pkg.vh rtl/inloop_filters/db_filter_luma.v rtl/inloop_filters/db_filter_chroma.v \
    rtl/inloop_filters/boundary_strength.v rtl/inloop_filters/deblock_top.v \
    tb/tb_flaw_deblock/tb_flaw_deblock_stages.sv
vsim -c work.tb_flaw_deblock_stages -do "run -all; quit -f"

# ------------------------------------------------------------------------------
# 6. Flaw D-06: Chroma t_C Table High-QP Zero Collapse
# ------------------------------------------------------------------------------
puts "\n>>> \[D-06\] In-Loop / Deblock: tb_flaw_chroma_tc - Buggy Mode"
vlog -sv -work work +incdir+rtl/common +incdir+rtl/inloop_filters \
    rtl/common/parameter_pkg.vh rtl/inloop_filters/db_filter_chroma.v tb/tb_flaw_chroma_tc/tb_flaw_chroma_tc.sv
vsim -c work.tb_flaw_chroma_tc -do "run -all; quit -f"

puts "\n>>> \[D-06\] In-Loop / Deblock: tb_flaw_chroma_tc - Remediated Mode"
vlog -sv -work work +define+REMEDIATION +incdir+rtl/common +incdir+rtl/inloop_filters \
    rtl/common/parameter_pkg.vh rtl/inloop_filters/db_filter_chroma.v tb/tb_flaw_chroma_tc/tb_flaw_chroma_tc.sv
vsim -c work.tb_flaw_chroma_tc -do "run -all; quit -f"

# ------------------------------------------------------------------------------
# 7. Flaw D-09: SAO Statistics Engine Stub & CABAC Syntax Omission
# ------------------------------------------------------------------------------
puts "\n>>> \[D-09\] In-Loop / SAO: tb_flaw_sao_integration - Buggy Mode"
vlog -sv -work work +incdir+rtl/common +incdir+rtl/inloop_filters +incdir+rtl/entropy \
    rtl/common/parameter_pkg.vh rtl/inloop_filters/sao_stats.v rtl/inloop_filters/sao_edge_offset.v \
    rtl/inloop_filters/sao_band_offset.v rtl/entropy/syntax_sao.v \
    tb/tb_flaw_sao/tb_flaw_sao_integration.sv
vsim -c work.tb_flaw_sao_integration -do "run -all; quit -f"

puts "\n>>> \[D-09\] In-Loop / SAO: tb_flaw_sao_integration - Remediated Mode"
vlog -sv -work work +define+REMEDIATION +incdir+rtl/common +incdir+rtl/inloop_filters +incdir+rtl/entropy \
    rtl/common/parameter_pkg.vh rtl/inloop_filters/sao_stats.v rtl/inloop_filters/sao_edge_offset.v \
    rtl/inloop_filters/sao_band_offset.v rtl/entropy/syntax_sao.v \
    tb/tb_flaw_sao/tb_flaw_sao_integration.sv
vsim -c work.tb_flaw_sao_integration -do "run -all; quit -f"

# ------------------------------------------------------------------------------
# 8. Flaw D-04: Intra RMD Mode Decision Divergence (SAD vs SATD)
# ------------------------------------------------------------------------------
puts "\n>>> \[D-04\] Intra / RMD: tb_flaw_intra_rmd - Buggy Mode"
vlog -sv -work work +incdir+rtl/common +incdir+rtl/intra \
    rtl/common/parameter_pkg.vh rtl/common/hadamard_satd_4x4.v rtl/intra/intra_rmd.v \
    tb/tb_flaw_intra_rmd/tb_flaw_intra_rmd.sv
vsim -c work.tb_flaw_intra_rmd -do "run -all; quit -f"

puts "\n>>> \[D-04\] Intra / RMD: tb_flaw_intra_rmd - Remediated Mode"
vlog -sv -work work +define+REMEDIATION_PATCH +incdir+rtl/common +incdir+rtl/intra \
    rtl/common/parameter_pkg.vh rtl/common/hadamard_satd_4x4.v rtl/intra/intra_rmd.v \
    tb/tb_flaw_intra_rmd/tb_flaw_intra_rmd.sv
vsim -c work.tb_flaw_intra_rmd -do "run -all; quit -f"

# ------------------------------------------------------------------------------
# 9. Flaw D-08: Intra Planar 16-bit Accumulator Dynamic Range Overflow
# ------------------------------------------------------------------------------
puts "\n>>> \[D-08\] Intra / Planar: tb_flaw_planar_overflow - Buggy Mode"
vlog -sv -work work +incdir+rtl/common +incdir+rtl/intra \
    rtl/common/parameter_pkg.vh tb/tb_flaw_planar_overflow/tb_flaw_planar_overflow.sv
vsim -c work.tb_flaw_planar_overflow -do "run -all; quit -f"

puts "\n>>> \[D-08\] Intra / Planar: tb_flaw_planar_overflow - Remediated Mode"
vlog -sv -work work +define+REMEDIATION_PATCH +incdir+rtl/common +incdir+rtl/intra \
    rtl/common/parameter_pkg.vh tb/tb_flaw_planar_overflow/tb_flaw_planar_overflow.sv
vsim -c work.tb_flaw_planar_overflow -do "run -all; quit -f"

# ------------------------------------------------------------------------------
# 10. Flaw D-03: 8x8 TU CG Coordinate Bit-Slicing Aliasing
# ------------------------------------------------------------------------------
puts "\n>>> \[D-03\] Entropy / Coeff: tb_flaw_syntax_coeff_cg - Buggy Mode"
vlog -sv -work work +incdir+rtl/common +incdir+rtl/entropy \
    rtl/common/parameter_pkg.vh rtl/entropy/syntax_coeff.v \
    tb/tb_flaw_syntax_coeff_cg/tb_flaw_syntax_coeff_cg.sv
vsim -c work.tb_flaw_syntax_coeff_cg -do "run -all; quit -f"

puts "\n>>> \[D-03\] Entropy / Coeff: tb_flaw_syntax_coeff_cg - Remediated Mode"
vlog -sv -work work +define+REMEDIATION +incdir+rtl/common +incdir+rtl/entropy \
    rtl/common/parameter_pkg.vh rtl/entropy/syntax_coeff.v \
    tb/tb_flaw_syntax_coeff_cg/tb_flaw_syntax_coeff_cg.sv
vsim -c work.tb_flaw_syntax_coeff_cg -do "run -all; quit -f"

# ------------------------------------------------------------------------------
# 11. Flaw D-11: CABAC Context Model Table 9-39 Slice Type Inversion
# ------------------------------------------------------------------------------
puts "\n>>> \[D-11\] Entropy / CABAC: tb_flaw_cabac_init - Buggy Mode"
vlog -sv -work work +incdir+rtl/common +incdir+rtl/entropy \
    rtl/common/parameter_pkg.vh rtl/entropy/ctx_model_store.v \
    tb/tb_flaw_cabac_init/tb_flaw_cabac_init.sv
vsim -c work.tb_flaw_cabac_init -do "run -all; quit -f"

puts "\n>>> \[D-11\] Entropy / CABAC: tb_flaw_cabac_init - Remediated Mode"
vlog -sv -work work +define+TEST_CONFORMANCE +incdir+rtl/common +incdir+rtl/entropy \
    rtl/common/parameter_pkg.vh rtl/entropy/ctx_model_store.v \
    tb/tb_flaw_cabac_init/tb_flaw_cabac_init.sv
vsim -c work.tb_flaw_cabac_init -do "run -all; quit -f"

# ------------------------------------------------------------------------------
# 12. Flaw D-10: Range Coder Renormalization, bits_left, & Carry Ripple
# ------------------------------------------------------------------------------
puts "\n>>> \[D-10\] Entropy / RangeCoder: tb_flaw_range_coder - Buggy Mode"
vlog -sv -work work +incdir+rtl/common +incdir+rtl/entropy \
    rtl/common/parameter_pkg.vh rtl/entropy/range_coder.v \
    tb/tb_flaw_range_coder/tb_flaw_range_coder.sv
vsim -c work.tb_flaw_range_coder -do "run -all; quit -f"

puts "\n>>> \[D-10\] Entropy / RangeCoder: tb_flaw_range_coder - Remediated Mode"
vlog -sv -work work +define+REMEDIATION +incdir+rtl/common +incdir+rtl/entropy \
    rtl/common/parameter_pkg.vh rtl/entropy/range_coder.v \
    tb/tb_flaw_range_coder/tb_flaw_range_coder.sv
vsim -c work.tb_flaw_range_coder -do "run -all; quit -f"

# ------------------------------------------------------------------------------
# 13. Flaw D-05: 64x64 CU Split Decision Deadlock
# ------------------------------------------------------------------------------
puts "\n>>> \[D-05\] Partitioning: tb_flaw_cu_split - Buggy Mode"
vlog -sv -work work +incdir+rtl/common +incdir+rtl/partition \
    rtl/common/parameter_pkg.vh rtl/common/hevc_interfaces.vh rtl/partition/ctu_partitioner.v \
    rtl/partition/mode_decision.v tb/tb_flaw_cu_split/tb_flaw_cu_split.sv
vsim -c work.tb_flaw_cu_split -do "run -all; quit -f"

puts "\n>>> \[D-05\] Partitioning: tb_flaw_cu_split - Remediated Mode"
vsim -c +REMEDIATED work.tb_flaw_cu_split -do "run -all; quit -f"

# ------------------------------------------------------------------------------
# 14. Flaw D-12: Rate Control Lambda Main10 Scaling & VBV 32-bit Overflow
# ------------------------------------------------------------------------------
puts "\n>>> \[D-12\] Rate Control: tb_flaw_lambda_rc - Buggy Mode"
vlog -sv -work work +incdir+rtl/common +incdir+rtl/rate_control \
    rtl/common/parameter_pkg.vh rtl/rate_control/lambda_calc.v rtl/rate_control/rate_controller.v \
    tb/tb_flaw_lambda_rc/tb_flaw_lambda_rc.sv
vsim -c work.tb_flaw_lambda_rc -do "run -all; quit -f"

puts "\n>>> \[D-12\] Rate Control: tb_flaw_lambda_rc - Remediated Mode"
vsim -c +REMEDIATED work.tb_flaw_lambda_rc -do "run -all; quit -f"

puts "\n================================================================================"
puts " ALL 14 FLAW TESTBENCHES EXECUTED IN BOTH DUAL STATES"
puts "================================================================================"
quit -f
