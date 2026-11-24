# HEVC Main10 Hardware Video Encoder — Architecture, Optimization & Verification Walkthrough

## Executive Summary

An exhaustive normative conformance audit comparing Verilog/SystemVerilog source code in `rtl/` directly against the official ITU-T H.265 (V11, 01/2026) specification PDF and Fraunhofer HM 18.0 reference software — followed by the `v2.0` **4-Pillar Optimization**, **`v2.1` Phase A `150 MHz` Timing Closure & Single-Path RTL Stripping**, **`v3.0` Phase B1 `128x128` Search Cache + Phase B2 2-Bank CTU Ping-Pong & Split CABAC FE/BE**, and **`v4.0` Phase C1–C3 In-Loop Fusion, Dual-Lane TQ/Quant Overlap & `180 MHz` Timing Closure** — reduced steady-state CTU period by **78.2%** (`127,647 -> 62,568 -> 39,970 -> 27,785 cycles/CTU`), eliminated **100%** of CABAC and In-Loop pipeline stalls (`Stall_CABAC = 0`, `Stall_Inloop = 0`), closed **`180 MHz` (`5.555 ns`)** timing in Vivado (`WNS = +0.250 ns`, $F_{\max} = 188.50\text{ MHz}$), eliminated all `REMEDIATION` preprocessor branches from production RTL (`0` in `rtl/` and `ip_repo/hevc_encoder_v1_0/src/`), and preserved **100.00% bit-exact sample (`max_diff = 0`) and CABAC bin conformance** against HM 18.0.
All behavioral/synthesis divergences in inter motion compensation remain permanently eliminated via [`rtl/inter/mc_window_fetch.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/inter/mc_window_fetch.v) (`0` behavioral `` `ifdef SYNTHESIS `` branches; only `3` 4-state `===` X-safety `` `ifdef SYNTHESIS `` guards remain in `rtl/entropy/syntax_coeff.v`, `rtl/inter/mc_window_fetch.v`, and `rtl/inter/ref_frame_buffer.v`).

---

## 1. Summary of `v2.0 -> v3.0 -> v4.0` Architectural Optimizations

| Phase / Pillar | Canonical Implemented Architecture | Latency / Timing Impact |
|---|---|---|
| **Single-Path RTL Cleanup & Lockbox** | Stripped all `REMEDIATION`/`NO_REMEDIATION` `` `ifdef `` branches from all **64** production files (`60` `.v` + `4` `.vh`) in `rtl/` & `ip_repo/hevc_encoder_v1_0/src/`. Historical buggy baselines live exclusively in [`tb/flaw_baseline_rtl/`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/flaw_baseline_rtl). | Pure single-path Main10 RTL; `28/28` flaw suite (`14/14` FAIL vs `14/14` PASS) intact. |
| **Phase A Timing Closure & Stage Pipelining (`v2.1`)** | Pipelined `intra_rmd.v` (`wB_v -> planar_sum_v`), 2-stage pipelined `db_filter_luma.v` + output skid buffer in `decoder_inloop_filters.v`, 17-cycle pipelined `S_LOAD_CG` in `syntax_coeff.v`, and 2-bank `coeff_buffer.v` ping-pong (`v2.1-phase-a-150mhz`). | Closed **`150 MHz` (`6.667 ns`)** Vivado timing (`WNS >= 0`, 0 failing endpoints). |
| **Phase B1 `128x128` Luma Search Cache ([`ref_search_cache.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/inter/ref_search_cache.v))** | On-chip `128x128` Luma search-window cache (`4 RAMB36 + 1 RAMB18`) integrated into `inter_pred_top.v` / `tz_search.v`. | Eliminated Frame 2 `T_MD` spike (`30,830 -> 8,442`, `T_MD` avg `6,403` cyc/CTU). |
| **Phase B2 2-Bank CTU Ping-Pong & Split FE/BE (`v3.0`)** | Dual-bank CTU pixel/in-loop/CABAC (`ctu_bin_ram_0/1`) ping-pong, **4-entry `cu_fifo` & `tu_meta_fifo`**, **4-bank `coeff_buffer.v` (`DEPTH=4096`)**, and decoupled `cabac_state` (FE) / `cabac_be_state` (BE) FSMs in `hevc_encoder_top.v`. | **`39,970 cycles/CTU`** (`Stall_CABAC = 0`, `157.51 MHz` Fmax, `+0.318 ns` WNS @ `150 MHz`). |
| **Phase C1 In-Loop Fusion & `frame_store` Overlap (`9c0c9ee`)** | Decoupled AXI4 [`frame_store.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/recon/frame_store.v) writes, inline fused `S_SAO`/`S_DUMP` in [`decoder_inloop_filters.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/top/decoder_inloop_filters.v), and 3-plane parallel `Y/Cb/Cr` [`sao_stats.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/inloop_filters/sao_stats.v). | **`30,937 cycles/CTU`** (`-22.6%` vs `v3.0`), **`Stall_Inloop = 0`**, `165.59 MHz` Fmax (`+0.628 ns` @ `150 MHz`). |
| **Phase C2 Dual-Lane TQ & Inter TU Overlap (`ecac14c`)** | Dual-lane `u_fwd_quant_0/1` + `u_inv_quant_0/1`, zero-CBF Luma IDCT bypass (`reg_tu_comp == 2'd0`), even/odd banked [`coeff_buffer.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/entropy/coeff_buffer.v), and 2-bank `pred_sram` Inter TU prefetch overlap + 4-cycle end-of-slice flush. | **`27,739 cycles/CTU`** (`-30.6%` vs `v3.0`), `158.83 MHz` Fmax (`+0.371 ns` @ `150 MHz`). |
| **Phase C3 `180 MHz` Timing Closure (`d15568b`, `v4.0` Freeze)** | `2-entry be_skid_mem` in [`cabac_enc_top.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/entropy/cabac_enc_top.v), streaming reverse-order `S_LOAD_CG` in [`syntax_coeff.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/entropy/syntax_coeff.v), and pipeline registers in `intra_angular` / `intra_planar` / `ref_sample_filter` / `ref_frame_buffer` / `hevc_encoder_top`. | **`27,785 cycles/CTU`**, **`188.50 MHz` Fmax** (`+0.250 ns` WNS @ **`180 MHz`**), **`0` stalls**, `1,696.1 / 282.7 / 30.8 / 13.3 fps` @ Fmax. |
| **Core Pillars (`v2.0` Foundation)** | TDP 2-sample/cycle DPB reads (`mc_window_fetch.v`), Depth-0 `64x64` bypass (`FAST_EARLY_CU_SPLIT = 0`), Pillar 3 per-CU `tu_cg_nonzero_mask` zero-CG skip, and Pillar 4 `deblock_top` `bs_comb` 1-cycle skip + write-skip. | `T_DB = 6,951` cycles/CTU (`<= 12,500` target), total 3-frame sim cut `8,001,545 ns -> 4,920,865 ns -> 3,458,665 ns` (`-56.8%` vs `v2.0`). |
| **IP Packaging & Compliance** | `ip_repo/hevc_encoder_v1_0/src/` synchronized 1-to-1 with `rtl/` (**64 / 64** RTL `.v`/`.vh` files SHA-256 identical + `hevc_encoder_top.xdc` = `65` files); normative mapping in `docs/H265_CONFORMANCE_MATRIX.md`. | `0` SHA-256 mismatches; `ipx::check_integrity status: 1`. |

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
- **Result:** **100.00% BIT-EXACT MATCH across all 73,728 samples in Frames 0, 1, and 2** against HM 18.0 reference decoder (`Global Max Sample Difference = 0`) for both **post-filter** (`hw_recon.yuv` vs `dec_gate.yuv`) and **pre-filter** (`hw_recon_pre.yuv` vs `rec_before_filter.yuv`, `24F92B0B464255389E3D23DD6E87508798A4CCE8F3074E9088D482936192BA78`):
  - Frame 0 (I-Slice, QP 29): Y exact 100.00% (max=0), Cb exact 100.00% (max=0), Cr exact 100.00% (max=0) | Quality vs original YUV: `39.024 dB Y / 39.549 dB YUV`.
  - Frame 1 (P-Slice, QP 26): Y exact 100.00% (max=0), Cb exact 100.00% (max=0), Cr exact 100.00% (max=0) | Quality vs original YUV: `39.343 dB Y / 40.168 dB YUV`.
  - Frame 2 (B-Slice, QP 26): Y exact 100.00% (max=0), Cb exact 100.00% (max=0), Cr exact 100.00% (max=0) | Quality vs original YUV: `39.438 dB Y / 40.227 dB YUV`.
  - 3-frame average quality ([`scripts/calc_psnr_ssim.py`](file:///d:/UIT_Doc/hevc_hw_encoder/scripts/calc_psnr_ssim.py)): **`39.268 dB Y / 41.866 dB U / 42.373 dB V / 39.981 dB YUV`**.
  - **Refreshed `v4.0` 4-QP Sweep ([`qp_sweep_results.json`](file:///d:/UIT_Doc/hevc_hw_encoder/qp_sweep_results.json), `QP ∈ {22, 27, 32, 37}`):** Re-executed via `python scripts/run_qp_sweep_and_bd_rate.py --force` (`73,728 / 73,728 max_diff = 0` at every QP: `5,249 B / 3,118 B / 2,071 B / 1,440 B`; **`BD-Rate +145.52%`, `BD-PSNR -5.02 dB`** vs HM 18.0).
- **Pipeline Throughput Profile ([`scripts/profile_pipeline_throughput.py`](file:///d:/UIT_Doc/hevc_hw_encoder/scripts/profile_pipeline_throughput.py)):**
  - **3-Frame Steady-State CTU Initiation Interval (`v4.0`, Phase A–C3):** **`27,785` cycles/CTU** (`-30.5%` vs `v3.0` `39,970`, `-55.6%` vs `v2.0` `62,568`, `-78.2%` vs `127,647` baseline) | **`T_MD = 6,403`**, **`T_TQ = 11,220`**, **`T_DB = 6,951`** (`<= 12,500` target), **`T_CABAC = 35,094`** (2-stage overlapped FE->BE lifetime), **`Stall_CABAC = 0`** and **`Stall_Inloop = 0` (`0.00%`)** across all 12 CTUs.
  - **Projected Steady-State FPS:** **`1,619.6 / 269.9 / 29.4 / 12.7 fps`** (`128x128 / CIF / 720p / 1080p`) @ `180 MHz`, **`1,696.1 / 282.7 / 30.8 / 13.3 fps`** @ **`188.50 MHz` achieved Fmax**, and **`1,799.6 / 299.9 / 32.7 / 14.1 fps`** @ `200 MHz`.

### Gate G2: Synthesis-Define Parity (`tb/run_sim_synthdef.do`)
- **Command:** `vsim -c -do tb/run_sim_synthdef.do` (compiled with `+define+SYNTHESIS +define+CFG_TOTAL_FRAMES=3` — zero `+define+REMEDIATION`).
- **Result:** Finished cleanly at `3,458,665 ns` (`345,866.5` cycles total, F0 `135,266`, F1 `97,531`, F2 `100,622` cycles) with **identical** throughput profile (`Avg CTU Period = 27,785`, `T_DB = 6,951`, `Stall_CABAC = 0`, `Stall_Inloop = 0`) and **100% SHA-256 IDENTICAL** binary outputs between G1 (behavioral) and G2 (`+define+SYNTHESIS`):
  - `str_b_frame.bin` (`3,134 B`): `FF2D0A83990DC94160627A8E061C8EC54F9EB07BECA3AC93F5C036ADD3DF820B`
  - `hw_recon.yuv` (`147,456 B`): `AE739FE1EDA914849D180F309A0B55B00AEC85B04619B49270DFBFAC0ADB049E`

### Gate G3: Bitstream Invariance & HM Decoder Conformance
- **Command:** `HM\bin\mgwmake\gcc-mingw-14.2\x86_64\release\TAppDecoder.exe -b str_b_frame.bin -o dec_out.yuv -d 10`
- **Result:** Clean decode of all 3 frames with exit code 0.
- **CABAC Bin Conformance (`scripts/verify_3frames_bins.py`):**
  - Total Bins (with Pillar 3 zero-CG skipping, streaming reverse-order `S_LOAD_CG`, CTU-delayed dynamic `BO`/`EO`/`OFF` SAO, and Rate Control enabled): **28,581 / 28,581 bins (100.00% BIT-EXACT)** across all 6 fields (`bin`, `type`, `range`, `pstate`, `valmps`, `ctx`) in both `transcript_3frames.log` and `transcript_synthdef.log`:
    - POC 0: `8,349 / 8,349` bins (100.00%).
    - POC 1: `9,819 / 9,819` bins (100.00%).
    - POC 2: `10,413 / 10,413` bins (100.00%).

### Gate G4: Flaw Testbench Regression Suite (`scripts/run_all_flaw_tb.py`)
- **Command:** `python scripts/run_all_flaw_tb.py`
- **Result:** **28/28 test runs PASSED** (`19.0s`, 14/14 PROVEN BUGGY + 14/14 PASS REMEDIATED):
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
- **Result:** `diff=0` across all **64 / 64** RTL `.v` and `.vh` files (`60` `.v` + `4` `.vh`, `65` total files in `ip_repo/hevc_encoder_v1_0/src/` including `hevc_encoder_top.xdc`), and `ipx::check_integrity status: 1` / Vivado IP Integrator catalog verification passed (`synth/vivado_verify.log`).

### Gate G7: AMD Vivado 2026.1 Synthesis & `180 MHz` Timing Closure (`hevc_encoder_axi_top`)
- **Target Part:** AMD Zynq UltraScale+ `xczu19eg-ffvb1517-2-e`
- **Target Clock:** **180.00 MHz** ($T = 5.555\text{ ns}$, `hevc_encoder_top.xdc`)
- **Setup Timing Slack (WNS):** **+0.250 ns (MET)** (`Data Path Delay = 5.087 ns`, 18 logic levels, `WPWS = +2.235 ns`, `0 / 175,456` failing pulse checks)
- **Total Negative Slack (TNS):** **0.000 ns (0 failing endpoints out of 452,482 total / 384,993 intra-clock endpoints)**
- **Estimated Maximum Frequency ($F_{\max}$):** **188.50 MHz**
- **CLB LUTs:** **243,266 / 522,720 (46.54%)**
  - Logic LUTs: **237,812 (45.50%)**
  - Memory LUTs (LUTRAM + SRL): **5,454 (3.38%)** (`5,424` LUTRAM + `30` SRL)
- **CLB Registers (FFs):** **169,846 / 1,045,440 (16.25%)**
- **Unintended Latches (`LDCE`) & Warnings:** **0 `LDCE` latches (0.00%)**, **0 `Synth 8-614` incomplete sensitivity warnings**, **0 `LUTAR-1` warnings**
- **Block RAM (BRAM Tile):** **60.0 Tiles (6.10%)** (includes dual-bank CTU ping-pong, `ref_search_cache`, `ctu_bin_ram_0/1`)
  - RAMB36/FIFO: 49 / 984 (4.98%)
  - RAMB18: 22 / 1,968 (1.12%)
- **DSP Slices:** **54 / 1,968 (2.74%)**
- **Power Estimation:** **5.031 W Total** (`3.892 W` Dynamic, `1.139 W` Static, `29.1 °C` Junction Temp)

### Gate G8: Dual-Tier UVM & HM 18.0 Closed-Loop Verification (`Vivado 2026.1 xsim`)
- **Suite Runner (`python uvm/run_uvm_suite.py --all --simulator xsim`):** `78.23 s`, **ALL GATES CONVERGED (`ERR=0 FAT=0 SVA=0`)**:
  - **Tier 1 (`cabac_uvm_test`):** `5,940` bins (`18` slices), **`1,266 / 1,266 B`** (`0` mismatches), `Max Buffered 0xFFs = 32`, `Carry Ripples = 2`, **`cg_cabac = 100.00%`**.
  - **Tier 2A (`hevc_ral_audit_test`):** `hw_reset = 10/10`, `bit_bash = 10/10`, `Scoreboard Errors = 0`.
  - **Tier 2B+C (`hevc_full_uvm_test`):** `4` intact NALs (**`256 B`**), `384/384` AXI4 DRAM writes, **`cg_soc_axi = 100.00%`**, HM 18.0 `exit=0` (`12,288 B` decoded YUV); plus `+BS_FORCE_HDR_STALL=1 +BS_STALL_PROB=25` stress (`72/256` stalls, `0` errors).
  - **Gate G6 Check:** `64/64` RTL↔IP SHA-256 parity verified inside `run_uvm_suite.py`.
