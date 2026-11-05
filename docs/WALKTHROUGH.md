# HEVC Main10 Hardware Video Encoder - Repository Cleanup, Audit & MC Architecture Walkthrough

## Executive Summary

An exhaustive normative conformance audit comparing Verilog/SystemVerilog source code in `rtl/` directly against the official ITU-T H.265 (V11, 01/2026) specification PDF and Fraunhofer HM 18.0 reference software was executed.
The legacy behavioral/synthesis discrepancy in inter-prediction motion compensation has been permanently resolved through **Option A (Sliding-Column Window DPB Fetch Engine, `mc_window_fetch.v`)**, removing all `` `ifdef SYNTHESIS `` bifurcations and eliminating the unsynthesizable `streaming_subpel_filter.v`.

---

## 1. Summary of Changes

| Category | Canonical Maintained (KEEP) | Removed / Consolidated |
|---|---|---|
| **Inter MC Architecture** | `rtl/inter/mc_window_fetch.v` (Option A sliding-column window fetcher: 64 reads at luma row start + 8 reads/col shift; 16 reads at chroma row start + 4 reads/col shift) feeding dual unified `subpel_interpolation_core.v` | Completely deleted `rtl/inter/streaming_subpel_filter.v`, `tb/tb_inter/tb_streaming_subpel_filter.sv`, and eliminated all `` `ifdef SYNTHESIS `` blocks from `rtl/top/hevc_encoder_top.v`. |
| **Unit Verification** | `tb/tb_mc_window_fetch/tb_mc_window_fetch.sv` (exhaustive 576-sample LFSR window verification across all TU sizes 4/8/16/32, components Y/Cb/Cr, arbitrary boundary MVs, back-to-back bubbles) | Deleted obsolete `tb_streaming_subpel_filter.sv`. |
| **IP Packaging** | `ip_repo/hevc_encoder_v1_0/src/` synchronized 1-to-1 with `rtl/` (63 source/header files, 100% SHA-256 parity) | Removed `streaming_subpel_filter.v` from `synth/synth_vivado.tcl`, `synth/package_ip.tcl`, and `component.xml`. |
| **Normative Documentation** | `docs/H265_CONFORMANCE_MATRIX.md` (clause-by-clause, equation-by-equation mapping across In-loop, Transform/Pred, and CABAC syntax) | Page-calibrated extraction via `scripts/extract_h265_clauses.py` (spec page offset +17). |

---

## 2. Gate Verification Record (Gates G0 through G7)

### Gate G0: Divergence Proof (Pre-Remediation Mutation Test)
- **Command:** 3-frame simulation with `dump_stall = 1'b0` (`scratch/mutant/run_mutant.do`).
- **Result:** Conclusively reproduced and proved catastrophic divergence when in-loop filtering and reconstruction memory handshakes are decoupled:
  - Frame 0: `Y exact=94.0% max=81` (mismatches starting immediately at $x=16, y=0$).
  - Frame 1: `Y exact=3.5% max=83`.
  - Frame 2: `Y exact=3.3% max=171`.

### Gate G1: Behavioral Parity (`run_sim.do`)
- **Command:** `python scripts/regression_gate.py --enable-loop-filters --num-frames 3`
- **Result:** **100.00% BIT-EXACT MATCH across all 73,728 samples in Frames 0, 1, and 2** against HM 18.0 reference decoder (`Global Max Sample Difference = 0`):
  - Frame 0 (I-Slice): Y exact 100.00% (max=0), Cb exact 100.00% (max=0), Cr exact 100.00% (max=0).
  - Frame 1 (P-Slice): Y exact 100.00% (max=0), Cb exact 100.00% (max=0), Cr exact 100.00% (max=0).
  - Frame 2 (B-Slice): Y exact 100.00% (max=0), Cb exact 100.00% (max=0), Cr exact 100.00% (max=0).

### Gate G2: Synthesis-Define Parity (`tb/run_sim_synthdef.do`)
- **Command:** `vsim -c -do tb/run_sim_synthdef.do` (compiled with `+define+SYNTHESIS+REMEDIATION+CFG_TOTAL_FRAMES=3`).
- **Result:** Emitted `str_b_frame.bin` SHA-256 hash:
  `1F535FDB6CCA7A3523736004426386B2AB31853791241D1FBEA03AA7F7D25792`
  **100% SHA-256 IDENTICAL** between G1 (behavioral) and G2 (`+define+SYNTHESIS`).

### Gate G3: Bitstream Invariance & HM Decoder Conformance
- **Command:** `HM\bin\mgwmake\gcc-mingw-14.2\x86_64\release\TAppDecoder.exe -b str_b_frame.bin -o dec_out.yuv -d 10`
- **Result:** Clean decode of all 3 frames with exit code 0.
- **CABAC Bin Conformance (`scripts/verify_3frames_bins.py`):**
  - Total Bins: **22,901 / 22,901 bins (100.00% BIT-EXACT)** across all 6 fields (`bin`, `type`, `range`, `pstate`, `valmps`, `ctx`).
  - POC 0: 8,486 / 8,486 bins (100.00%).
  - POC 1: 7,263 / 7,263 bins (100.00%).
  - POC 2: 7,152 / 7,152 bins (100.00%).

### Gate G4: Flaw Testbench Regression Suite (`scripts/run_all_flaw_tb.py`)
- **Command:** `python scripts/run_all_flaw_tb.py`
- **Result:** **28/28 test runs PASSED** (14/14 PROVEN BUGGY + 14/14 PASS REMEDIATED):
  - D-01 (AMVP): PROVEN (FAIL) / PASS (100%)
  - D-13 (Sub-pel MC): PROVEN (FAIL) / PASS (100%)
  - D-02 (DST-VII): PROVEN (FAIL) / PASS (100%)
  - D-14 (MDCS): PROVEN (FAIL) / PASS (100%)
  - D-07 (Deblock): PROVEN (FAIL) / PASS (100%)
  - D-06 (Chroma tC): PROVEN (FAIL) / PASS (100%)
  - D-09 (SAO): PROVEN (FAIL) / PASS (100%)
  - D-04 (Intra RMD): PROVEN (FAIL) / PASS (100%)
  - D-08 (Planar): PROVEN (FAIL) / PASS (100%)
  - D-03 (Coeff CG): PROVEN (FAIL) / PASS (100%)
  - D-11 (CABAC Init): PROVEN (FAIL) / PASS (100%)
  - D-10 (Range Coder): PROVEN (FAIL) / PASS (100%)
  - D-05 (CU Split): PROVEN (FAIL) / PASS (100%)
  - D-12 (Lambda RC): PROVEN (FAIL) / PASS (100%)

### Gate G5: Unit & Subsystem Test Suites
- **SoC Integration AXI Top (`tb/run_tb_axi.do`):** ALL 9 TESTS PASSED.
- **Inter Prediction Unit (`tb/tb_inter/run.do`):** Bi-Prediction Motion Compensation Unit Verification PASSED.
- **Deblocking Filter (`tb/tb_deblock/run.do`):** 6,144 / 6,144 samples match HM reference, cross-CTU boundary filtering PASSED.
- **Spatial Availability (`tb/tb_spatial_availability/run.do`):** 2,720 / 2,720 vector checks PASSED (100% Clause 6.4.1 conformant, 0 failures).
- **MC Window Fetch Engine (`tb/tb_mc_window_fetch/run.do`):** ALL WINDOW CHECKS PASSED (576 samples verified across LFSR patterns).

### Gate G6: IP Packaging Parity
- **Command:** SHA-256 comparison between `rtl/` and `ip_repo/hevc_encoder_v1_0/src/`.
- **Result:** `missing=0, mismatches=0` across all 63 Verilog and header files.

### Gate G7: AMD Vivado 2026.1 Synthesis & Timing Closure
- **Target Part:** AMD Zynq UltraScale+ `xczu19eg-ffvb1517-2-e`
- **Target Clock:** 50.00 MHz ($T = 20.000\text{ ns}$)
- **Setup Timing Slack (WNS):** **+3.847 ns (MET)**
- **Total Negative Slack (TNS):** **0.000 ns (0 failing endpoints out of 325,536)**
- **Estimated Maximum Frequency ($F_{\max}$):** **61.91 MHz**
- **CLB LUTs:** **187,823 / 522,720 (35.93%)**
  - Logic LUTs: 181,984
  - Memory LUTs (LUTRAM + SRL): 5,839 (5,808 LUTRAM + 31 SRL)
- **CLB Registers (FFs):** **122,796 / 1,045,440 (11.75%)**
- **Unintended Latches (`LDCE`):** **0 (0.00%)**
- **Block RAM (BRAM Tile):** **36.5 Tiles (3.71%)**
  - RAMB36/FIFO: 30 / 984 (3.05%)
  - RAMB18: 13 / 1,968 (0.66%)
- **DSP Slices:** **221 / 1,968 (11.23%)**
- **Power Estimation:** **2.015 W Total** (0.902 W Dynamic, 1.113 W Static)
