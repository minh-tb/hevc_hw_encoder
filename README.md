# High-Performance Synthesizable HEVC/H.265 Main10 Hardware Video Encoder

An RTL implementation of a high-throughput, pipelined **HEVC (ITU-T H.265 / ISO/IEC 23008-2)** video compression hardware encoder designed in synthesizable **Verilog / SystemVerilog**. The architecture accelerates the full encoding loop from raw video inputs to standard-compliant NAL bitstreams, targeting modern FPGA and ASIC architectures.

---

## Conformance & Performance Scorecard (`v4.0-final-signoff`)

- **Bit-Exact Conformance:** **100.00% sample-by-sample match (`max_diff == 0`)** across all 3 frames ($Y, Cb, Cr$: `73,728 / 73,728` post-filter `hw_recon.yuv` vs. `dec_gate.yuv` and `73,728 / 73,728` pre-filter `hw_recon_pre.yuv` vs. `rec_before_filter.yuv`) against the Fraunhofer **HM 18.0** reference decoder on `Foreman 128x128` 10-bit (and **100.00% `max_diff == 0` across all 4 QPs** $QP \in \{22, 27, 32, 37\}$ in refreshed [`qp_sweep_results.json`](file:///d:/UIT_Doc/hevc_hw_encoder/qp_sweep_results.json)).
- **`v4.0` Throughput & Timing Optimization (Phase A + B + Phase C1–C3):** Achieved **`27,785 cycles/CTU` steady-state CTU initiation interval** (**-30.5%** vs `v3.0` `39,970`, **-55.6%** vs `v2.0` `62,568`, **-78.2%** vs initial `127,647` baseline; total 3-frame simulation `3,458,665 ns` / `345,866.5` cycles), **`T_MD = 6,403`**, **`T_TQ = 11,220`**, **`T_DB = 6,951`** (`<= 12,500` target), **`T_CABAC = 35,094`** (2-stage overlapped FE->BE lifetime), **`Stall_CABAC = 0`** and **`Stall_Inloop = 0` (`0.00%`)** across all 12 CTUs. Projected steady-state throughput reaches **`1,619.6 / 269.9 / 29.4 / 12.7 fps`** (`128x128 / CIF / 720p / 1080p`) at **`180 MHz`**, and **`1,696.1 / 282.7 / 30.8 / 13.3 fps`** at achieved **`188.50 MHz` $F_{\max}$**, enabled by:
  - **Phase A & B Foundation (`v2.1 -> v3.0`):** `intra_rmd` / `db_filter_luma` pipelining, `128x128` Luma [`ref_search_cache.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/inter/ref_search_cache.v), 2-bank CTU Ping-Pong, 4-entry `cu_fifo` / `tu_meta_fifo`, and split CABAC FE/BE FSMs (`39,970` cyc/CTU, `157.51 MHz`).
  - **Phase C1 In-Loop & `frame_store` Overlap (`9c0c9ee`):** Decoupled AXI4 [`frame_store.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/recon/frame_store.v) flush, inline fused `S_SAO`/`S_DUMP` in [`decoder_inloop_filters.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/top/decoder_inloop_filters.v), and 3-plane parallel `Y/Cb/Cr` [`sao_stats.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/inloop_filters/sao_stats.v) (`39,970 -> 30,937` cyc/CTU, **`Stall_Inloop = 0`**).
  - **Phase C2 Dual-Lane TQ & Inter TU Overlap (`ecac14c`):** Dual-lane `fwd_quant_0/1` + `inv_quant_0/1`, zero-CBF Luma IDCT bypass, even/odd banked [`coeff_buffer.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/entropy/coeff_buffer.v), and 2-bank `pred_sram` Inter TU prefetch overlap + 4-cycle end-of-slice flush (`30,937 -> 27,739` cyc/CTU).
  - **Phase C3 `180 MHz` Timing Closure (`d15568b`, Final RTL Freeze):** `2-entry be_skid_mem` in [`cabac_enc_top.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/entropy/cabac_enc_top.v), streaming reverse-order `S_LOAD_CG` in [`syntax_coeff.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/entropy/syntax_coeff.v), and pipeline registers across `intra_pred_idx` / `intra_angular` / `intra_planar` / `ref_sample_filter` / `ref_frame_buffer` (`27,785` cyc/CTU, **`188.50 MHz` Fmax**).
- **Entropy Coding Conformance:** Standard-compliant CABAC bitstream output verified symbol-by-symbol (**28,581 / 28,581 bins, 100.00% bit-exact** across POC 0: 8,349, POC 1: 9,819, POC 2: 10,413; `str_b_frame.bin` `3,134 B` with Pillar 3 `tu_cg_nonzero_mask` zero-CG skipping, full-CTU 32-band `BO` / last-CTU `EO` SAO RDO, and Rate Control enabled) against HM 18.0 without a single syntax desynchronization.
- **Physical Synthesis Convergence & `180 MHz` Timing Closure:** Fully synthesized in **AMD Vivado 2026.1 Enterprise** on **Zynq UltraScale+ `xczu19eg-ffvb1517-2-e`** (`hevc_encoder_axi_top`, `-verilog_define {SYNTHESIS=1}`, `5.555 ns` / `180 MHz` constraint) with **complete timing closure (`WNS = +0.250 ns`, $F_{\max} = 188.50\text{ MHz}$, `TNS = 0.000 ns` across `452,482` total / `384,993` intra-clock endpoints, `WPWS = +2.235 ns` across `175,456` endpoints, 0 `Synth 8-614`, 0 `LUTAR-1`, 0 unintended latches)**.
- **PPA Summary:** Synthesizes to **243,266 LUTs (46.54%)** (-45.81% vs initial `448,916` baseline), **169,846 FFs (16.25%)** (-50.63% vs baseline), **49 RAMB36 + 22 RAMB18 Blocks (60.0 BRAM Tiles, 6.10%)**, and **54 DSPs (2.74%)** (-94.13% vs baseline), with total on-chip power at **5.031 W** (**3.892 W** Dynamic, **1.139 W** Static @ `29.1 °C`).
- **Pure Single-Path Production RTL, Regression, Dual-Tier UVM & IP Parity:** **0 `REMEDIATION` directives** across all **64 production files (`60` `.v` + `4` `.vh`)** in [`rtl/`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl) and [`ip_repo/hevc_encoder_v1_0/src/`](file:///d:/UIT_Doc/hevc_hw_encoder/ip_repo/hevc_encoder_v1_0/src/) (**64 / 64** SHA-256 identical + `hevc_encoder_top.xdc` = `65` packaged files), **0 behavioral `` `ifdef SYNTHESIS `` blocks**, **14 / 14** dual-state algorithmic flaw testbenches (`28 / 28` runs in `scripts/run_all_flaw_tb.py` in `19.0 s`, using locked baselines in [`tb/flaw_baseline_rtl/`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/flaw_baseline_rtl)), **9 / 9** AXI4-Lite/AXI4 SoC tests (`113 B`, `TLAST=1`, `irq=1`), **Gate G8 Dual-Tier UVM (`Vivado 2026.1 xsim` in `78.23 s`, `PASS`)** (`Tier 1`: `1,266/1,266 B`, `cg_cabac=100%`; `Tier 2A`: `10/10` RAL; `Tier 2B+C`: **`256 B`**, `384/384` DRAM writes, `cg_soc_axi=100%`, HM 18.0 `exit=0`; plus `+BS_FORCE_HDR_STALL=1 +BS_STALL_PROB=25` `72/256` stalls, `0` errors), and **Gate 1 (`run_sim.do`) == Gate 2 (`tb/run_sim_synthdef.do`) Conformance (`str_b_frame.bin` `3,134 B` SHA-256 `FF2D0A83990DC94160627A8E061C8EC54F9EB07BECA3AC93F5C036ADD3DF820B`, `hw_recon.yuv` `147,456 B` SHA-256 `AE739FE1EDA914849D180F309A0B55B00AEC85B04619B49270DFBFAC0ADB049E`, `hw_recon_pre.yuv` `24F92B0B464255389E3D23DD6E87508798A4CCE8F3074E9088D482936192BA78`, `max_diff = 0` across all 73,728 samples)**.

---

## AMD Zynq UltraScale+ Synthesis Metrics (`xczu19eg-ffvb1517-2-e`)

Out-of-context synthesis executed with `SYNTHESIS=1` under a `5.555 ns` (`180 MHz`) clock constraint on top-level `hevc_encoder_axi_top` ([`synth/vivado_output/`](file:///d:/UIT_Doc/hevc_hw_encoder/synth/vivado_output)):

| Resource Type | Initial Baseline | v2.0 Sign-Off (`50 MHz`) | v3.0 (`150 MHz`) | **v4.0 Final (`180 MHz`)** | Available | Final Utilization % | Net Reduction vs. Baseline |
|---|---:|---:|---:|---:|---:|---|---|
| **CLB LUTs** | 448,916 | 226,544 | 237,476 | **243,266** | 522,720 | **46.54%** | **-205,650 LUTs (-45.81%)** |
| *-- Logic LUTs* | 441,925 | 218,785 | 229,718 | **237,812** | 522,720 | **45.50%** | **-204,113 LUTs (-46.19%)** |
| *-- Memory LUTs (LUTRAM + SRL)* | 6,991 | 7,759 | 7,758 | **5,454** | 161,280 | **3.38%** | 5,424 LUTRAM + 30 SRL |
| **CLB Registers (FF)** | 344,030 | 140,046 | 163,801 | **169,846** | 1,045,440 | **16.25%** | **-174,184 FFs (-50.63%)** |
| **Register as Latch (`LDCE`)** | 0 | 0 | 0 | **0** | 1,045,440 | **0.00%** | 0 unintended latches |
| **Unique Control Sets** | 14,641 | 7,679 | 9,158 | **8,840** | 130,680 | **6.76%** | **-5,801 sets (-39.62%)** |
| **Block RAM** | 12.5 Tiles | 41.5 Tiles | 60.0 Tiles | **49 RAMB36 + 22 RAMB18** | 984 Tiles | **6.10%** | **60.0 Tiles** (CTU ping-pong, `ref_search_cache`, `ctu_bin_ram_0/1`) |
| *-- RAMB36/FIFO* | 11 | 33 | 49 | **49** | 984 | **4.98%** | +38 `RAMB36E2` |
| *-- RAMB18* | 3 | 17 | 22 | **22** | 1,968 | **1.12%** | +19 `RAMB18E2` |
| **DSP48E2 Slices** | 920 | 63 | 63 | **54** | 1,968 | **2.74%** | **-866 DSPs (-94.13%)** |
| **Estimated $F_{\max}$** | 96.36 MHz | 103.73 MHz | 157.51 MHz | **188.50 MHz** | 180.00 MHz | **MET (+0.250 ns)** | **TNS: 0.000 ns** (0 / 452,482 failing), WPWS: +2.235 ns |
| **Total On-Chip Power** | 2.910 W | 2.199 W | 4.158 W | **5.031 W** | — | — | **Dynamic: 3.892 W**, Device Static: 1.139 W (`29.1 °C`) |
| **Methodology `LUTAR-1` & `8-614`** | 1 Advisory | 0 Warnings | 0 Warnings | **0 Warnings** | — | **0 Latches** | Synchronous `core_rst_n_reg` & clean `address_generator` sensitivity |

---

## Rate-Distortion & Multi-QP Conformance

Evaluated on **Foreman 128x128 10-bit** (`v4.0` default 3-frame sign-off run: POC 0 I-Slice QP 29 `39.024 dB Y / 39.549 dB YUV`, POC 1 P-Slice QP 26 `39.343 dB Y / 40.168 dB YUV`, POC 2 B-Slice QP 26 `39.438 dB Y / 40.227 dB YUV`; 3-frame average `PSNR-Y = 39.268 dB`, `PSNR-U = 41.866 dB`, `PSNR-V = 42.373 dB`, **`PSNR-YUV = 39.981 dB`**) and refreshed **4-QP sweep** ($QP \in \{22, 27, 32, 37\}$, [qp_sweep_results.json](file:///d:/UIT_Doc/hevc_hw_encoder/qp_sweep_results.json)) on the finalized `v4.0` RTL vs. Fraunhofer HM 18.0 software anchor:

| Operating Point | HM 18.0 Rate (kbps) | HM 18.0 PSNR-Y (dB) | HW Encoder Rate (kbps) | HW Encoder PSNR-Y (dB) | $\Delta$ PSNR (dB) | Sample Exactness | Max Diff | Conformance |
|---|---|---|---|---|---|---|---|---|
| **QP = 22** | 186.56 | 42.83 | **419.92** | **42.33** | -0.50 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |
| **QP = 27** | 103.84 | 39.65 | **249.44** | **39.22** | -0.43 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |
| **QP = 32** | 64.00 | 36.58 | **165.68** | **37.41** | +0.83 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |
| **QP = 37** | 38.40 | 33.62 | **115.20** | **34.77** | +1.15 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |

- **Bjøntegaard Delta Rate (BD-Rate):** **+145.52%** (`+145.519%`, refreshed `v4.0` sweep in `qp_sweep_results.json`; reflects single-pass fixed-hardware RDO trade-off against floating-point multi-pass software search).
- **Bjøntegaard Delta PSNR (BD-PSNR):** **-5.02 dB** (`-5.0248 dB`; average quality delta across equivalent bitrates against reference software anchor).
- **Bit-Exact Conformance:** **100.00% across all 4 QPs** (`max_diff == 0` on all 73,728 samples per QP; `5,249 B / 3,118 B / 2,071 B / 1,440 B`).
- Rate-distortion curves are visualized in [rd_curve.svg](file:///d:/UIT_Doc/hevc_hw_encoder/rd_curve.svg) (source metrics in [qp_sweep_results.json](file:///d:/UIT_Doc/hevc_hw_encoder/qp_sweep_results.json)).

---

## Key Hardware Modules

### 1. Prediction & Motion Estimation
- **Intra Prediction (`rtl/intra/`):**
  - **Rough Mode Decision (`rtl/intra/intra_rmd.v` + `rtl/common/hadamard_satd_4x4.v`):** Evaluates **4 Luma modes** (`Planar = 0`, `DC = 1`, `Hor = 10`, `Ver = 26`) via **4x4-tiled Hadamard SATD** (split-stage `signed [12:0]`/`signed [14:0]` butterflies, `wr_bank`/`rd_bank` ping-pong double-buffered 16-sample residual banks, and Stage-1 `row_t` start-edge latch) across full `4x4`, `8x8`, `16x16`, and `32x32` CU/PU sizes, plus normative **5-candidate Chroma Intra RDO** (`Planar`, `Ver = 26`, `Hor = 10`, `DC`, `DM_CHROMA`) per ITU-T H.265 Table 8-2 and sequential 1-pixel/cycle reference loading (`T3-14`) with $4\times4$ Chroma MDCS scan (`Clause 7.4.9.11`).
  - **Final Intra Prediction Reconstruction (`rtl/intra/intra_pred_top.v`, `rtl/intra/intra_angular.v`):** Supports all 35 Luma prediction modes (Planar, DC, and 33 Angular directions) for residual generation, with the `hevc_encoder_top.v` Chroma `above-right` reference fetch bit-5 truncation fix (`abs_top_x_raw` / `rmd_abs_top_x_c_raw`).
- **Inter Prediction (`rtl/inter/`):**
  - **Integer Motion Estimation (IME) & Search Cache (`ref_search_cache.v`):** Hardware-optimized Test Zone Search (TZ-Search) backed by a **`128x128` on-chip Luma search-window cache (`4 RAMB36 + 1 RAMB18`)**, cutting Frame 2 inter CTU `T_MD` spikes (`30,830 -> 6,403` avg).
  - **Fractional Motion Estimation (FME):** Half-pel and quarter-pel interpolation filters (8-tap luma, 4-tap chroma).
  - **Motion Compensation & TDP DPB (`mc_window_fetch.v`, `subpel_interpolation_core.v`):** True Dual-Port (TDP) 2-sample/cycle DPB reads (Port-A muxed between pipelined writeback `dpb_wr_*_d1` and `mc_window_fetch` + Read-Only Port-B) with `rd_hold` collision stall, `0D/1D` fast fetch, drain-to-emit write-through bypass, and vertical `row0_win` reuse.
  - Pipelined reference sample buffering and motion vector predictor (MVP) merge evaluation (`FAST_EARLY_CU_SPLIT = 0` default in `mode_decision.v` with depth-0 64×64 bit-exact bypass).

### 2. Transform & Quantization Engine
- **2D Transform (`rtl/transform/`):**
  - Synthesizable 1D core implementing DCT-II (4x4, 8x8, 16x16, 32x32) and 4x4 DST-VII (`dct_top.v`; unit-verified in `tb_flaw_dst7`, while in the 3-frame Foreman top-level run CUs split to 8x8 minimum so Luma `tu_size_log2=2` count is `0`), paired with **zero-CBF Luma IDCT bypass**, **2-bank `pred_sram`** Inter TU prefetch overlap, and a 4-cycle end-of-slice flush.
  - 2D transform realized via dual-port matrix transposition RAM (`transpose_ram_32x32.v`).
  - *Encoder subset:* residual quadtree (RQT) depth is fixed at 0, so TU size = CU size. CU quadtree splitting still gives 8×8 to 32×32 TUs. Partitioning is PART_2Nx2N only (see T3-11/T3-12 in [`docs/H265_CONFORMANCE_MATRIX.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/H265_CONFORMANCE_MATRIX.md)).
- **Quantization (`rtl/quant/`):**
  - Dual-lane configurable QP forward quantization (`u_fwd_quant_0/1` of `fwd_quant.v`) with sign-magnitude handling (`T_TQ = 11,220` avg cycles/CTU).
  - Paired dual-lane inverse quantization (`u_inv_quant_0/1` of `inv_quant.v`) with ITU-T Table 8-10 Chroma QP mapping and even/odd banked `coeff_buffer.v` for the reconstruction loop.

### 3. Reconstruction & In-Loop Filters
- **Deblocking Filter (`rtl/inloop_filters/`):**
  - Boundary strength (`boundary_strength.v` `bs_comb`/`qp_avg_comb`) and 1-cycle `Bs == 0` fast-skip in `deblock_top.v` with grid-stepped traversal (`+2`/`+4`), pipelined 1-sample/cycle `S_PIX_LOAD` (`db_pix_rd_ready`), 2-stage pipelined `db_filter_luma.v` (`180 MHz` timing closure), and unmodified write-back skip (`T_DB = 6,951` cycles/CTU).
  - Dual-bank CTU Ping-Pong in [`decoder_inloop_filters.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/top/decoder_inloop_filters.v) + output skid buffer + inline fused `S_SAO`/`S_DUMP` + decoupled-flush AXI4 [`frame_store.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/recon/frame_store.v) (**`Stall_Inloop = 0`** across all 12 CTUs).
- **Sample Adaptive Offset (SAO):**
  - Inline fused Band Offset (BO) and Edge Offset (EO) classification datapaths (`0°, 90°, 135°, 45°`) inside `decoder_inloop_filters.v` with EO row+1 lookahead, latched neighbor BO offset forwarding, and 3-plane parallel (`Y / Cb / Cr`) 32-band BO + last-CTU EO RDO in [`sao_stats.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/inloop_filters/sao_stats.v) (`T3-13`).

### 4. CABAC Arithmetic Entropy Encoder & Synthesis Hygiene
- **Split FE/BE CABAC & 2-Bank CTU-Delayed Bitstream Serialization (`rtl/entropy/cabac_enc_top.v`):**
  - Dual-bank synchronous Block RAM bin queue (`ctu_bin_ram_0` & `ctu_bin_ram_1`, `2x 8192 x 10-bit`, `4 RAMB36E2 + 2 RAMB18E2`), 2-entry `be_skid_mem` backpressure decoupling, even/odd banked **4-bank `coeff_buffer.v` (`DEPTH=4096`)**, and **4-entry `cu_fifo` / `tu_meta_fifo`** decouple front-end `cabac_state` from back-end `cabac_be_state` (`Stall_CABAC = 0` across all 12 CTUs, `T_CABAC = 35,094`), while preserving normative `sao(rx, ry)`-first ordering (`Clause 7.3.8.2`).
- **Binary Arithmetic Range Coder (`rtl/entropy/range_coder.v`):**
  - Fully pipelined renormalization engine emitting standard-compliant byte streams with 16-bit carry-propagation protection.
- **Context Modeling (`rtl/entropy/ctx_model_store.v`):**
  - **186** CABAC context models (`0..185`) initialized in **186 cycles** per slice type (I/P/B).
- **Syntax Generators (`rtl/entropy/syntax_*.v`):**
  - Hardware binarization for CU modes, split flags, transform tree, SAO offsets (`cMax=31`), and quantized residual coefficients (`syntax_coeff.v`) with per-CU `tu_cg_nonzero_mask` zero-CG skipping and streaming reverse-order `S_LOAD_CG` (`180 MHz` timing closure).
- **Single-Path Production RTL & Simulation-vs-Synthesis Parity:** `0` `REMEDIATION` directives in `rtl/` and `ip_repo/hevc_encoder_v1_0/src/` (buggy regression baselines isolated in [`tb/flaw_baseline_rtl/`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/flaw_baseline_rtl)) and `0` behavioral `` `ifdef SYNTHESIS `` blocks (`3` 4-state `===` X-safety guards). Gate 1 (`run_sim.do`) and Gate 2 (`tb/run_sim_synthdef.do`, `+define+SYNTHESIS`) on [`tb/tb_full_encoder/tb_b_frame_encoder.v`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/tb_full_encoder/tb_b_frame_encoder.v) finish at `3,458,665 ns` (`345,866.5` cycles) and produce bit-identical `str_b_frame.bin` (`3,134 B`, SHA-256 `FF2D0A83990DC94160627A8E061C8EC54F9EB07BECA3AC93F5C036ADD3DF820B`) and `hw_recon.yuv` (`147,456 B`, SHA-256 `AE739FE1EDA914849D180F309A0B55B00AEC85B04619B49270DFBFAC0ADB049E`) at **`27,785 cycles/CTU` steady-state CTU period** (`1,619.6 / 269.9 / 29.4 / 12.7 fps` @ `180 MHz`, `1,696.1 / 282.7 / 30.8 / 13.3 fps` @ `188.50 MHz`).

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
   - **RTL Finite State Machine (FSM) Reference Suite:** [`docs/fsm_reference.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/fsm_reference.md) — master index & inter-FSM flowchart covering [Top & Control](file:///d:/UIT_Doc/hevc_hw_encoder/docs/fsm/top_and_control_fsms.md), [Partition & Mode Decision](file:///d:/UIT_Doc/hevc_hw_encoder/docs/fsm/partition_and_mode_decision_fsms.md), [Intra Prediction](file:///d:/UIT_Doc/hevc_hw_encoder/docs/fsm/intra_prediction_fsms.md), [Inter Prediction](file:///d:/UIT_Doc/hevc_hw_encoder/docs/fsm/inter_prediction_fsms.md), [Transform/Quant/Recon/DPB/RC](file:///d:/UIT_Doc/hevc_hw_encoder/docs/fsm/transform_quant_recon_fsms.md), [In-Loop Filters](file:///d:/UIT_Doc/hevc_hw_encoder/docs/fsm/inloop_filters_fsms.md), and [Entropy & NAL](file:///d:/UIT_Doc/hevc_hw_encoder/docs/fsm/entropy_and_nal_fsms.md)
   - **IC Design & Remediation Case Studies:** [`docs/CASE_STUDIES.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/CASE_STUDIES.md) and [`docs/WALKTHROUGH.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/WALKTHROUGH.md)

