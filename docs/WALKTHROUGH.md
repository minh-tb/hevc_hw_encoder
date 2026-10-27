# HEVC Main10 Hardware Video Encoder - Repository Cleanup & Consolidation Walkthrough

## Executive Summary

To eliminate misleading and duplicate files across synthesis flows, testbenches, simulation runners, documentation, and transcripts, a comprehensive repository cleanup was executed following user-approved guidelines. Exactly **one canonical version** of each component is now preserved, eliminating over **560 MB** of stale caches, redundant files, and duplicate test suites.

---

## 1. Summary of Changes by Category

| Category | Canonical Maintained (KEEP) | Removed / Consolidated |
|---|---|---|
| **Synthesis & Toolflow** | **Vivado 2026.1 Flow** (`synth/run_vivado.bat`, `synth/synth_vivado.tcl`, `synth/package_ip.tcl`, `synth/verify_ip_catalog.tcl`, `synth/extract_vivado_results.py`) | **Quartus flow completely removed**: `hevc_encoder_top.qpf/.qsf`, `synth_hevc.tcl`, `hevc_encoder_top.sdc`, `extract_synth_results.py`, `db/`, `incremental_db/`, `output_files/`, `tonghop/`. Removed 10 superseded/one-off Vivado TCLs (`synth_dct_*.tcl`, `profile_*.tcl`, `check_*.tcl`), `synth/vivado_output_dct/`, 21 `*.backup.log/jou` files, and `.Xil/` (380 MB). |
| **IP Core Packaging** | `ip_repo/hevc_encoder_v1_0/` with exact 1-to-1 RTL synchronization (64 source files) and canonical GUI `xgui/hevc_encoder_v1_0.tcl` | Removed redundant identical GUI script `xgui/hevc_encoder_axi_top_v1_0.tcl`. Staged `hadamard_satd_4x4.v` and `mvp_predictor.v`. |
| **Simulation Runners** | `run_sim.do` (unified direct logging to `transcript_3frames.log`), `compile.do` (clean relative paths for restoring library in QP sweeps) | Removed obsolete `run.do`, `tb/modelsim_regression.do`, and 11 redundant individual flaw `.do` wrappers (`tb/tb_flaw_*/run_*.do`). |
| **Testbenches** | **Full Encoder**: [`tb_b_frame_encoder.v`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/tb_full_encoder/tb_b_frame_encoder.v) + [`tb_256x256_encoder.v`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/tb_full_encoder/tb_256x256_encoder.v)<br>**Transform**: [`tb_dct_top.sv`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/tb_dct_top/tb_dct_top.sv) + [`tb_transform_rigorous.v`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/tb_transform/tb_transform_rigorous.v)<br>**In-Loop**: [`tb_inloop_filters.sv`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/tb_inloop_filters/tb_inloop_filters.sv)<br>**MVP**: [`tb_mvp_predictor.sv`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/tb_mvp_predictor/tb_mvp_predictor.sv) | Removed outdated full-encoder TBs `tb_hevc_encoder_top.v` (64×64) and `tb_multi_ctu_encoder.v` (128×128). Removed duplicate `tb/tb_transform/tb_dct_top.v` (270 KB), `tb2d.v`, `tb_transform_1d.v`, `vec2d.hex` (4 MB). Consolidated `integration/tb_inloop_filters` into `tb/tb_inloop_filters` and deleted `integration/`. Promoted golden test vector file TB to `tb_mvp_predictor.sv`. Removed `tb/init_vals.v` and `tb/verify_psnr.py`. |
| **Scripts** | Canonical suite: `run_all_flaw_tb.py`, `verify_3frames_bins.py`, `regression_gate.py`, `visualize_and_evaluate_foreman.py`, `run_qp_sweep_and_bd_rate.py`, `f0_diff.py` | Removed wrappers & obsolete scripts: `visual_eval.py`, `visualize_and_evaluate_b_frames.py`, `compare_bins.py`, `compare_frame1_bins.py`, `run_rd_benchmark.py`, `balance_adder_trees.py`, and `scripts/debug/` (18 trace scripts). |
| **Documentation** | [`README.md`](file:///d:/UIT_Doc/hevc_hw_encoder/README.md), [`regression_results.md`](file:///d:/UIT_Doc/hevc_hw_encoder/regression_results.md), [`rtl_algorithmic_flaws_report.md`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl_algorithmic_flaws_report.md), and consolidated `docs/` (`WALKTHROUGH.md`, `CASE_STUDIES.md`, `datapath.md`, `CABAC.md`, `algorithmflowchart.md`, `TUQuadtree,Transform&Quantization_flowchart.md`) | Removed outdated `project_structure.txt`, `port_connection_map.md`, `antigravity.md`, `datapath_new.txt`, and placeholder `datapath.drawio`. Unlinked junction `artifact_link/`. In brain directory, kept only `walkthrough.md`, `hevc_hardware_optimization_case_studies.md`, and `project_cleanup_plan.md`. |
| **Personal & Media** | Preserved `resume/` and `Entropy Coding in HEVC.pdf`. Preserved test vectors (`foreman_*.hex`, `checker_*.hex`, `flat_*.hex`). | Removed `BaoCaoDoAn1_*.pptx` and `slides_text.txt`. Removed duplicate `foreman_input_*.png` and all transient `*.bmp` and `*.yuv` files. Updated `visualize_and_evaluate_foreman.py` to auto-clean temporary BMPs. |

---

## 2. Verification & Validation Results

Following consolidation, the entire verification suite was executed:

### A. Full-Encoder Simulation (`run_sim.do`)
- **Direct Logging**: Emits directly to `transcript_3frames.log` with zero intermediate duplication.
- **Completion**: 128×128 3-frame encoding finished cleanly in **9,742,065 ns** with 12/12 CTUs processed without stall or deadlock.

### B. CABAC Bin-by-Bin Conformance (`scripts/verify_3frames_bins.py`)
- Automatically regenerated reference `dec_output_3frames.txt` from `str_b_frame.bin` via HM 18.0 `TAppDecoder.exe`.
- **Result**: **100.00% BIT-EXACT MATCH across all 22,745 bins across all 3 frames**:
  - POC 0: 8,486 / 8,486 matched (100.00%)
  - POC 1: 7,202 / 7,202 matched (100.00%)
  - POC 2: 7,057 / 7,057 matched (100.00%)

### C. Spatial Pixel Conformance (`f0_diff.py` & `regression_gate.py`)
- **Frame 0**: Exact = 100.00% (24,576 / 24,576 samples), Max Diff = 0 across Y, Cb, Cr
- **Frame 1**: Exact = 100.00% (24,576 / 24,576 samples), Max Diff = 0 across Y, Cb, Cr
- **Frame 2**: Exact = 100.00% (24,576 / 24,576 samples), Max Diff = 0 across Y, Cb, Cr
- **Regression Gate**: Global Max Sample Difference = 0 (`PASS`).

### D. Algorithmic Flaw Testbench Suite (`scripts/run_all_flaw_tb.py`)
- **Dual-State Convergence**: **14/14 PROVEN BUGGY (FAIL)** and **14/14 PASS REMEDIATED (100%)** in 18.8 seconds.

### E. Surviving Unit Testbenches
- `tb/run_tb_axi.do`: All 9 SoC integration AXI tests PASSED.
- `tb/tb_spatial_availability/run.do`: 1,360 / 1,360 vector checks PASSED (100% Clause 6.4.1 conformant).
- `tb/tb_deblock/run.do`: 6,144 / 6,144 samples match HM reference, cross-CTU boundary filtering PASSED.
- `tb/tb_inter/run.do`: 1,184 / 1,184 sub-pel interpolation samples match (0 mismatches), Bi-Pred MC PASSED.
- `compile.do`: Cleanly compiles unified RTL library, `tb_b_frame_encoder.v`, and `tb_256x256_encoder.v`.

### F. Dangling Reference Scan
- Scanned all tracked source, script, doc, and testbench files across the repository for references to deleted files.
- **Result**: **0 dangling references** (100% clean).
