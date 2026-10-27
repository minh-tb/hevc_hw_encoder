# High-Performance Synthesizable HEVC/H.265 Main10 Hardware Video Encoder

An RTL implementation of a high-throughput, pipelined **HEVC (ITU-T H.265 / ISO/IEC 23008-2)** video compression hardware encoder designed in synthesizable **Verilog / SystemVerilog**. The architecture accelerates the full encoding loop from raw video inputs to standard-compliant NAL bitstreams, targeting modern FPGA and ASIC architectures.

---

## Conformance & Performance Scorecard

- **Bit-Exact Conformance:** **100.00% sample-by-sample match (`max_diff == 0`)** across all frames ($Y, Cb, Cr$) against Fraunhofer **HM 18.0** reference decoder across multi-QP sweeps ($QP \in \{22, 27, 32, 37\}$).
- **Entropy Coding Conformance:** Standard-compliant CABAC bitstream output verified symbol-by-symbol against the normative HM decoder without a single syntax desynchronization.
- **Physical Synthesis Convergence & Timing Closure:** Fully synthesized in **AMD Vivado 2026.1 Enterprise** on **Zynq UltraScale+ `xczu19eg-ffvb1517-2-e`** with complete timing closure (**WNS = +10.497 ns, Fmax = 105.23 MHz @ 50 MHz target**, 0 failing endpoints out of 543,058).
- **PPA Optimization:** Area reduced to **225,933 LUTs (43.22%)** (-222,983 LUTs / -49.7% vs. initial baseline), **249,980 FFs (23.91%)**, and **209 DSPs (10.62%)** (-711 DSPs / -77.3% vs. initial baseline), with dynamic power reduced to **0.831 W**.
- **Regression Suite:** **100% Convergence (14/14 passing)** on self-checking unit- and system-level testbenches.

---

## AMD Zynq UltraScale+ Synthesis Metrics (`xczu19eg-ffvb1517-2-e`)

Out-of-context synthesis executed with `SYNTHESIS=1 REMEDIATION=1` on top-level `hevc_encoder_axi_top`:

| Resource Type | Used | Available | Utilization % |
|---|---|---|---|
| **CLB LUTs** | **225,933** | 522,720 | **43.22%** (-222,983 LUTs / -49.7% vs. baseline) |
| *-- Logic LUTs* | 223,550 | 522,720 | 42.77% |
| *-- Memory LUTs (Distributed RAM)* | 2,383 | 212,160 | 1.12% |
| **CLB Registers (FF)** | **249,980** | 1,045,440 | **23.91%** (-94,050 FFs / -27.3% vs. baseline) |
| **Block RAM Tiles** | **30.0** | 984 | **3.05%** |
| *-- RAMB36/FIFO* | 27 | 984 | 2.74% |
| *-- RAMB18* | 6 | 1,968 | 0.30% |
| **DSP48E2 Slices** | **209** | 1,968 | **10.62%** (-711 DSPs / -77.3% vs. baseline) |
| **Estimated $F_{\max}$** | **105.23 MHz** | (Target Period: 20.0 ns, **WNS: +10.497 ns (MET)**, TNS: 0.000 ns, 0 failing endpoints) |
| **Total On-Chip Power** | **1.943 W** | (Dynamic: 0.831 W, Device Static: 1.113 W) |

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

