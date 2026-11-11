# High-Performance Synthesizable HEVC/H.265 Main10 Hardware Video Encoder

An RTL implementation of a high-throughput, pipelined **HEVC (ITU-T H.265 / ISO/IEC 23008-2)** video compression hardware encoder designed in synthesizable **Verilog / SystemVerilog**. The architecture accelerates the full encoding loop from raw video inputs to standard-compliant NAL bitstreams, targeting modern FPGA and ASIC architectures.

---

## Conformance & Performance Scorecard

- **Bit-Exact Conformance:** **100.00% sample-by-sample match (`max_diff == 0`)** across all frames ($Y, Cb, Cr$) against Fraunhofer **HM 18.0** reference decoder across multi-QP sweeps ($QP \in \{22, 27, 32, 37\}$).
- **Entropy Coding Conformance:** Standard-compliant CABAC bitstream output verified symbol-by-symbol (**29,383 / 29,383 bins, 100.00% bit-exact** across POC 0: 8,844, POC 1: 9,908, POC 2: 10,631 with CTU-delayed dynamic `EO`/`BO`/`OFF` SAO and Rate Control enabled) against the normative HM decoder without a single syntax desynchronization.
- **Physical Synthesis Convergence & Timing Closure:** Fully synthesized in **AMD Vivado 2026.1 Enterprise** on **Zynq UltraScale+ `xczu19eg-ffvb1517-2-e`** with complete timing closure (**WNS = +10.121 ns, Fmax = 101.22 MHz @ 50 MHz target**, 0 failing endpoints out of 348,790, **0 `LUTAR-1` warnings**, and **0 unintended latches**).
- **PPA Optimization:** Area optimized to **223,429 LUTs (42.74%)** (-225,487 LUTs / -50.23% vs. initial baseline), **126,387 FFs (12.09%)** (-217,643 FFs / -63.26% vs. initial baseline), **33 RAMB36 + 17 RAMB18 Blocks (41.5 BRAM Tiles)**, and **61 DSPs (3.10%)** (-859 DSPs / -93.37% vs. initial baseline), with total on-chip power at **2.077 W** (**0.963 W** Dynamic, **1.114 W** Static).
- **Regression & IP Parity Suite:** **100% Convergence** across all **14 / 14** dual-state algorithmic flaw testbenches (`scripts/run_all_flaw_tb.py`), **9 / 9** AXI4-Lite/AXI4 SoC integration tests (`tb/tb_axi_top.sv`), **Full 3-Frame Post-Filter Conformance (`max_diff = 0` across all 73,728 samples in Frames 0, 1, and 2)** via `regression_gate.py`, and **63 / 63** SHA-256 synchronized IP-XACT source files (`ip_repo/hevc_encoder_v1_0/src/`).

---

## AMD Zynq UltraScale+ Synthesis Metrics (`xczu19eg-ffvb1517-2-e`)

Out-of-context synthesis executed with `SYNTHESIS=1 REMEDIATION=1` on top-level `hevc_encoder_axi_top`:

| Resource Type | Initial Baseline | Phase 2 Optimized | Sign-Off Final | Available | Final Utilization % | Net Reduction vs. Baseline |
|---|---:|---:|---:|---:|---|---|
| **CLB LUTs** | 448,916 | 225,933 | **223,429** | 522,720 | **42.74%** | **-225,487 LUTs (-50.23%)** |
| *-- Logic LUTs* | 441,925 | 218,942 | **215,670** | 522,720 | **41.26%** | **-226,255 LUTs (-51.20%)** |
| *-- Memory LUTs (LUTRAM + SRL)* | 6,991 | 6,991 | **7,759** | 161,280 | **4.81%** | 7,728 LUTRAM + 31 SRL |
| **CLB Registers (FF)** | 344,030 | 249,980 | **126,387** | 1,045,440 | **12.09%** | **-217,643 FFs (-63.26%)** |
| **Register as Latch (`LDCE`)** | 0 | 0 | **0** | 1,045,440 | **0.00%** | 0 unintended latches |
| **Unique Control Sets** | 14,641 | 10,733 | **7,414** | 130,680 | **5.67%** | **-7,227 sets (-49.36%)** |
| **Block RAM** | 12.5 Tiles | 30.0 Tiles | **33 RAMB36 + 17 RAMB18** | 984 Tiles | **4.22%** | **+29.0 BRAM Tiles (41.5 Tiles)** |
| *-- RAMB36/FIFO* | 11 | 27 | **33** | 984 | **3.35%** | +22 `RAMB36E2` |
| *-- RAMB18* | 3 | 6 | **17** | 1968 | **0.86%** | +14 `RAMB18E2` |
| **DSP48E2 Slices** | 920 | 209 | **61** | 1,968 | **3.10%** | **-859 DSPs (-93.37%)** |
| **Estimated $F_{\max}$** | 96.36 MHz | 105.33 MHz | **101.22 MHz** | 50.00 MHz | **2.02× margin** | **WNS: +10.121 ns (MET)**, TNS: 0.000 ns (0 / 348,790 failing) |
| **Total On-Chip Power** | 2.910 W | 1.943 W | **2.077 W** | — | — | **Dynamic: 0.963 W**, Device Static: 1.114 W |
| **Methodology `LUTAR-1`** | 1 Advisory | 1 Advisory | **0 Advisories** | — | **0 Warnings** | Synchronous reset register `core_rst_n_reg` |

---

## Rate-Distortion & Multi-QP Conformance

Evaluated on **Foreman 128x128 10-bit** (3 frames: POC 0 I-Slice, POC 1 P-Slice, POC 2 B-Slice) vs. Fraunhofer HM 18.0 software anchor:

| Operating Point | HM 18.0 Rate (kbps) | HM 18.0 PSNR-Y (dB) | HW Encoder Rate (kbps) | HW Encoder PSNR-Y (dB) | $\Delta$ PSNR (dB) | Sample Exactness | Max Diff | Conformance |
|---|---|---|---|---|---|---|---|---|
| **QP = 22** | 186.56 | 42.83 | **413.04** | **42.19** | -0.63 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |
| **QP = 27** | 103.84 | 39.65 | **244.80** | **39.17** | -0.48 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |
| **QP = 32** | 64.00 | 36.58 | **160.64** | **37.50** | +0.92 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |
| **QP = 37** | 38.40 | 33.62 | **106.72** | **34.76** | +1.14 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |

- **Bjøntegaard Delta Rate (BD-Rate):** **+138.34%** (Reflects single-pass fixed-hardware RDO trade-off against floating-point multi-pass software search).
- **Bjøntegaard Delta PSNR (BD-PSNR):** **-4.70 dB** (Average quality delta across equivalent bitrates against reference software anchor).
- **Bit-Exact Conformance:** **100.00% across all 4 QPs** (`max_diff == 0` on all 73,728 samples).
- Rate-distortion curves are visualized in [rd_curve.svg](file:///d:/UIT_Doc/hevc_hw_encoder/rd_curve.svg).

---

## Key Hardware Modules

### 1. Prediction & Motion Estimation
- **Intra Prediction (`rtl/intra/`):**
  - **Rough Mode Decision (RMD):** 35 Luma prediction modes (Planar, DC, and 33 Angular directions) plus normative 5-candidate Chroma Intra RDO search (`Planar, Vertical, Horizontal, DC, DM_CHROMA`) per ITU-T H.265 Table 8-2 with sequential 1-pixel/cycle reference loading (`T3-14`).
  - Parallel SATD (Sum of Absolute Transformed Differences) calculation across 4x4 to 32x32 block sizes and synchronized $4\times4$ Chroma MDCS scan (`Clause 7.4.9.11`).
- **Inter Prediction (`rtl/inter/`):**
  - **Integer Motion Estimation (IME):** Hardware-optimized Test Zone Search (TZ-Search) algorithm with diamond and raster search patterns.
  - **Fractional Motion Estimation (FME):** Half-pel and quarter-pel interpolation filters (8-tap luma, 4-tap chroma).
  - Pipelined reference sample buffering and motion vector predictor (MVP) merge evaluation.

### 2. Transform & Quantization Engine
- **2D Transform (`rtl/transform/`):**
  - Synthesizable 1D core implementing DCT-II (4x4, 8x8, 16x16, 32x32) and 4x4 DST-VII.
  - 2D transform realized via dual-port matrix transposition RAM (`transpose_ram_32x32.v`).
  - *Encoder subset:* residual quadtree (RQT) depth is fixed at 0, so TU size = CU size. CU quadtree splitting still gives 8×8 to 32×32 TUs. Partitioning is PART_2Nx2N only (see T3-11/T3-12 in [`docs/H265_CONFORMANCE_MATRIX.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/H265_CONFORMANCE_MATRIX.md)).
- **Quantization (`rtl/quant/`):**
  - Configurable QP forward quantization (`fwd_quant.v`) with sign-magnitude handling.
  - Paired inverse quantization (`inv_quant.v`) with ITU-T Table 8-10 Chroma QP mapping for the reconstruction loop.

### 3. Reconstruction & In-Loop Filters
- **Deblocking Filter (`rtl/inloop_filters/`):**
  - Boundary strength (BS) calculation for luma and chroma edges.
  - Normal and strong filtering paths with threshold adaptivity.
- **Sample Adaptive Offset (SAO):**
  - Band Offset (BO) and Edge Offset (EO) classification datapaths (`0°, 90°, 135°, 45°`) with 2-phase single-port BRAM neighbor read (`S_REQ_PIX -> S_REQ_N1 -> S_WAIT_PIX`), `pre_sao_row_buf` line caching in [`sao_top.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/inloop_filters/sao_top.v), post-deblocked neighbor border updates in [`decoder_inloop_filters.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/top/decoder_inloop_filters.v), and dynamic full-frame multi-mode RDO (`EO`, `BO`, `OFF`, `SINGLE_PASS_CAUSAL_SYNC = 0`) in [`sao_stats.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/inloop_filters/sao_stats.v) (`T3-13`).

### 4. CABAC Arithmetic Entropy Encoder
- **CTU-Delayed Bitstream Serialization (`rtl/entropy/cabac_enc_top.v`):**
  - Synchronous Block RAM bin queue (`ctu_bin_ram`, `8192 x 10-bit`, `2 RAMB36E2 + 1 RAMB18E2`) with 1-cycle lookahead read handshakes buffers `coding_quadtree()` syntax bins during CTU reconstruction so `sao(rx, ry)` is normatively emitted first after `sao_stats` finishes (`Clause 7.3.8.2`).
- **Binary Arithmetic Range Coder (`rtl/entropy/range_coder.v`):**
  - Fully pipelined renormalization engine emitting standard-compliant byte streams with 16-bit carry-propagation protection.
- **Context Modeling (`rtl/entropy/ctx_model_store.v`):**
  - On-chip state and most probable symbol (MPS) tables initialized per slice type (I/P/B).
- **Syntax Generators (`rtl/entropy/syntax_*.v`):**
  - Hardware binarization for CU modes, split flags, transform tree, and quantized residual coefficients.

---

## Verification & Toolflow Execution

1. **Multi-QP Benchmark & Rate-Distortion Sweep:**
   ```bash
   python scripts/run_qp_sweep_and_bd_rate.py
   ```
2. **AMD Vivado Out-of-Context Synthesis & Metrics Extraction:**
   ```bash
   synth\run_vivado.bat synth
   python synth/extract_vivado_results.py
   ```
3. **Packaging Vivado IP Core:**
   ```bash
   synth\run_vivado.bat package
   ```
4. **Detailed Architecture, Flowcharts & Interface Specifications:**
   - **System Datapath & Pipeline:** [`docs/datapath.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/datapath.md)
   - **Top-Level Algorithm Flowchart:** [`docs/algorithmflowchart.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/algorithmflowchart.md)
   - **Top-Level Port Connections & Interfaces:** [`docs/port_connections_hevc_top.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/port_connections_hevc_top.md)
   - **Major Subsystems ("Bif Modules") Flowcharts:** [`docs/bif_modules_flowcharts.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/bif_modules_flowcharts.md)
   - **CABAC Entropy Coding Subsystem:** [`docs/CABAC.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/CABAC.md)
   - **TU Quadtree, Transform & Quantization:** [`docs/TUQuadtree,Transform&Quantization_flowchart.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/TUQuadtree,Transform&Quantization_flowchart.md)
   - **IC Design & Remediation Case Studies:** [`docs/CASE_STUDIES.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/CASE_STUDIES.md) and [`docs/WALKTHROUGH.md`](file:///d:/UIT_Doc/hevc_hw_encoder/docs/WALKTHROUGH.md)

