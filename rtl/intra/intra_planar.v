//=============================================================================
// intra_planar.v
// Intra Planar Prediction
//
// Mapped from HM source:
//   TLibCommon/TComPrediction.cpp
//   Void TComPrediction::xPredIntraPlanar()
//
// HEVC spec: Section 8.4.4.2.4 (Planar prediction)
//
// Algorithm (HM xPredIntraPlanar):
//   For each pixel (x, y) in N×N block:
//     hor = (N-1-x)*left[y] + (x+1)*topRight + N/2  >> log2(N)
//           where topRight = ref[N+1] (top-right corner = ref_top[N])
//           Wait -- in HM: topRight = pSrc[nTbS] (last top row sample)
//                          bottomLeft = pSrc[-nTbS] (last left col sample)
//
//   HM exact formula:
//     pred[x][y] = ( (N-1-x)*refL[y] + (x+1)*refT[N]
//                  + (N-1-y)*refT[x] + (y+1)*refL[N]
//                  + N ) >> (log2(N)+1)
//   where:
//     refT[x]  = top row reference samples,  x=0..N   (N+1 values)
//     refL[y]  = left col reference samples, y=0..N   (N+1 values)
//     refT[N]  = top-right corner (one beyond last top sample)
//     refL[N]  = bottom-left corner (one beyond last left sample)
//     N        = block size (4,8,16,32)
//
// Reference sample indexing (from ref_sample_filter output):
//   ref[0]        = corner p[-1][-1]    — NOT used in planar
//   ref[1..N]     = refT[0..N-1]        — top row first N samples
//   ref[N+1]      = refT[N]             — top-right extra sample
//   ref[2N+1..3N] = refL[0..N-1]        — left col first N samples
//   ref[3N+1]     = refL[N]             — bottom-left extra sample
//
// Rounding: add N before right-shifting by (log2N+1)
//   This is a round-half-up: N = 2^log2N = (1 << (log2N+1)) >> 1
//
// Bit width analysis:
//   (N-1-x) + (x+1) = N. So the horizontal sum is at most N*1023.
//   (N-1-y) + (y+1) = N. So the vertical sum is at most N*1023.
//   Sum of 4 terms + N: max = 2*N*1023 + N = 64*1023 + 32 = 65504 → 16-bit
//   After >>6 (N=32): max = 1023 → fits exactly in PIXEL_WIDTH=10
//
// Pipeline:
//   Stage 1: Buffer top-row (N+1) and left-col (N+1) reference samples
//   Total latency: (4N+1) buffer + 2 + N² output cycles
//
// Multiplier strategy:
//   Coefficients range 0..N (max 32) — 6-bit
//   Reference samples 0..1023 — 10-bit
//   Product: 16-bit — fits in DSP48 slice
//=============================================================================

`include "parameter_pkg.vh"

module intra_planar (
    input  wire         clk,
    input  wire         rst_n,

    // PU context
    input  wire [2:0]   pu_size_log2,   // 2=4×4 .. 5=32×32

    // Reference samples from ref_sample_filter (serial, ref[0..4N])
    input  wire         in_valid,
    output wire         in_ready,
    input  wire [`PIXEL_WIDTH-1:0] in_sample,
    input  wire [7:0]   in_idx,
    input  wire         in_last,

    // Predicted pixel output (row-major, N×N)
    output reg          out_valid,
    input  wire         out_ready,
    output reg  [`PIXEL_WIDTH-1:0] out_pixel,
    output reg  [5:0]   out_x,
    output reg  [5:0]   out_y,
    output reg          out_last
);

    //-------------------------------------------------------------------------
    // PU size decode
    //-------------------------------------------------------------------------
    wire [5:0] N       = 6'd1 << pu_size_log2;     // 4,8,16,32
    wire [7:0] N_wide  = {2'b0, N};                 // zero-extended for indexing
    wire [7:0] N2_wide = {1'b0, N, 1'b0};           // 2N

    //-------------------------------------------------------------------------
    // Reference sample buffers
    // refT[0..N]: top row + top-right corner (N+1 samples)
    // refL[0..N]: left col + bottom-left corner (N+1 samples)
    //-------------------------------------------------------------------------
    reg [`PIXEL_WIDTH-1:0] refT [0:32];  // max N+1 = 33
    reg [`PIXEL_WIDTH-1:0] refL [0:32];

    //-------------------------------------------------------------------------
    // State machine
    //-------------------------------------------------------------------------
    localparam S_REF_BUF = 2'd0;
    localparam S_COMPUTE = 2'd1;

    reg [1:0] state;

    //-------------------------------------------------------------------------
    // Input buffer FSM
    // ref[1..N+1]   → refT[0..N]   (top row + top-right)
    // ref[2N+1..3N+1] → refL[0..N]  (left col + bottom-left)
    //
    // HM pSrc pointer layout:
    //   pSrc[0..nTbS]   = top row left-to-right (N+1 values including top-right)
    //   pSrc[-1..-nTbS] = left col top-to-bottom (N values)
    //   pSrc[-nTbS-1]   = bottom-left
    //
    // Mapped to ref_buf flat indexing:
    //   refT[i] = ref_buf[i+1]         for i=0..N
    //   refL[i] = ref_buf[2N+1+i]      for i=0..N
    //-------------------------------------------------------------------------
    assign in_ready = (state == S_REF_BUF);

    wire fire_in = in_valid && in_ready;

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_REF_BUF;
            for (i = 0; i <= 32; i = i + 1) begin
                refT[i] <= {`PIXEL_WIDTH{1'b0}};
                refL[i] <= {`PIXEL_WIDTH{1'b0}};
            end
        end else begin
            case (state)
                S_REF_BUF: begin
                    if (fire_in) begin
                        // Top row: ref[1..N+1] → refT[0..N]
                        // in_idx 1 to N+1
                        if (in_idx >= 8'd1 && in_idx <= N_wide + 8'd1) begin
                            refT[in_idx - 8'd1] <= in_sample;
                        end

                        // Left col: ref[2N+1..3N+1] → refL[0..N]
                        // in_idx 2N+1 to 3N+1
                        if (in_idx >= N2_wide + 8'd1 &&
                            in_idx <= N2_wide + N_wide + 8'd1) begin
                            refL[in_idx - N2_wide - 8'd1] <= in_sample;
                        end

                        if (in_last) state <= S_COMPUTE;
                    end
                end

                S_COMPUTE: begin
                    if (out_last && out_valid && out_ready)
                        state <= S_REF_BUF;
                end
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // Pixel computation
    //
    // HM formula for pixel (x, y):
    //   pred = ( (N-1-x)*refL[y] + (x+1)*refT[N]
    //          + (N-1-y)*refT[x] + (y+1)*refL[N]
    //          + N ) >> (log2N + 1)
    //
    // Decompose into two horizontal/vertical weighted averages:
    //   hor_val = (N-1-x)*refL[y] + (x+1)*refT[N]
    //   ver_val = (N-1-y)*refT[x] + (y+1)*refL[N]
    //   pred    = (hor_val + ver_val + N) >> (log2N + 1)
    //
    // All multiplications use coefficients ≤ N (max 32, 6-bit)
    // and reference samples ≤ 1023 (10-bit) → 16-bit product
    // 4 products summed: max 4 * 32 * 1023 + 32 = 130976 → 17-bit
    // After >> (log2N+1) max 6: result ≤ 1023 → 10-bit ✓
    //
    // Registered pipeline:
    //   Cycle 0: latch (x,y), read refT[x], refL[y]
    //   Cycle 1: compute 4 products
    //   Cycle 2: sum + round + shift → output
    //   But to keep 1-cycle throughput per pixel, fully unroll combinationally.
    //   Synthesis maps to 4 DSP48 slices per planar unit.
    //-------------------------------------------------------------------------
    reg [5:0] px;
    reg [5:0] py;

    // Coefficient computation (combinational from px, py, N)
    wire [5:0] coef_hor_l  = (N - 6'd1 - px);  // N-1-x
    wire [5:0] coef_hor_r  = (px + 6'd1);       // x+1
    wire [5:0] coef_ver_t  = (N - 6'd1 - py);  // N-1-y
    wire [5:0] coef_ver_b  = (py + 6'd1);       // y+1

    // Reference samples for current (px, py)
    wire [`PIXEL_WIDTH-1:0] sL_y  = refL[py];       // refL[y]
    wire [`PIXEL_WIDTH-1:0] sT_N  = refT[N];        // refT[N] = top-right
    wire [`PIXEL_WIDTH-1:0] sT_x  = refT[px];       // refT[x]
    wire [`PIXEL_WIDTH-1:0] sL_N  = refL[N];        // refL[N] = bottom-left

    // Four products (16-bit each)
    wire [15:0] prod_hl  = coef_hor_l * sL_y;
    wire [15:0] prod_hr  = coef_hor_r * sT_N;
    wire [15:0] prod_vt  = coef_ver_t * sT_x;
    wire [15:0] prod_vb  = coef_ver_b * sL_N;

    // Sum + rounding + shift
    // {11'b0, N} forces Verilog to safely instantiate 17-bit adders to prevent overflow
    wire [16:0] psum  = prod_hl + prod_hr
                      + prod_vt + prod_vb
                      + {11'b0, N};                  // +N for rounding

    wire [4:0]  shift = {2'b0, pu_size_log2} + 5'd1; // log2N + 1

    wire [`PIXEL_WIDTH-1:0] pred_pixel = psum >> shift; // max result = 1023 ✓

    //-------------------------------------------------------------------------
    // Output FSM — raster scan
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_pixel <= {`PIXEL_WIDTH{1'b0}};
            out_x     <= 6'd0;
            out_y     <= 6'd0;
            out_last  <= 1'b0;
            px        <= 6'd0;
            py        <= 6'd0;
        end else if (state == S_COMPUTE) begin
            if (out_ready || !out_valid) begin
                if (out_last && out_valid) begin
                    out_valid <= 1'b0;
                    out_last  <= 1'b0;
                end else begin
                    out_valid <= 1'b1;
                    out_pixel <= pred_pixel;
                    out_x     <= px;
                    out_y     <= py;
                    out_last  <= (px == N - 6'd1) && (py == N - 6'd1);

                    if (px == N - 6'd1) begin
                        px <= 6'd0;
                        py <= py + 6'd1;
                    end else begin
                        px <= px + 6'd1;
                    end

                    if ((px == N - 6'd1) && (py == N - 6'd1)) begin
                        px <= 6'd0;
                        py <= 6'd0;
                    end
                end
            end
        end else begin
            out_valid <= 1'b0;
            px <= 6'd0;
            py <= 6'd0;
        end
    end

    //-------------------------------------------------------------------------
    // Simulation checks
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && state == S_COMPUTE && out_valid && out_last)
            $display("INFO  [intra_planar] block done size=%0d", N);
    end
    // synthesis translate_on

endmodule