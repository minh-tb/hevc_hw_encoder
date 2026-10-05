#!/usr/bin/env python3
"""
scripts/run_all_flaw_tb.py
HEVC / H.265 Main10 Hardware Video Encoder - Algorithmic Flaw Testbench Regression Runner

Compiles and executes all 14 dual-state ModelSim testbenches in headless batch mode.
Reports dual-state verification status:
  - Buggy Mode: Confirms reproduction of flaw (assert & fail / deviation reported)
  - Remediated Mode: Confirms bit-exact normative conformance (assert & pass)
"""

import os
import sys
import subprocess
import time

MODELSIM_DIR = r"C:\altera\13.0sp1\modelsim_ase\win32aloem"
VLOG = os.path.join(MODELSIM_DIR, "vlog.exe")
VSIM = os.path.join(MODELSIM_DIR, "vsim.exe")

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

TEST_CASES = [
    {
        "id": "D-01",
        "name": "tb_flaw_amvp",
        "subsys": "Inter / AMVP",
        "vlog_cmd": [VLOG, "-sv", "-work", "work", "+incdir+rtl/common", "+incdir+rtl/inter",
                     "rtl/common/parameter_pkg.vh", "rtl/inter/mvp_predictor.v",
                     "tb/tb_flaw_amvp/tb_flaw_amvp.sv"],
        "buggy_sim": [VSIM, "-c", "work.tb_flaw_amvp", "-do", "run -all; quit -f"],
        "buggy_marker": "FLAW D-01 CONFIRMED",
        "remed_cmd": [VLOG, "-sv", "-work", "work", "+define+REMEDIATION", "+incdir+rtl/common", "+incdir+rtl/inter",
                      "rtl/common/parameter_pkg.vh", "rtl/inter/mvp_predictor.v",
                      "tb/tb_flaw_amvp/tb_flaw_amvp.sv"],
        "remed_sim": [VSIM, "-c", "work.tb_flaw_amvp", "-do", "run -all; quit -f"],
        "remed_marker": "ALL TESTS PASSED: AMVP CONFORMANCE VERIFIED",
    },
    {
        "id": "D-13",
        "name": "tb_flaw_hpel",
        "subsys": "Inter / MC",
        "vlog_cmd": [VLOG, "-sv", "-work", "work", "+incdir+rtl/common", "+incdir+rtl/inter",
                     "rtl/common/parameter_pkg.vh", "rtl/inter/hpel_filter_luma.v",
                     "rtl/inter/hpel_filter_chroma.v", "tb/tb_flaw_hpel/tb_flaw_hpel_ports.sv"],
        "buggy_sim": [VSIM, "-c", "work.tb_flaw_hpel_ports", "-do", "run -all; quit -f"],
        "buggy_marker": "FLAW D-13 CONFIRMED",
        "remed_cmd": [VLOG, "-sv", "-work", "work", "+define+REMEDIATION", "+incdir+rtl/common", "+incdir+rtl/inter",
                      "rtl/common/parameter_pkg.vh", "rtl/inter/hpel_filter_luma.v",
                      "rtl/inter/hpel_filter_chroma.v", "tb/tb_flaw_hpel/tb_flaw_hpel_ports.sv"],
        "remed_sim": [VSIM, "-c", "work.tb_flaw_hpel_ports", "-do", "run -all; quit -f"],
        "remed_marker": "ALL TESTS PASSED: SUB-PEL FILTER PORTS PROPERLY CONNECTED",
    },
    {
        "id": "D-02",
        "name": "tb_flaw_dst7",
        "subsys": "Transform",
        "vlog_cmd": [VLOG, "-sv", "-work", "work", "+incdir+rtl/common",
                     "rtl/common/parameter_pkg.vh", "rtl/transform/transpose_ram_32x32.v",
                     "rtl/transform/transform_1d_core.v", "rtl/transform/dct_top.v",
                     "tb/tb_flaw_dst7/tb_flaw_dst7.sv"],
        "buggy_sim": [VSIM, "-c", "work.tb_flaw_dst7", "-do", "run -all; quit -f"],
        "buggy_marker": "FLAW D-02 CONFIRMED",
        "remed_cmd": None,
        "remed_sim": [VSIM, "-c", "+REMEDIATED", "work.tb_flaw_dst7", "-do", "run -all; quit -f"],
        "remed_marker": "ALL 4 TESTS PASSED SPECIFICATION",
    },
    {
        "id": "D-14",
        "name": "tb_flaw_mdcs",
        "subsys": "Transform / Entropy",
        "vlog_cmd": [VLOG, "-sv", "-work", "work", "+incdir+rtl/common",
                     "rtl/common/parameter_pkg.vh", "rtl/top/address_generator.v",
                     "tb/tb_flaw_mdcs/tb_flaw_mdcs.sv"],
        "buggy_sim": [VSIM, "-c", "work.tb_flaw_mdcs", "-do", "run -all; quit -f"],
        "buggy_marker": "FLAW D-14 / D-04 CONFIRMED",
        "remed_cmd": None,
        "remed_sim": [VSIM, "-c", "+REMEDIATED", "work.tb_flaw_mdcs", "-do", "run -all; quit -f"],
        "remed_marker": "ALL TESTS PASSED SPECIFICATION",
    },
    {
        "id": "D-07",
        "name": "tb_flaw_deblock",
        "subsys": "In-Loop / Deblock",
        "vlog_cmd": [VLOG, "-sv", "-work", "work", "+incdir+rtl/common", "+incdir+rtl/inloop_filters",
                     "rtl/common/parameter_pkg.vh", "rtl/inloop_filters/db_filter_luma.v",
                     "rtl/inloop_filters/db_filter_chroma.v", "rtl/inloop_filters/boundary_strength.v",
                     "rtl/inloop_filters/deblock_top.v", "tb/tb_flaw_deblock/tb_flaw_deblock_stages.sv"],
        "buggy_sim": [VSIM, "-c", "work.tb_flaw_deblock_stages", "-do", "run -all; quit -f"],
        "buggy_marker": "FAILED: Deblocking edge stage truncation detected",
        "remed_cmd": [VLOG, "-sv", "-work", "work", "+define+REMEDIATION", "+incdir+rtl/common", "+incdir+rtl/inloop_filters",
                      "rtl/common/parameter_pkg.vh", "rtl/inloop_filters/db_filter_luma.v",
                      "rtl/inloop_filters/db_filter_chroma.v", "rtl/inloop_filters/boundary_strength.v",
                      "rtl/inloop_filters/deblock_top.v", "tb/tb_flaw_deblock/tb_flaw_deblock_stages.sv"],
        "remed_sim": [VSIM, "-c", "work.tb_flaw_deblock_stages", "-do", "run -all; quit -f"],
        "remed_marker": "ALL TESTS PASSED: All 8 CTU raster edges visited and filtered successfully",
    },
    {
        "id": "D-06",
        "name": "tb_flaw_chroma_tc",
        "subsys": "In-Loop / Deblock",
        "vlog_cmd": [VLOG, "-sv", "-work", "work", "+incdir+rtl/common", "+incdir+rtl/inloop_filters",
                     "rtl/common/parameter_pkg.vh", "rtl/inloop_filters/db_filter_chroma.v",
                     "tb/tb_flaw_chroma_tc/tb_flaw_chroma_tc.sv"],
        "buggy_sim": [VSIM, "-c", "work.tb_flaw_chroma_tc", "-do", "run -all; quit -f"],
        "buggy_marker": "FAILED: Chroma t_C table mapping flaw detected",
        "remed_cmd": [VLOG, "-sv", "-work", "work", "+define+REMEDIATION", "+incdir+rtl/common", "+incdir+rtl/inloop_filters",
                      "rtl/common/parameter_pkg.vh", "rtl/inloop_filters/db_filter_chroma.v",
                      "tb/tb_flaw_chroma_tc/tb_flaw_chroma_tc.sv"],
        "remed_sim": [VSIM, "-c", "work.tb_flaw_chroma_tc", "-do", "run -all; quit -f"],
        "remed_marker": "ALL TESTS PASSED: Full Table 8-19 and Main10 scaling verified",
    },
    {
        "id": "D-09",
        "name": "tb_flaw_sao",
        "subsys": "In-Loop / SAO",
        "vlog_cmd": [VLOG, "-sv", "-work", "work", "+incdir+rtl/common", "+incdir+rtl/inloop_filters",
                     "+incdir+rtl/entropy", "rtl/common/parameter_pkg.vh", "rtl/inloop_filters/sao_stats.v",
                     "rtl/inloop_filters/sao_edge_offset.v", "rtl/inloop_filters/sao_band_offset.v",
                     "rtl/entropy/syntax_sao.v", "tb/tb_flaw_sao/tb_flaw_sao_integration.sv"],
        "buggy_sim": [VSIM, "-c", "work.tb_flaw_sao_integration", "-do", "run -all; quit -f"],
        "buggy_marker": "FAILED: SAO integration flaw detected",
        "remed_cmd": [VLOG, "-sv", "-work", "work", "+define+REMEDIATION", "+incdir+rtl/common", "+incdir+rtl/inloop_filters",
                      "+incdir+rtl/entropy", "rtl/common/parameter_pkg.vh", "rtl/inloop_filters/sao_stats.v",
                      "rtl/inloop_filters/sao_edge_offset.v", "rtl/inloop_filters/sao_band_offset.v",
                      "rtl/entropy/syntax_sao.v", "tb/tb_flaw_sao/tb_flaw_sao_integration.sv"],
        "remed_sim": [VSIM, "-c", "work.tb_flaw_sao_integration", "-do", "run -all; quit -f"],
        "remed_marker": "ALL TESTS PASSED: SAO integration verified",
    },
    {
        "id": "D-04",
        "name": "tb_flaw_intra_rmd",
        "subsys": "Intra / RMD",
        "vlog_cmd": [VLOG, "-sv", "-work", "work", "+incdir+rtl/common", "+incdir+rtl/intra",
                     "rtl/common/parameter_pkg.vh", "rtl/common/hadamard_satd_4x4.v",
                     "rtl/intra/intra_rmd.v", "tb/tb_flaw_intra_rmd/tb_flaw_intra_rmd.sv"],
        "buggy_sim": [VSIM, "-c", "work.tb_flaw_intra_rmd", "-do", "run -all; quit -f"],
        "buggy_marker": "FLAW D-04 CONFIRMED",
        "remed_cmd": [VLOG, "-sv", "-work", "work", "+define+REMEDIATION_PATCH", "+incdir+rtl/common", "+incdir+rtl/intra",
                      "rtl/common/parameter_pkg.vh", "rtl/common/hadamard_satd_4x4.v",
                      "rtl/intra/intra_rmd.v", "tb/tb_flaw_intra_rmd/tb_flaw_intra_rmd.sv"],
        "remed_sim": [VSIM, "-c", "work.tb_flaw_intra_rmd", "-do", "run -all; quit -f"],
        "remed_marker": "ALL TESTS PASSED",
    },
    {
        "id": "D-08",
        "name": "tb_flaw_planar_overflow",
        "subsys": "Intra / Planar",
        "vlog_cmd": [VLOG, "-sv", "-work", "work", "+incdir+rtl/common", "+incdir+rtl/intra",
                     "rtl/common/parameter_pkg.vh", "tb/tb_flaw_planar_overflow/tb_flaw_planar_overflow.sv"],
        "buggy_sim": [VSIM, "-c", "work.tb_flaw_planar_overflow", "-do", "run -all; quit -f"],
        "buggy_marker": "FAILED: 2 Accumulator Overflow",
        "remed_cmd": [VLOG, "-sv", "-work", "work", "+define+REMEDIATION_PATCH", "+incdir+rtl/common", "+incdir+rtl/intra",
                      "rtl/common/parameter_pkg.vh", "tb/tb_flaw_planar_overflow/tb_flaw_planar_overflow.sv"],
        "remed_sim": [VSIM, "-c", "work.tb_flaw_planar_overflow", "-do", "run -all; quit -f"],
        "remed_marker": "ALL TESTS PASSED",
    },
    {
        "id": "D-03",
        "name": "tb_flaw_syntax_coeff_cg",
        "subsys": "Entropy / Coeff",
        "vlog_cmd": [VLOG, "-sv", "-work", "work", "+incdir+rtl/common", "+incdir+rtl/entropy",
                     "rtl/common/parameter_pkg.vh", "rtl/entropy/syntax_coeff.v",
                     "tb/tb_flaw_syntax_coeff_cg/tb_flaw_syntax_coeff_cg.sv"],
        "buggy_sim": [VSIM, "-c", "work.tb_flaw_syntax_coeff_cg", "-do", "run -all; quit -f"],
        "buggy_marker": "FLAW D-03 CONFIRMED",
        "remed_cmd": [VLOG, "-sv", "-work", "work", "+define+REMEDIATION", "+incdir+rtl/common", "+incdir+rtl/entropy",
                      "rtl/common/parameter_pkg.vh", "rtl/entropy/syntax_coeff.v",
                      "tb/tb_flaw_syntax_coeff_cg/tb_flaw_syntax_coeff_cg.sv"],
        "remed_sim": [VSIM, "-c", "work.tb_flaw_syntax_coeff_cg", "-do", "run -all; quit -f"],
        "remed_marker": "ALL 9 TESTS PASSED SPECIFICATION",
    },
    {
        "id": "D-11",
        "name": "tb_flaw_cabac_init",
        "subsys": "Entropy / CABAC",
        "vlog_cmd": [VLOG, "-sv", "-work", "work", "+incdir+rtl/common", "+incdir+rtl/entropy",
                     "rtl/common/parameter_pkg.vh", "rtl/entropy/ctx_model_store.v",
                     "tb/tb_flaw_cabac_init/tb_flaw_cabac_init.sv"],
        "buggy_sim": [VSIM, "-c", "work.tb_flaw_cabac_init", "-do", "run -all; quit -f"],
        "buggy_marker": "FLAW D-11 CONFIRMED",
        "remed_cmd": [VLOG, "-sv", "-work", "work", "+define+TEST_CONFORMANCE", "+incdir+rtl/common", "+incdir+rtl/entropy",
                      "rtl/common/parameter_pkg.vh", "rtl/entropy/ctx_model_store.v",
                      "tb/tb_flaw_cabac_init/tb_flaw_cabac_init.sv"],
        "remed_sim": [VSIM, "-c", "work.tb_flaw_cabac_init", "-do", "run -all; quit -f"],
        "remed_marker": "ALL 186 CONTEXT MODELS PASSED TABLE 9-39 BIT-ACCURATELY",
    },
    {
        "id": "D-10",
        "name": "tb_flaw_range_coder",
        "subsys": "Entropy / RangeCoder",
        "vlog_cmd": [VLOG, "-sv", "-work", "work", "+incdir+rtl/common", "+incdir+rtl/entropy",
                     "rtl/common/parameter_pkg.vh", "rtl/entropy/range_coder.v",
                     "tb/tb_flaw_range_coder/tb_flaw_range_coder.sv"],
        "buggy_sim": [VSIM, "-c", "work.tb_flaw_range_coder", "-do", "run -all; quit -f"],
        "buggy_marker": "FLAW D-10 CONFIRMED",
        "remed_cmd": [VLOG, "-sv", "-work", "work", "+define+REMEDIATION", "+incdir+rtl/common", "+incdir+rtl/entropy",
                      "rtl/common/parameter_pkg.vh", "rtl/entropy/range_coder.v",
                      "tb/tb_flaw_range_coder/tb_flaw_range_coder.sv"],
        "remed_sim": [VSIM, "-c", "work.tb_flaw_range_coder", "-do", "run -all; quit -f"],
        "remed_marker": "ALL RANGE CODER TESTS PASSED",
    },
    {
        "id": "D-05",
        "name": "tb_flaw_cu_split",
        "subsys": "Partitioning",
        "vlog_cmd": [VLOG, "-sv", "-work", "work", "+incdir+rtl/common", "+incdir+rtl/partition",
                     "rtl/common/parameter_pkg.vh", "rtl/common/hevc_interfaces.vh",
                     "rtl/partition/ctu_partitioner.v", "rtl/partition/mode_decision.v",
                     "tb/tb_flaw_cu_split/tb_flaw_cu_split.sv"],
        "buggy_sim": [VSIM, "-c", "work.tb_flaw_cu_split", "-do", "run -all; quit -f"],
        "buggy_marker": "FLAW D-05 CONFIRMED",
        "remed_cmd": None,
        "remed_sim": [VSIM, "-c", "+REMEDIATED", "work.tb_flaw_cu_split", "-do", "run -all; quit -f"],
        "remed_marker": "ALL TESTS PASSED SPECIFICATION",
    },
    {
        "id": "D-12",
        "name": "tb_flaw_lambda_rc",
        "subsys": "Rate Control",
        "vlog_cmd": [VLOG, "-sv", "-work", "work", "+incdir+rtl/common", "+incdir+rtl/rate_control",
                     "rtl/common/parameter_pkg.vh", "rtl/rate_control/lambda_calc.v",
                     "rtl/rate_control/rate_controller.v", "tb/tb_flaw_lambda_rc/tb_flaw_lambda_rc.sv"],
        "buggy_sim": [VSIM, "-c", "work.tb_flaw_lambda_rc", "-do", "run -all; quit -f"],
        "buggy_marker": "FLAW D-12 CONFIRMED",
        "remed_cmd": None,
        "remed_sim": [VSIM, "-c", "+REMEDIATED", "work.tb_flaw_lambda_rc", "-do", "run -all; quit -f"],
        "remed_marker": "ALL TESTS PASSED SPECIFICATION",
    },
]

def run_cmd(cmd, cwd=REPO_ROOT):
    proc = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    return proc.returncode, proc.stdout

def main():
    print("=" * 80)
    print(" HEVC Main10 Hardware Video Encoder - Algorithmic Flaw Testbench Suite")
    print(" ModelSim Altera 10.1d Headless Batch Regression")
    print("=" * 80)
    
    results = []
    start_time = time.time()
    
    for tc in TEST_CASES:
        t_id = tc["id"]
        name = tc["name"]
        subsys = tc["subsys"]
        print(f"\n>>> [{t_id}] Running {name} ({subsys}) ...")
        
        # 1. Compile Buggy RTL
        rc, out = run_cmd(tc["vlog_cmd"])
        if rc != 0:
            print(f"    [COMPILE ERROR] vlog failed for {name}!")
            print(out)
            results.append((t_id, subsys, name, "COMPILE_FAIL", "N/A"))
            continue
            
        # 2. Simulate Buggy RTL
        rc, out = run_cmd(tc["buggy_sim"])
        buggy_status = "FAIL"
        if tc["buggy_marker"] and tc["buggy_marker"] in out:
            buggy_status = "PROVEN (FAIL)"
        else:
            buggy_status = "UNCONFIRMED"
        print(f"    Buggy Run: {buggy_status}")
        
        # 3. Simulate Remediated RTL if available
        remed_status = "N/A"
        if tc["remed_sim"]:
            if tc["remed_cmd"]:
                rc, out = run_cmd(tc["remed_cmd"])
                if rc != 0:
                    print(f"    [REMED COMPILE ERROR] vlog failed for {name}!")
                    print(out)
                    remed_status = "REMED_COMPILE_FAIL"
            if remed_status != "REMED_COMPILE_FAIL":
                rc, out = run_cmd(tc["remed_sim"])
                if tc["remed_marker"] and tc["remed_marker"] in out:
                    remed_status = "PASS (100%)"
                else:
                    remed_status = "FAIL"
            print(f"    Remediated Run: {remed_status}")
            
        results.append((t_id, subsys, name, buggy_status, remed_status))
        
    elapsed = time.time() - start_time
    
    print("\n" + "=" * 80)
    print(f" REGRESSION SUMMARY TABLE (Completed in {elapsed:.1f}s)")
    print("=" * 80)
    print(f"{'Flaw ID':<8} | {'Subsystem':<22} | {'Testbench':<24} | {'Buggy Mode':<16} | {'Remediated Mode':<16}")
    print("-" * 94)
    for r in results:
        print(f"{r[0]:<8} | {r[1]:<22} | {r[2]:<24} | {r[3]:<16} | {r[4]:<16}")
    print("=" * 80)

if __name__ == "__main__":
    main()
