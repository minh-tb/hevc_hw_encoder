# HEVC Main10 Hardware Video Encoder — Architecture, Optimization & Verification Walkthrough

## Executive Summary

An exhaustive normative conformance audit comparing Verilog/SystemVerilog source code in `rtl/` directly against the official ITU-T H.265 (V11, 01/2026) specification PDF and Fraunhofer HM 18.0 reference software, followed by a **4-Pillar Cycles-per-CTU Optimization & TDP BRAM Zero-Replication** program and **Full-Chip Audit Remediation** (stall-safe `nal_writer`/`slice_controller` handshake, `u_inter_pred.mc_start` tie-off, `hevc_encoder_axi_top` edge-detected IRQ counters, and `address_generator` sensitivity parity), cut 3-frame average CTU latency by **51.0%** (`127,647 -> 62,568` cycles/CTU) and deblocking filter latency by **54.6%** (`15,936 -> 7,230` cycles/CTU) while preserving **100.00% bit-exact sample and CABAC bin conformance** and achieving **47.79 dB `PSNR_Y`** closed-loop UVM parity on Vivado `xsim`.
All behavioral/synthesis divergences in inter motion compensation were permanently eliminated via [`rtl/inter/mc_window_fetch.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/inter/mc_window_fetch.v) (`0` behavioral `` `ifdef SYNTHESIS `` branches remain; the `3` remaining `` `ifdef SYNTHESIS `` directives in `rtl/entropy/syntax_coeff.v`, `rtl/inter/mc_window_fetch.v`, and `rtl/inter/ref_frame_buffer.v` are strictly 4-state `===` X-safety guards with `11` simulation-only `` `ifndef SYNTHESIS `` init/reset blocks across 8 RTL files and `72` `synthesis translate_off` logging/assertion lines).

---

## 1. Summary of Architectural Changes & 4-Pillar Latency Optimization

| Category | Canonical Maintained / Implemented (KEEP) | Removed / Consolidated |
|---|---|---|
| **Pillar 1: Inter MC & TDP DPB (`mc_window_fetch.v`, `hevc_encoder_top.v`)** | True Dual-Port (TDP) 2-sample/cycle DPB reads (Port-A muxed between pipelined in-loop writeback `dpb_wr_*_d1` and `mc_window_fetch` even-column reads + Read-Only Port-B odd-column reads, yielding **0 extra BRAM tiles**) + `rd_hold` collision stall on Port-A writes + `0D/1D` fast fetch + drain-to-emit write-through bypass + vertical row-start window reuse (`row0_win`). | Replaced single-port DPB stall bottleneck; deleted `rtl/inter/streaming_subpel_filter.v` & obsolete `tb_streaming_subpel_filter.sv`; `0` behavioral `` `ifdef SYNTHESIS `` blocks remain. |
| **Pillar 2: Mode Decision (`mode_decision.v`, `hevc_encoder_top.v`)** | Depth-0 (`64x64`) bit-exact bypass + parameterized `FAST_EARLY_CU_SPLIT` (`0` default for 100% bit-exact sign-off & `D-05` `tb_flaw_cu_split`; `= 1` relaxes `eff_split_threshold` by `1.5×` at depths 1–2). | Eliminates dead evaluation cycles on non-encodable depth-0 64×64 root CUs. |
| **Pillar 3: Entropy Zero-CG Skip (`syntax_coeff.v`, `cabac_enc_top.v`, `hevc_encoder_top.v`)** | Three per-CU CG non-zero masks (`tu_cg_nonzero_mask_y[63:0]`, `_cb[15:0]`, `_cr[15:0]`) indexed by `quant_out_scan_idx[9:4]` and gated by `tu_cg_mask_en` (defaulting to all-1s when `tu_cg_mask_en !== 1'b1` for standalone `D-03` TB). Enforces Clause 7.3.8.11 inferred `coded_sub_block_flag = 1` on `cur_cg == 0` while skipping 32-cycle SRAM reads on all-zero CGs. | Eliminates wasted coeff-buffer SRAM reads across zero sub-blocks without altering encoded CABAC bins. |
| **Pillar 4: In-Loop Deblock & SAO/Inter Prefetch (`deblock_top.v`, `boundary_strength.v`, `decoder_inloop_filters.v`, `sao_top.v`, `ref_frame_buffer.v`, `inter_pred_top.v`)** | Combinational `bs_comb` / `qp_avg_comb` 1-cycle `Bs == 0` skip, grid-stepped edge traversal (`+2` Luma / `+4` Chroma), pipelined 1-sample/cycle `S_PIX_LOAD` (`db_pix_rd_ready`), skipping unmodified `p`/`q` write-backs (`!luma_skip_write`, `chroma_skip_write`) preserving `D-07`, plus `sao_top.v` BO bypass & `ref_frame_buffer.v`/`inter_pred_top.v` 4×4 Luma bypass (`ref_req_is_4x4_safe`). | Cuts `T_DB` from `15,936` to `7,230` cycles/CTU (`-54.6%`, well below `12,500` target) with `Stall_Inloop = 0`. |
| **Unit Verification** | [`tb/tb_mc_window_fetch/tb_mc_window_fetch.sv`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/tb_mc_window_fetch/tb_mc_window_fetch.sv) (6,272 samples across TU 4/8/16/32, Y/Cb/Cr, 0D/1D-H/1D-V/2D, boundary MVs, and `rd_hold` Port-A write collision stress + `1'bx` guard). | Deleted obsolete `tb_streaming_subpel_filter.sv`. |
| **IP Packaging** | `ip_repo/hevc_encoder_v1_0/src/` synchronized 1-to-1 with `rtl/` (**63 / 63** RTL `.v`/`.vh` source/header files at 100% SHA-256 parity + `hevc_encoder_top.xdc` = 64 files). | Removed `streaming_subpel_filter.v` from `synth/synth_vivado.tcl`, `synth/package_ip.tcl`, and `component.xml`. |
| **Normative Documentation** | `docs/H265_CONFORMANCE_MATRIX.md` (clause-by-clause, equation-by-equation mapping across In-loop, Transform/Pred, and CABAC syntax). | Page-calibrated extraction via `scripts/extract_h265_clauses.py` (spec page offset +17). |

---

## 2. Gate Verification Record (Gates G0 through G8)

### Gate G0: Divergence Proof (Pre-Remediation Mutation Test)
- **Command:** 3-frame simulation with `dump_stall = 1'b0` (`scratch/mutant/run_mutant.do`).
- **Result:** Conclusively reproduced and proved catastrophic divergence when in-loop filtering and reconstruction memory handshakes are decoupled:
  - Frame 0: `Y exact=94.0% max=81` (mismatches starting immediately at $x=16, y=0$).
  - Frame 1: `Y exact=3.5% max=83`.
  - Frame 2: `Y exact=3.3% max=171`.

### Gate G1: Behavioral Parity (`run_sim.do`)
- **Command:** `python scripts/regression_gate.py --enable-loop-filters --num-frames 3`
- **Result:** **100.00% BIT-EXACT MATCH across all 73,728 samples in Frames 0, 1, and 2** against HM 18.0 reference decoder (`Global Max Sample Difference = 0`) for both **post-filter** (`hw_recon.yuv` vs `dec_gate.yuv`) and **pre-filter** (`hw_recon_pre.yuv` vs `rec_before_filter.yuv`, `6CFC954D3A337CBF4D5C810DF83B5C71A372A6FFF4FD1CA724B55AA2EC115A38`):
  - Frame 0 (I-Slice, QP 29): Y exact 100.00% (max=0), Cb exact 100.00% (max=0), Cr exact 100.00% (max=0) | Quality vs original YUV: `39.02 dB Y / 39.34 dB YUV` (SSIM-Y `0.9628`).
  - Frame 1 (P-Slice, QP 26): Y exact 100.00% (max=0), Cb exact 100.00% (max=0), Cr exact 100.00% (max=0) | Quality vs original YUV: `39.34 dB Y / 40.15 dB YUV` (SSIM-Y `0.9627`).
  - Frame 2 (B-Slice, QP 26): Y exact 100.00% (max=0), Cb exact 100.00% (max=0), Cr exact 100.00% (max=0) | Quality vs original YUV: `39.44 dB Y / 40.21 dB YUV` (SSIM-Y `0.9616`).
  - 3-frame average quality ([`scripts/calc_psnr_ssim.py`](file:///d:/UIT_Doc/hevc_hw_encoder/scripts/calc_psnr_ssim.py)): `39.268 dB Y / 41.637 dB U / 41.952 dB V / 39.900 dB YUV`.
  - **Pre-Optimization Baseline 4-QP Sweep (`2026-11-14`, [`qp_sweep_results.json`](file:///d:/UIT_Doc/hevc_hw_encoder/qp_sweep_results.json), `QP ∈ {22, 27, 32, 37}`):** Archived from pre-optimization HEAD (`73,728 / 73,728 max_diff = 0` at every QP; `BD-Rate +148.58%`, `BD-PSNR -5.11 dB` vs HM 18.0; not re-run post-4-Pillar optimization).
- **Pipeline Throughput Profile ([`scripts/profile_pipeline_throughput.py`](file:///d:/UIT_Doc/hevc_hw_encoder/scripts/profile_pipeline_throughput.py)):**
  - **3-Frame Average Latency (`FAST_EARLY_CU_SPLIT = 0`, Post-Remediation):** **`62,568` cycles/CTU** (`-51.0%` vs `127,647` baseline, `< 71,348` target) | **`T_MD = 9,888`**, **`T_TQ = 14,172`**, **`T_DB = 7,230`** (`-54.6%` vs `15,936` baseline, `<= 12,500` target), **`T_CABAC = 40,142`**, **`Stall = 9.95%` (`10.0%`)**, **`Stall_Inloop = 0`** across all 12 CTUs.
  - **Pre-Remediation Isolated `-gFAST_EARLY_CU_SPLIT=1` Check (`1.5× eff_split_threshold` at depths 1–2):** **`63,959` cycles/CTU** (`T_MD = 7,230` `-27.6%`, `T_TQ = 13,455` `-5.1%`, `T_DB = 5,530` `-23.5%`, `T_CABAC = 45,112` `+11.9%`), `3,023 B`, `27,028 / 27,028` 6-field exact CABAC bins, `73,728 / 73,728` samples `max_diff = 0`, `PSNR-Y = 39.262 dB`, `PSNR-YUV = 40.109 dB`.

### Gate G2: Synthesis-Define Parity (`tb/run_sim_synthdef.do`)
- **Command:** `vsim -c -do tb/run_sim_synthdef.do` (compiled with `+define+SYNTHESIS+REMEDIATION+CFG_TOTAL_FRAMES=3`).
- **Result:** Finished cleanly at `8,001,545 ns` (`800154` cycles total, `-2,144` cycles vs pre-remediation `8,022,985 ns`) with **identical** throughput profile (`AVG Total = 62,568`, `T_DB = 7,230`) and **100% SHA-256 IDENTICAL** binary outputs between G1 (behavioral) and G2 (`+define+SYNTHESIS`):
  - `str_b_frame.bin` (`3,175 B`): `B6544062BB2ED515C4FA48C77439D026694DE895F4CB4DDE1934EB23E16F1B99`
  - `hw_recon.yuv` (`147,456 B`): `FDAB258067650458E281E0DF5F2C0DE33FA19D57B8B56FAE2E014CAF409E683F`

### Gate G3: Bitstream Invariance & HM Decoder Conformance
- **Command:** `HM\bin\mgwmake\gcc-mingw-14.2\x86_64\release\TAppDecoder.exe -b str_b_frame.bin -o dec_out.yuv -d 10`
- **Result:** Clean decode of all 3 frames with exit code 0.
- **CABAC Bin Conformance (`scripts/verify_3frames_bins.py`):**
  - Total Bins (with Pillar 3 zero-CG skipping, CTU-delayed dynamic `BO`/`EO`/`OFF` SAO, and Rate Control enabled): **28,962 / 28,962 bins (100.00% BIT-EXACT)** across all 6 fields (`bin`, `type`, `range`, `pstate`, `valmps`, `ctx`) in both `transcript_3frames.log` and `transcript_synthdef.log`:
    - POC 0: `8,496 / 8,496` bins (100.00%).
    - POC 1: `10,022 / 10,022` bins (100.00%).
    - POC 2: `10,444 / 10,444` bins (100.00%).

### Gate G4: Flaw Testbench Regression Suite (`scripts/run_all_flaw_tb.py`)
- **Command:** `python scripts/run_all_flaw_tb.py`
- **Result:** **28/28 test runs PASSED** (`19.9s`, 14/14 PROVEN BUGGY + 14/14 PASS REMEDIATED):
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
- **Active Post-Remediation Verified Suites (`9` unit + `1` AXI SoC = `10` re-verified directly after `2026-11-19` RTL remediation edits, ModelSim 10.1d; all `26` suites pass across `2026-11-16..19`):**
  - **SoC Integration AXI Top (`tb/run_tb_axi.do` / `tb/tb_axi_top/tb_hevc_encoder_axi_top.sv`):** ALL 9 TESTS PASSED (`119 B` AXI4-Stream bitstream output, `TLAST=1`, `irq` aligned with `STATUS.DONE=1`).
  - **NAL & Slice/GOP Control (`tb_nal_writer` incl. Test 3 stalled `nal_end_pending` + final-byte `0x03` EPB = `10 B`, `tb_slice_controller`, `tb_gop_controller`):** All PASSED (`2026-11-19`).
  - **MC Window Fetch Engine (`tb/tb_mc_window_fetch/run.do`):** `ALL WINDOW CHECKS PASSED (6272 samples verified)` (`2026-11-19`).
  - **Inter Prediction & Sub-pel Cores (`tb/tb_inter/run.do` `tb_b_prediction`, `tb_ref_frame_buffer`, `tb_interpolation_filter`, `tb_mvp_predictor`):** `tb_b_prediction` & `tb_ref_frame_buffer` re-verified PASS (`2026-11-19`); `tb_interpolation_filter` (`0` fails) & `tb_mvp_predictor` (`20,000` tests) verified on pre-remediation HEAD.
  - **Intra, Transform, Quant & Partitioning (`tb_intra_pred_top`, `tb_transform_rigorous`, `tb_intra_planar`, `tb_intra_dc`, `tb_ref_sample_filter`, `tb_inv_quant`, `tb_spatial_availability`, `tb_rate_control_rdo`):** `tb_intra_pred_top` (`616,224` samples) & `tb_transform_rigorous` (`240/240`) re-verified PASS (`2026-11-19`); remaining units verified prior to `2026-11-19` cleanup edits.
  - **In-Loop Deblocking & SAO (`tb_boundary_strength`, `tb/tb_deblock/run.do`, `tb_db_filter_luma`, `tb_inloop_filters`, `tb_sao`, `tb_sao_stats`):** `tb_boundary_strength` (`1,010` vectors incl. Chroma CBF Clause 8.7.2.4, `0` errors) re-verified PASS (`2026-11-19`); remaining suites verified prior to `2026-11-19` edits.
  - **Entropy (`tb_range_coder`, `tb_ctx_model_store`, `tb_syntax_pred`):** Verified on unchanged entropy modules (`19,391` matches, `186` models, `0` errors). *(Supplemental: `tb_entropy_chain` runs standalone emitting `7` bytes without golden `flat_field_qp32.bin`, and `tb_intra_angular` runs `0` vectors due to missing `.dat` files.)*
- **Known Legacy Un-Updated Standalone TBs (15 un-updated TBs fail elaboration/assertions due to RTL port/design evolution):** `tb_syntax_coeff`, `tb_mode_decision`, `tb_db_filter_chroma`, `tb_syntax_cu`, `tb_ctu_partitioner`, `tb_pu_cu_splitter`, `tb_ctu_raster_scan`, `tb_recon_unit`, `tb_hpel_filter_luma`, `tb_hpel_filter_chroma`, `tb_mc_unit`, `tb_tz_search`, `tb_fwd_quant`, `tb_dct_top`, `tb_frame_store`.

### Gate G6: IP Packaging Parity
- **Command:** SHA-256 comparison between `rtl/` and `ip_repo/hevc_encoder_v1_0/src/`.
- **Result:** `diff=0` across all **63 / 63** Verilog/SystemVerilog `.v`/`.sv` and header `.vh` files (`64` total files in `ip_repo/hevc_encoder_v1_0/src/` including `hevc_encoder_top.xdc`), and Vivado IP Integrator catalog verification emitted `[SUCCESS] HEVC Encoder IP Catalog & IP Integrator Verification PASSED!` (`synth/vivado_verify.log`).

### Gate G7: AMD Vivado 2026.1 Synthesis & Timing Closure (`hevc_encoder_axi_top`)
- **Target Part:** AMD Zynq UltraScale+ `xczu19eg-ffvb1517-2-e`
- **Target Clock:** 50.00 MHz ($T = 20.000\text{ ns}$)
- **Setup Timing Slack (WNS):** **+10.360 ns (MET)** (`Data Path Delay = 9.422 ns`, `WPWS = 9.458 ns`, `0 / 147,907` failing pulse checks)
- **Total Negative Slack (TNS):** **0.000 ns (0 failing endpoints out of 389,569 total / 344,074 intra-clock endpoints)**
- **Estimated Maximum Frequency ($F_{\max}$):** **103.73 MHz**
- **CLB LUTs:** **226,544 / 522,720 (43.34%)**
  - Logic LUTs: **218,785 (41.86%)**
  - Memory LUTs (LUTRAM + SRL): **7,759 (4.81%)** (`7,728` LUTRAM + `31` SRL)
- **CLB Registers (FFs):** **140,046 / 1,045,440 (13.40%)**
- **Unintended Latches (`LDCE`) & Warnings:** **0 `LDCE` latches (0.00%)**, **0 `Synth 8-614` incomplete sensitivity warnings**, **0 `LUTAR-1` warnings**
- **Block RAM (BRAM Tile):** **41.5 Tiles (4.22%)** (`0` extra BRAMs from DPB TDP conversion)
  - RAMB36/FIFO: 33 / 984 (3.35%)
  - RAMB18: 17 / 1,968 (0.86%)
- **DSP Slices:** **63 / 1,968 (3.20%)**
- **Power Estimation:** **2.199 W Total** (`1.085 W` Dynamic, `1.115 W` Static, `26.8 °C` Junction Temp)

### Gate G8: Dual-Tier UVM & HM 18.0 Closed-Loop Verification (`Vivado 2026.1 xsim`)
- **Suite Runner (`python uvm/run_uvm_suite.py --all --simulator xsim`):** `97.98s`, **ALL PASS (`ERR=0 FAT=0 SVA=0`)**:
  - **Tier 1 (`cabac_uvm_test`):** `5,940` bins (`18` slices), **`1,266 / 1,266 B`** (`0` mismatches), `Max Buffered 0xFFs = 32`, `Carry Ripples = 2`, `409 / 1,675` stall cycles, **`cg_cabac = 100.00%`**.
  - **Tier 2A (`hevc_ral_audit_test`):** `hw_reset = 10/10`, `bit_bash = 10/10`, `664R / 653W` AXI4-Lite, `Scoreboard Errors = 0`, `cg_soc_axi = 66.67%`.
  - **Tier 2B+C (`hevc_full_uvm_test`, Default `+BS_FORCE_HDR_STALL=0 +BS_STALL_PROB=25`):** `4` intact NALs (`28, 34, 11, 197 B` -> **`270 B`**), `384/384` DRAM writes, `59/270` stall cycles, **`cg_soc_axi = 100.00%`**, HM 18.0 `exit=0` (`12,288 B` YUV), **`PSNR_Y = 47.79 dB`** (`U = 31.37 dB`, `V = 35.12 dB`) — matching QuestaSim!
  - **Forced Cycle-0 Header Backpressure (`+BS_FORCE_HDR_STALL=1 +BS_STALL_PROB=25`):** `PASS` (`ERR=0 FAT=0 SVA=0`, `5.12s`), `4` intact NALs, **`269 B`**, `97/269` stall cycles, **`cg_soc_axi = 100.00%`**, HM 18.0 `exit=0`, **`PSNR_Y = 47.79 dB`** (`U = 31.37 dB`, `V = 35.12 dB`).
