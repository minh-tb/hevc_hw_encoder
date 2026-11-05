# High-Performance Synthesizable HEVC/H.265 Main10 Hardware Video Encoder

An RTL implementation of a high-throughput, pipelined **HEVC (ITU-T H.265 / ISO/IEC 23008-2)** video compression hardware encoder designed in synthesizable **Verilog / SystemVerilog**. The architecture accelerates the full encoding loop from raw video inputs to standard-compliant NAL bitstreams, targeting modern FPGA and ASIC architectures.

---

## Conformance & Performance Scorecard

- **Bit-Exact Conformance:** **100.00% sample-by-sample match (`max_diff == 0`)** across all frames ($Y, Cb, Cr$) against Fraunhofer **HM 18.0** reference decoder across multi-QP sweeps ($QP \in \{22, 27, 32, 37\}$).
- **Entropy Coding Conformance:** Standard-compliant CABAC bitstream output verified symbol-by-symbol (**22,691 / 22,691 bins, 100.00% bit-exact** across POC 0: 8,486, POC 1: 7,193, POC 2: 7,012) against the normative HM decoder without a single syntax desynchronization.
- **Physical Synthesis Convergence & Timing Closure:** Fully synthesized in **AMD Vivado 2026.1 Enterprise** on **Zynq UltraScale+ `xczu19eg-ffvb1517-2-e`** with complete timing closure (**WNS = +3.847 ns, Fmax = 61.91 MHz @ 50 MHz target**, 0 failing endpoints out of 325,536, **0 `LUTAR-1` warnings**, and **0 unintended latches**).
- **PPA Optimization:** Area reduced to **187,823 LUTs (35.93%)** (-261,093 LUTs / -58.16% vs. initial baseline), **122,796 FFs (11.75%)** (-221,234 FFs / -64.31% vs. initial baseline), **30 RAMB36 + 13 RAMB18 Blocks**, and **221 DSPs (11.23%)** (-699 DSPs / -75.98% vs. initial baseline), with total on-chip power at **2.015 W** (**0.902 W** Dynamic, **1.113 W** Static).
- **Regression & IP Parity Suite:** **100% Convergence** across all **14 / 14** dual-state algorithmic flaw testbenches (`scripts/run_all_flaw_tb.py`), **9 / 9** AXI4-Lite/AXI4 SoC integration tests (`tb/tb_axi_top.sv`), **Full 3-Frame Post-Filter Conformance (`max_diff = 0` across all 73,728 samples in Frames 0, 1, and 2)** via `regression_gate.py`, and **63 / 63** SHA-256 synchronized IP-XACT source files (`ip_repo/hevc_encoder_v1_0/src/`).

---

## AMD Zynq UltraScale+ Synthesis Metrics (`xczu19eg-ffvb1517-2-e`)

Out-of-context synthesis executed with `SYNTHESIS=1 REMEDIATION=1` on top-level `hevc_encoder_axi_top`:

| Resource Type | Initial Baseline | Phase 2 Optimized | Sign-Off Final | Available | Final Utilization % | Net Reduction vs. Baseline |
|---|---:|---:|---:|---:|---|---|
| **CLB LUTs** | 448,916 | 225,933 | **187,823** | 522,720 | **35.93%** | **-261,093 LUTs (-58.16%)** |
| *-- Logic LUTs* | 441,925 | 218,942 | **181,984** | 522,720 | **34.81%** | **-259,941 LUTs (-58.82%)** |
| *-- Memory LUTs (LUTRAM + SRL)* | 6,991 | 6,991 | **5,839** | 161,280 | **3.62%** | 5,808 LUTRAM + 31 SRL |
| **CLB Registers (FF)** | 344,030 | 249,980 | **122,796** | 1,045,440 | **11.75%** | **-221,234 FFs (-64.31%)** |
| **Register as Latch (`LDCE`)** | 0 | 0 | **0** | 1,045,440 | **0.00%** | 0 unintended latches |
| **Unique Control Sets** | 14,641 | 10,733 | **7,280** | 130,680 | **5.57%** | **-7,361 sets (-50.28%)** |
| **Block RAM** | 12.5 Tiles | 30.0 Tiles | **30 RAMB36 + 13 RAMB18** | 984 Tiles | **3.71%** | **+24.0 BRAM Units** |
| *-- RAMB36/FIFO* | 11 | 27 | **30** | 984 | **3.05%** | +19 `RAMB36E2` |
| *-- RAMB18* | 3 | 6 | **13** | 1,968 | **0.66%** | +10 `RAMB18E2` |
| **DSP48E2 Slices** | 920 | 209 | **221** | 1,968 | **11.23%** | **-699 DSPs (-75.98%)** |
| **Estimated $F_{\max}$** | 96.36 MHz | 105.33 MHz | **61.91 MHz** | 50.00 MHz | **1.24× margin** | **WNS: +3.847 ns (MET)**, TNS: 0.000 ns (0 / 325,536 failing) |
| **Total On-Chip Power** | 2.910 W | 1.943 W | **2.015 W** | — | — | **Dynamic: 0.902 W**, Device Static: 1.113 W |
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
  - **Rough Mode Decision (RMD):** 35 prediction modes (Planar, DC, and 33 Angular directions).
  - Parallel SATD (Sum of Absolute Transformed Differences) calculation across 4x4 to 32x32 block sizes.
- **Inter Prediction (`rtl/inter/`):**
  - **Integer Motion Estimation (IME):** Hardware-optimized Test Zone Search (TZ-Search) algorithm with diamond and raster search patterns.
  - **Fractional Motion Estimation (FME):** Half-pel and quarter-pel interpolation filters (8-tap luma, 4-tap chroma).
  - Pipelined reference sample buffering and motion vector predictor (MVP) merge evaluation.

### 2. Transform & Quantization Engine
- **2D Transform (`rtl/transform/`):**
  - Synthesizable 1D core implementing DCT-II (4x4, 8x8, 16x16, 32x32) and 4x4 DST-VII.
  - 2D transform realized via dual-port matrix transposition RAM (`transpose_ram_32x32.v`).
- **Quantization (`rtl/quant/`):**
  - Configurable QP forward quantization (`fwd_quant.v`) with sign-magnitude handling.
  - Paired inverse quantization (`inv_quant.v`) with ITU-T Table 8-10 Chroma QP mapping for the reconstruction loop.

### 3. Reconstruction & In-Loop Filters
- **Deblocking Filter (`rtl/inloop_filters/`):**
  - Boundary strength (BS) calculation for luma and chroma edges.
  - Normal and strong filtering paths with threshold adaptivity.
- **Sample Adaptive Offset (SAO):**
  - Band Offset (BO) and Edge Offset (EO) classified over pixel neighborhoods with window buffering.

### 4. CABAC Arithmetic Entropy Encoder
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

