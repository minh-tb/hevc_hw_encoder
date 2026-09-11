# High-Performance Synthesizable HEVC/H.265 Hardware Video Encoder

An RTL implementation of a high-throughput, pipelined **HEVC (H.265)** video compression hardware encoder designed in synthesizable **Verilog / SystemVerilog**. The architecture accelerates the full encoding loop from raw video inputs to standard-compliant NAL bitstreams, targeting FPGA and ASIC architectures.

---

## Architecture Overview

`
+---------------------------------------------------------------------------------------+
|                                HEVC Hardware Encoder                                 |
+---------------------------------------------------------------------------------------+
|  [Input CTU] -> [CU/PU Splitter & Partitioner]                                        |
|                       |                                                               |
|        +--------------+--------------+                                                |
|        |                             |                                                |
|  [Intra Prediction]           [Inter Prediction]                                      |
|  - RMD 35 Modes Selection     - TZ-Search Integer ME                                  |
|  - Angular, Planar, DC        - Half-Pel & Quarter-Pel FME                            |
|        |                             |                                                |
|        +--------------+--------------+                                                |
|                       |                                                               |
|             [Mode Decision & RDO]                                                     |
|                       |                                                               |
|            [2D DCT / DST Transform]                                                   |
|            - 4x4, 8x8, 16x16, 32x32 Core + Transpose RAM                              |
|                       |                                                               |
|             [Forward Quantization]                                                    |
|                       |                                                               |
|        +--------------+--------------+                                                |
|        |                             |                                                |
|  [Inverse Quantization]       [CABAC Arithmetic Encoder]                              |
|        |                      - Context Model Store                                   |
|  [Inverse Transform]          - Binary Arithmetic Range Coder                         |
|        |                      - Pipelined Bitstream Packer                            |
|  [Reconstruction Unit]               |                                                |
|        |                       [NAL Unit Writer]                                      |
|  [Deblocking Filter]                 |                                                |
|        |                       [Bitstream Output]                                     |
|  [Sample Adaptive Offset (SAO)]                                                       |
|        |                                                                              |
|  [Reference Frame Store]                                                              |
+---------------------------------------------------------------------------------------+
`

---

## Key Hardware Modules

### 1. Prediction & Motion Estimation
- **Intra Prediction (
tl/intra/):**
  - **Rough Mode Decision (RMD):** 35 prediction modes (Planar, DC, and 33 Angular directions).
  - Parallel SATD (Sum of Absolute Transformed Differences) calculation across \times4$ to \times32$ block sizes.
- **Inter Prediction (
tl/inter/):**
  - **Integer Motion Estimation (IME):** Hardware-optimized Test Zone Search (TZ-Search) algorithm with diamond and raster search patterns.
  - **Fractional Motion Estimation (FME):** Half-pel and quarter-pel interpolation filters (8-tap luma, 4-tap chroma).
  - Pipelined reference sample buffering and motion vector predictor (MVP) merge evaluation.

### 2. Transform & Quantization Engine
- **2D Transform (
tl/transform/):**
  - Synthesizable 1D core implementing DCT-II (\times4$, \times8$, \times16$, \times32$) and \times4$ DST-VII.
  - 2D transform realized via dual-port matrix transposition RAM (	ranspose_ram_32x32.v).
- **Quantization (
tl/quant/):**
  - Configurable QP forward quantization (wd_quant.v) with sign-magnitude handling.
  - Paired inverse quantization (inv_quant.v) for the reconstruction loop.

### 3. Reconstruction & In-Loop Filters
- **Deblocking Filter (
tl/inloop_filters/):**
  - Boundary strength (BS) calculation for luma and chroma edges.
  - Normal and strong filtering paths with threshold adaptivity.
- **Sample Adaptive Offset (SAO):**
  - Band Offset (BO) and Edge Offset (EO) classified over pixel neighborhoods with window buffering.

### 4. CABAC Arithmetic Entropy Encoder
- **Binary Arithmetic Range Coder (
tl/entropy/range_coder.v):**
  - Fully pipelined renormalization engine emitting standard-compliant byte streams.
- **Context Modeling (
tl/entropy/ctx_model_store.v):**
  - On-chip state and most probable symbol (MPS) tables initialized per slice type (I/P/B).
- **Syntax Generators (
tl/entropy/syntax_*.v):**
  - Hardware binarization for CU modes, split flags, transform tree, and quantized residual coefficients.

---

## Repository Structure

`
├── rtl/                        # Synthesizable Verilog / SystemVerilog RTL
│   ├── common/                 # Interfaces, arbiters, FIFOs, and math packages
│   ├── entropy/                # CABAC encoder, range coder, syntax generators
│   ├── inloop_filters/         # Deblocking filter & SAO engine
│   ├── input_output/           # CTU input buffer, NAL parser & writer
│   ├── inter/                  # TZ-Search IME, FME interpolation, MC unit
│   ├── intra/                  # Intra RMD, angular prediction, reference filter
│   ├── partition/              # CTU quadtree partitioner & mode decision
│   ├── quant/                  # Forward & Inverse Quantization
│   ├── rate_control/           # Hardware lambda calculation & rate controller
│   ├── recon/                  # Reconstruction, residual subtraction, frame store
│   ├── top/                    # Top-level encoder and GOP/slice controllers
│   └── transform/              # 1D/2D DCT/DST cores & transpose RAM
├── tb/                         # Self-checking ModelSim / QuestaSim testbenches
├── synth/                      # Quartus / Synopsys synthesis & timing scripts (.tcl, .sdc)
├── scripts/                    # Hardware validation, RD-curve plotting & profiling
├── tonghop/                    # Complete Quartus Prime FPGA compilation project
└── compile.do / run_sim.do     # EDA simulation flow automation
`

---

## Verification & Simulation

The hardware encoder is verified against bit-accurate golden test vectors generated from the Fraunhofer **HM (HEVC Test Model)** reference software:

1. **Unit-Level Testbenches (	b/):** Individual self-checking testbenches for DCT/DST, Quantization, Intra Prediction, Inter Motion Search, Deblocking, SAO, and CABAC.
2. **Top-Level Integration (	b/tb_full_encoder/):** Full frame encoding testbench validating CTU pipeline synchronization and complete bitstream compliance.
3. **Running Simulations:**
   `ash
   # Open QuestaSim / ModelSim and execute:
   vsim -do run_sim.do
   `

---

## Synthesis & Implementation

- **Target FPGA:** Intel / Altera Cyclone IV / Cyclone V / Arria / Stratix.
- **Synthesis:**
  - Open Quartus Prime and load hevc_encoder_top.qpf or 	onghop/doan1.qpf.
  - Alternatively, run the batch synthesis TCL flow:
    `ash
    quartus_sh -t synth/synth_hevc.tcl
    `
