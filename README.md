# High-Performance Synthesizable HEVC/H.265 Main10 Hardware Video Encoder

An RTL implementation of a high-throughput, pipelined **HEVC (ITU-T H.265 / ISO/IEC 23008-2)** video compression hardware encoder designed in synthesizable **Verilog / SystemVerilog**. The architecture accelerates the full encoding loop from raw video inputs to standard-compliant NAL bitstreams, targeting modern FPGA and ASIC architectures.

---

## Conformance & Performance Scorecard

- **Bit-Exact Conformance:** **100.00% sample-by-sample match (`max_diff == 0`)** across all 3 frames ($Y, Cb, Cr$: `73,728 / 73,728` post-filter `hw_recon.yuv` vs. `dec_gate.yuv` and `73,728 / 73,728` pre-filter `hw_recon_pre.yuv` vs. `rec_before_filter.yuv`) against the Fraunhofer **HM 18.0** reference decoder on `Foreman 128x128` 10-bit (pre-optimization 4-QP sweep $QP \in \{22, 27, 32, 37\}$ archived from `2026-11-14` in `qp_sweep_results.json`).
- **4-Pillar Latency & Throughput Optimization:** Achieved **62,747 cycles/CTU** 3-frame average (**-50.8%** vs `127,647` baseline, `< 71,348` target) and **`T_DB = 7,230` cycles/CTU** (**-54.6%** vs `15,936` baseline, `<= 12,500` target) with **`Stall_Inloop = 0`** across all 12 CTUs (`T_MD = 9,982`, `T_TQ = 14,172`, `T_CABAC = 40,321`) via TDP 2-sample/cycle DPB reads (**0 extra BRAM tiles**) + `mc_window_fetch` 0D/1D fast fetch/row-start reuse/bypass + `rd_hold`, `mode_decision` depth-0 bypass & `FAST_EARLY_CU_SPLIT=0` default (`eff_split_threshold` `1.5×` relaxation at `=1` also verified 100% bit-exact: `63,959` avg, `T_MD = 7,230`, `T_DB = 5,530`, `T_CABAC = 45,112`, `3,023 B`, `PSNR-YUV = 40.109 dB`), per-CU `tu_cg_nonzero_mask` zero-CG skip, `deblock_top` `bs_comb` 1-cycle skip/pipelined load/unmodified write-skip, `sao_top.v` BO bypass, and `ref_frame_buffer.v`/`inter_pred_top.v` 4×4 Luma bypass.
- **Entropy Coding Conformance:** Standard-compliant CABAC bitstream output verified symbol-by-symbol (**28,962 / 28,962 bins, 100.00% bit-exact** across POC 0: 8,496, POC 1: 10,022, POC 2: 10,444 with Pillar 3 `tu_cg_nonzero_mask` zero-CG skipping, full-CTU 32-band `BO` / last-CTU `EO` SAO RDO, and Rate Control enabled) against the normative HM decoder without a single syntax desynchronization.
- **Physical Synthesis Convergence & Timing Closure:** Fully synthesized in **AMD Vivado 2026.1 Enterprise** on **Zynq UltraScale+ `xczu19eg-ffvb1517-2-e`** (`hevc_encoder_axi_top`, `-verilog_define {SYNTHESIS=1 REMEDIATION=1}`) with complete timing closure (**WNS = +10.360 ns, Fmax = 103.73 MHz @ 50 MHz target**, 0 failing endpoints out of 389,457, **0 `LUTAR-1` warnings**, and **0 unintended latches**).
- **PPA Optimization:** Area optimized to **225,006 LUTs (43.05%)** (-223,910 LUTs / -49.88% vs. initial baseline), **140,035 FFs (13.39%)** (-203,995 FFs / -59.30% vs. initial baseline), **33 RAMB36 + 17 RAMB18 Blocks (41.5 BRAM Tiles, 4.22% — 0 extra BRAMs from TDP DPB conversion)**, and **63 DSPs (3.20%)** (-857 DSPs / -93.15% vs. initial baseline), with total on-chip power at **2.198 W** (**1.084 W** Dynamic, **1.115 W** Static).
- **Regression & IP Parity Suite:** **100% Convergence** across all **14 / 14** dual-state algorithmic flaw testbenches (`28 / 28` runs in `34.6s`, `scripts/run_all_flaw_tb.py`), **26** self-checking unit & SoC testbenches PASS (`tb_mc_window_fetch` `6,272` samples incl. `rd_hold` stall stress, `tb_boundary_strength` `1,010` vectors incl. Chroma CBF, `tb_sao`, `tb_sao_stats`, `tb_inloop_filters` Phase 1 & 2 `FullFrame 24,576/24,576`, `tb_deblock` `6,144` matches, `tb_db_filter_luma` `10,000` tests, `tb_b_prediction`, `tb_interpolation_filter`, `tb_spatial_availability`, `tb_ref_frame_buffer`, `tb_range_coder`, `tb_ctx_model_store`, `tb_syntax_pred`, `tb_rate_control_rdo`, `tb_intra_pred_top`, `tb_intra_planar`, `tb_intra_dc`, `tb_ref_sample_filter`, `tb_mvp_predictor`, `tb_inv_quant`, `tb_transform_rigorous`, `tb_nal_writer`, `tb_gop_controller`, `tb_slice_controller`, plus **9 / 9** AXI4-Lite/AXI4 SoC integration tests `119 B` `TLAST=1` in [`tb/tb_axi_top/tb_hevc_encoder_axi_top.sv`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/tb_axi_top/tb_hevc_encoder_axi_top.sv) via [`tb/run_tb_axi.do`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/run_tb_axi.do)), **Full 3-Frame Gate 1 (`run_sim.do`) == Gate 2 (`tb/run_sim_synthdef.do`) Conformance (`str_b_frame.bin` 3,178 B, `hw_recon.yuv` & `hw_recon_pre.yuv` 147,456 B bit-identical, `max_diff = 0` across all 73,728 samples)** via `scripts/regression_gate.py`, and **63 / 63** SHA-256 synchronized IP-XACT source files (`ip_repo/hevc_encoder_v1_0/src/`).

---

## AMD Zynq UltraScale+ Synthesis Metrics (`xczu19eg-ffvb1517-2-e`)

Out-of-context synthesis executed with `SYNTHESIS=1 REMEDIATION=1` on top-level `hevc_encoder_axi_top`:

| Resource Type | Initial Baseline | Phase 2 Optimized | Sign-Off Final | Available | Final Utilization % | Net Reduction vs. Baseline |
|---|---:|---:|---:|---:|---|---|
| **CLB LUTs** | 448,916 | 225,933 | **225,006** | 522,720 | **43.05%** | **-223,910 LUTs (-49.88%)** |
| *-- Logic LUTs* | 441,925 | 218,942 | **217,247** | 522,720 | **41.56%** | **-224,678 LUTs (-50.84%)** |
| *-- Memory LUTs (LUTRAM + SRL)* | 6,991 | 6,991 | **7,759** | 161,280 | **4.81%** | 7,728 LUTRAM + 31 SRL |
| **CLB Registers (FF)** | 344,030 | 249,980 | **140,035** | 1,045,440 | **13.39%** | **-203,995 FFs (-59.30%)** |
| **Register as Latch (`LDCE`)** | 0 | 0 | **0** | 1,045,440 | **0.00%** | 0 unintended latches |
| **Unique Control Sets** | 14,641 | 10,733 | **7,668** | 130,680 | **5.87%** | **-6,973 sets (-47.63%)** |
| **Block RAM** | 12.5 Tiles | 30.0 Tiles | **33 RAMB36 + 17 RAMB18** | 984 Tiles | **4.22%** | **41.5 Tiles (+0 extra from TDP)** |
| *-- RAMB36/FIFO* | 11 | 27 | **33** | 984 | **3.35%** | +22 `RAMB36E2` |
| *-- RAMB18* | 3 | 6 | **17** | 1968 | **0.86%** | +14 `RAMB18E2` |
| **DSP48E2 Slices** | 920 | 209 | **63** | 1,968 | **3.20%** | **-857 DSPs (-93.15%)** |
| **Estimated $F_{\max}$** | 96.36 MHz | 105.33 MHz | **103.73 MHz** | 50.00 MHz | **2.07× margin** | **WNS: +10.360 ns (MET)**, TNS: 0.000 ns (0 / 389,457 failing), WPWS: 9.458 ns |
| **Total On-Chip Power** | 2.910 W | 1.943 W | **2.198 W** | — | — | **Dynamic: 1.084 W**, Device Static: 1.115 W |
| **Methodology `LUTAR-1`** | 1 Advisory | 1 Advisory | **0 Advisories** | — | **0 Warnings** | Synchronous reset register `core_rst_n_reg` |

---

## Rate-Distortion & Multi-QP Conformance

Evaluated on **Foreman 128x128 10-bit** (post-optimization 3-frame sign-off run: POC 0 I-Slice QP 29 `39.02 dB Y / 39.34 dB YUV / 0.9628 SSIM-Y`, POC 1 P-Slice QP 26 `39.34 dB Y / 40.15 dB YUV / 0.9627 SSIM-Y`, POC 2 B-Slice QP 26 `39.44 dB Y / 40.21 dB YUV / 0.9616 SSIM-Y`; 3-frame average `PSNR-Y = 39.268 dB`, `PSNR-U = 41.637 dB`, `PSNR-V = 41.952 dB`, `PSNR-YUV = 39.900 dB`) and archived pre-optimization 4-QP sweep (`2026-11-14`, $QP \in \{22, 27, 32, 37\}$, [qp_sweep_results.json](file:///d:/UIT_Doc/hevc_hw_encoder/qp_sweep_results.json)) vs. Fraunhofer HM 18.0 software anchor:

| Operating Point | HM 18.0 Rate (kbps) | HM 18.0 PSNR-Y (dB) | HW Encoder Rate (kbps) | HW Encoder PSNR-Y (dB) | $\Delta$ PSNR (dB) | Sample Exactness | Max Diff | Conformance |
|---|---|---|---|---|---|---|---|---|
| **QP = 22** | 186.56 | 42.83 | **424.16** | **42.33** | -0.50 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |
| **QP = 27** | 103.84 | 39.65 | **252.24** | **39.22** | -0.43 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |
| **QP = 32** | 64.00 | 36.58 | **168.16** | **37.41** | +0.83 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |
| **QP = 37** | 38.40 | 33.62 | **116.80** | **34.77** | +1.15 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |

- **Bjøntegaard Delta Rate (BD-Rate):** **+148.58%** (`+148.579%`, archived `2026-11-14` pre-4-Pillar sweep in `qp_sweep_results.json`; reflects single-pass fixed-hardware RDO trade-off against floating-point multi-pass software search).
- **Bjøntegaard Delta PSNR (BD-PSNR):** **-5.11 dB** (`-5.1084 dB`, archived `2026-11-14` baseline; average quality delta across equivalent bitrates against reference software anchor).
- **Bit-Exact Conformance:** **100.00% across all 4 QPs** (`max_diff == 0` on all 73,728 samples in archived `2026-11-14` sweep; default post-optimization Foreman I/P/B regression re-verified 100.00% `max_diff == 0` across all 73,728 samples).
- Rate-distortion curves are visualized in [rd_curve.svg](file:///d:/UIT_Doc/hevc_hw_encoder/rd_curve.svg) (source metrics in [qp_sweep_results.json](file:///d:/UIT_Doc/hevc_hw_encoder/qp_sweep_results.json)).

---

## Key Hardware Modules

### 1. Prediction & Motion Estimation
- **Intra Prediction (`rtl/intra/`):**
  - **Rough Mode Decision (`rtl/intra/intra_rmd.v` + `rtl/common/hadamard_satd_4x4.v`):** Evaluates **4 Luma modes** (`Planar = 0`, `DC = 1`, `Hor = 10`, `Ver = 26`) via **4x4-tiled Hadamard SATD** (split-stage `signed [12:0]`/`signed [14:0]` butterflies, `wr_bank`/`rd_bank` ping-pong double-buffered 16-sample residual banks, and Stage-1 `row_t` start-edge latch) across full `4x4`, `8x8`, `16x16`, and `32x32` CU/PU sizes, plus normative **5-candidate Chroma Intra RDO** (`Planar`, `Ver = 26`, `Hor = 10`, `DC`, `DM_CHROMA`) per ITU-T H.265 Table 8-2 and sequential 1-pixel/cycle reference loading (`T3-14`) with $4\times4$ Chroma MDCS scan (`Clause 7.4.9.11`).
  - **Final Intra Prediction Reconstruction (`rtl/intra/intra_pred_top.v`, `rtl/intra/intra_angular.v`):** Supports all 35 Luma prediction modes (Planar, DC, and 33 Angular directions) for residual generation, with the `hevc_encoder_top.v` Chroma `above-right` reference fetch bit-5 truncation fix (`abs_top_x_raw` / `rmd_abs_top_x_c_raw`).
- **Inter Prediction (`rtl/inter/`):**
  - **Integer Motion Estimation (IME):** Hardware-optimized Test Zone Search (TZ-Search) algorithm with diamond and raster search patterns.
  - **Fractional Motion Estimation (FME):** Half-pel and quarter-pel interpolation filters (8-tap luma, 4-tap chroma).
  - **Motion Compensation & TDP DPB (`mc_window_fetch.v`, `subpel_interpolation_core.v`):** True Dual-Port (TDP) 2-sample/cycle DPB reads (Port-A muxed between pipelined writeback `dpb_wr_*_d1` and `mc_window_fetch` + Read-Only Port-B, **0 extra BRAM tiles**) with `rd_hold` collision stall, `0D/1D` fast fetch, drain-to-emit write-through bypass, and vertical `row0_win` reuse.
  - Pipelined reference sample buffering and motion vector predictor (MVP) merge evaluation (`FAST_EARLY_CU_SPLIT = 0` default in `mode_decision.v` with depth-0 64×64 bit-exact bypass).

### 2. Transform & Quantization Engine
- **2D Transform (`rtl/transform/`):**
  - Synthesizable 1D core implementing DCT-II (4x4, 8x8, 16x16, 32x32) and 4x4 DST-VII (`dct_top.v`; unit-verified in `tb_flaw_dst7`, while in the 3-frame Foreman top-level run CUs split to 8x8 minimum so Luma `tu_size_log2=2` count is `0`).
  - 2D transform realized via dual-port matrix transposition RAM (`transpose_ram_32x32.v`).
  - *Encoder subset:* residual quadtree (RQT) depth is fixed at 0, so TU size = CU size. CU quadtree splitting still gives 8×8 to 32×32 TUs. Partitioning is PART_2Nx2N only (see T3-11/T3-12 in [`docs/H265_CONFORMANCE_MATRIX.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/H265_CONFORMANCE_MATRIX.md)).
- **Quantization (`rtl/quant/`):**
  - Configurable QP forward quantization (`fwd_quant.v`) with sign-magnitude handling.
  - Paired inverse quantization (`inv_quant.v`) with ITU-T Table 8-10 Chroma QP mapping for the reconstruction loop.

### 3. Reconstruction & In-Loop Filters
- **Deblocking Filter (`rtl/inloop_filters/`):**
  - Boundary strength (`boundary_strength.v` `bs_comb`/`qp_avg_comb`) and 1-cycle `Bs == 0` fast-skip in `deblock_top.v` with grid-stepped traversal (`+2`/`+4`), pipelined 1-sample/cycle `S_PIX_LOAD` (`db_pix_rd_ready`), and unmodified write-back skip (`T_DB = 7,230` cycles/CTU, `-54.6%`).
  - Normal and strong filtering paths with threshold adaptivity.
- **Sample Adaptive Offset (SAO):**
  - Band Offset (BO) and Edge Offset (EO) classification datapaths (`0°, 90°, 135°, 45°`) with 2-phase single-port BRAM neighbor read (`S_REQ_PIX -> S_REQ_N1 -> S_WAIT_PIX`), internal `64x10b` line caching and `EO_45` right-border `n0_rd_valid` handling in [`sao_top.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/inloop_filters/sao_top.v), latched neighbor BO offset forwarding in [`decoder_inloop_filters.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/top/decoder_inloop_filters.v), and full-CTU sequential `Y -> Cb -> Cr` 32-band BO RDO (causality border-skip `x>=60||y>=60` Y / `x>=28||y>=30` C when non-last, symmetric `[-15, +15]` clamp matching `syntax_sao.v` `cMax=31`, and `ctu_qp` Q8 lambda LUT) plus last-CTU (`is_last_col && is_last_row`) EO 4-class RDO in [`sao_stats.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/inloop_filters/sao_stats.v) (`T3-13`).

### 4. CABAC Arithmetic Entropy Encoder & Synthesis Hygiene
- **CTU-Delayed Bitstream Serialization (`rtl/entropy/cabac_enc_top.v`):**
  - Synchronous Block RAM bin queue (`ctu_bin_ram`, `8192 x 10-bit`, `2 RAMB36E2 + 1 RAMB18E2`) with 1-cycle lookahead `drain_prefetched_valid` BRAM serializer buffers `coding_quadtree()` syntax bins during CTU reconstruction so `sao(rx, ry)` is normatively emitted first after `sao_stats` finishes (`Clause 7.3.8.2`).
- **Binary Arithmetic Range Coder (`rtl/entropy/range_coder.v`):**
  - Fully pipelined renormalization engine emitting standard-compliant byte streams with 16-bit carry-propagation protection.
- **Context Modeling (`rtl/entropy/ctx_model_store.v`):**
  - **186** CABAC context models (`0..185`) initialized in **186 cycles** per slice type (I/P/B).
- **Syntax Generators (`rtl/entropy/syntax_*.v`):**
  - Hardware binarization for CU modes, split flags, transform tree, SAO offsets (`cMax=31`), and quantized residual coefficients (`syntax_coeff.v`) with per-CU `tu_cg_nonzero_mask` zero-CG skipping (`cur_cg == 0` inferred `coded_sub_block_flag = 1`, `tu_cg_mask_en` gated).
- **Simulation-vs-Synthesis Parity:** `0` behavioral `` `ifdef SYNTHESIS `` blocks remain in `rtl/` (`3` 4-state `===` X-safety `` `ifdef SYNTHESIS `` guards in `rtl/entropy/syntax_coeff.v`, `rtl/inter/mc_window_fetch.v`, and `rtl/inter/ref_frame_buffer.v`, `11` `` `ifndef SYNTHESIS `` init/clear blocks across 8 RTL files, and `72` `synthesis translate_off` directives for deterministic simulation startup/logging). Gate 1 (`run_sim.do`) and Gate 2 (`tb/run_sim_synthdef.do`, `+define+SYNTHESIS`) on [`tb/tb_full_encoder/tb_b_frame_encoder.v`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/tb_full_encoder/tb_b_frame_encoder.v) produce bit-identical `str_b_frame.bin` (`3,178 B`, SHA-256 `542231A85C24C6D600096E46F971DE0274442D49B9A74630355576EAFDB4C0FA`) and `hw_recon.yuv` (`147,456 B`, SHA-256 `FDAB258067650458E281E0DF5F2C0DE33FA19D57B8B56FAE2E014CAF409E683F`) at **62,747 cycles/CTU** average latency.

---

## Verification & Toolflow Execution

1. **3-Frame Full-Encoder Simulation (Gate 1 & Gate 2 `+define+SYNTHESIS`) & Verification:**
   ```bash
   vsim -c -do "do run_sim.do; quit -f"
   vsim -c -do "do tb/run_sim_synthdef.do; quit -f"
   python scripts/verify_3frames_bins.py
   python scripts/regression_gate.py --enable-loop-filters --num-frames 3
   ```
   - Runs [`tb/tb_full_encoder/tb_b_frame_encoder.v`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/tb_full_encoder/tb_b_frame_encoder.v) across Foreman `128x128` 10-bit (POC 0 I, POC 1 P, POC 2 B).
2. **AXI4-Lite / AXI4 SoC Integration & Dual-State Algorithmic Flaw Regression:**
   ```bash
   vsim -c -do "do tb/run_tb_axi.do; quit -f"
   python scripts/run_all_flaw_tb.py
   ```
   - Exercises [`tb/tb_axi_top/tb_hevc_encoder_axi_top.sv`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/tb_axi_top/tb_hevc_encoder_axi_top.sv) (`9 / 9` tests) and all 14 dual-state flaw testbenches (`28 / 28` buggy vs. remediated runs).
3. **Multi-QP Benchmark & Rate-Distortion Sweep:**
   ```bash
   python scripts/run_qp_sweep_and_bd_rate.py
   ```
4. **AMD Vivado Out-of-Context Synthesis & Metrics Extraction:**
   ```bash
   synth\run_vivado.bat synth
   python synth/extract_vivado_results.py
   ```
5. **Packaging Vivado IP Core:**
   ```bash
   synth\run_vivado.bat package
   ```
6. **Detailed Architecture, Flowcharts & Interface Specifications:**
   - **System Datapath & Pipeline:** [`docs/datapath.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/datapath.md)
   - **Top-Level Algorithm Flowchart:** [`docs/algorithmflowchart.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/algorithmflowchart.md)
   - **Top-Level Port Connections & Interfaces:** [`docs/port_connections_hevc_top.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/port_connections_hevc_top.md)
   - **Major Subsystems ("Bif Modules") Flowcharts:** [`docs/bif_modules_flowcharts.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/bif_modules_flowcharts.md)
   - **CABAC Entropy Coding Subsystem:** [`docs/CABAC.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/CABAC.md)
   - **TU Quadtree, Transform & Quantization:** [`docs/TUQuadtree,Transform&Quantization_flowchart.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/TUQuadtree,Transform&Quantization_flowchart.md)
   - **IC Design & Remediation Case Studies:** [`docs/CASE_STUDIES.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/CASE_STUDIES.md) and [`docs/WALKTHROUGH.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/WALKTHROUGH.md)

