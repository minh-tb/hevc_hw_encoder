# High-Performance Synthesizable HEVC/H.265 Hardware Video Encoder

An RTL implementation of a high-throughput, pipelined **HEVC (H.265)** video compression hardware encoder designed in synthesizable **Verilog / SystemVerilog**. The architecture accelerates the full encoding loop from raw video inputs to standard-compliant NAL bitstreams, targeting FPGA and ASIC architectures.

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
  - Paired inverse quantization (`inv_quant.v`) for the reconstruction loop.

### 3. Reconstruction & In-Loop Filters
- **Deblocking Filter (`rtl/inloop_filters/`):**
  - Boundary strength (BS) calculation for luma and chroma edges.
  - Normal and strong filtering paths with threshold adaptivity.
- **Sample Adaptive Offset (SAO):**
  - Band Offset (BO) and Edge Offset (EO) classified over pixel neighborhoods with window buffering.

### 4. CABAC Arithmetic Entropy Encoder
- **Binary Arithmetic Range Coder (`rtl/entropy/range_coder.v`):**
  - Fully pipelined renormalization engine emitting standard-compliant byte streams.
- **Context Modeling (`rtl/entropy/ctx_model_store.v`):**
  - On-chip state and most probable symbol (MPS) tables initialized per slice type (I/P/B).
- **Syntax Generators (`rtl/entropy/syntax_*.v`):**
  - Hardware binarization for CU modes, split flags, transform tree, and quantized residual coefficients.

---

## Verification & Simulation

The hardware encoder is verified against bit-accurate golden test vectors generated from the Fraunhofer **HM (HEVC Test Model)** reference software:

1. **Unit-Level Testbenches (`tb/`):** Individual self-checking testbenches for DCT/DST, Quantization, Intra Prediction, Inter Motion Search, Deblocking, SAO, and CABAC.
2. **Top-Level Integration (`tb/tb_full_encoder/`):** Full frame encoding testbench validating CTU pipeline synchronization and complete bitstream compliance.
3. **Running Simulations:**
   ```bash
   # Open QuestaSim / ModelSim and execute:
   vsim -do run_sim.do
   ```
