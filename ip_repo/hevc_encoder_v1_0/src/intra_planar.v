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
    reg [5:0] N_r;
    reg [4:0] shift_r;
    reg [`PIXEL_WIDTH-1:0] refT_N_r;
    reg [`PIXEL_WIDTH-1:0] refL_N_r;

    //-------------------------------------------------------------------------
    // Input buffer FSM
    //-------------------------------------------------------------------------
    assign in_ready = (state == S_REF_BUF);

    wire fire_in = in_valid && in_ready;

    integer i;
`ifndef SYNTHESIS
    integer init_i;
    initial begin
        for (init_i = 0; init_i <= 32; init_i = init_i + 1) begin
            refT[init_i] = {`PIXEL_WIDTH{1'b0}};
            refL[init_i] = {`PIXEL_WIDTH{1'b0}};
        end
    end
`endif
    always @(posedge clk) begin
        if (!rst_n) begin
            state    <= S_REF_BUF;
            N_r      <= 6'd4;
            shift_r  <= 5'd3;
            refT_N_r <= {`PIXEL_WIDTH{1'b0}};
            refL_N_r <= {`PIXEL_WIDTH{1'b0}};
        end else begin
            case (state)
                S_REF_BUF: begin
                    if (fire_in) begin
                        // Top row: ref[1..N+1] -> refT[0..N]
                        if (in_idx >= 8'd1 && in_idx <= N_wide + 8'd1) begin
                            refT[in_idx - 8'd1] <= in_sample;
                        end

                        // Left col: ref[2N+1..3N+1] -> refL[0..N]
                        if (in_idx >= N2_wide + 8'd1 &&
                            in_idx <= N2_wide + N_wide + 8'd1) begin
                            refL[in_idx - N2_wide - 8'd1] <= in_sample;
                        end

                        if (in_last) begin
                            N_r      <= N;
                            shift_r  <= {2'b0, pu_size_log2} + 5'd1;
                            refT_N_r <= refT[N];
                            refL_N_r <= refL[N];
                            state    <= S_COMPUTE;
                        end
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
    // Pixel computation — 2-Stage Lockstep Pipeline (180 MHz Timing Closure)
    //   Stage 1: Read refL[py]/refT[px] and compute 4 products -> s1_*
    //   Stage 2: Sum + round + shift -> out_pixel register
    //-------------------------------------------------------------------------
    reg [5:0] px;
    reg [5:0] py;
    reg       gen_done;

    // Coefficient computation (combinational from px, py, N_r)
    wire [5:0] coef_hor_l  = (N_r - 6'd1 - px);  // N-1-x
    wire [5:0] coef_hor_r  = (px + 6'd1);         // x+1
    wire [5:0] coef_ver_t  = (N_r - 6'd1 - py);  // N-1-y
    wire [5:0] coef_ver_b  = (py + 6'd1);         // y+1

    // Reference samples for current (px, py)
    wire [`PIXEL_WIDTH-1:0] sL_y  = refL[py];       // refL[y]
    wire [`PIXEL_WIDTH-1:0] sT_x  = refT[px];       // refT[x]

    // Four products (16-bit each)
    wire [15:0] prod_hl  = coef_hor_l * sL_y;
    wire [15:0] prod_hr  = coef_hor_r * refT_N_r;
    wire [15:0] prod_vt  = coef_ver_t * sT_x;
    wire [15:0] prod_vb  = coef_ver_b * refL_N_r;

    // Stage 1 -> Stage 2 Pipeline Registers
    reg        s1_valid;
    reg [15:0] s1_prod_hl;
    reg [15:0] s1_prod_hr;
    reg [15:0] s1_prod_vt;
    reg [15:0] s1_prod_vb;
    reg [5:0]  s1_x;
    reg [5:0]  s1_y;
    reg        s1_last;

    // Stage 2: Sum + rounding + shift
    wire [16:0] psum_s2  = s1_prod_hl + s1_prod_hr
                         + s1_prod_vt + s1_prod_vb
                         + {11'b0, N_r};

    wire [`PIXEL_WIDTH-1:0] pred_pixel_s2 = psum_s2 >> shift_r;
    wire pipe_en = out_ready || !out_valid;

    //-------------------------------------------------------------------------
    // Lockstep 2-stage output FSM — raster scan
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid  <= 1'b0;
            out_pixel  <= {`PIXEL_WIDTH{1'b0}};
            out_x      <= 6'd0;
            out_y      <= 6'd0;
            out_last   <= 1'b0;
            px         <= 6'd0;
            py         <= 6'd0;
            gen_done   <= 1'b0;
            s1_valid   <= 1'b0;
            s1_prod_hl <= 16'd0;
            s1_prod_hr <= 16'd0;
            s1_prod_vt <= 16'd0;
            s1_prod_vb <= 16'd0;
            s1_x       <= 6'd0;
            s1_y       <= 6'd0;
            s1_last    <= 1'b0;
        end else if (state == S_COMPUTE) begin
            if (pipe_en) begin
                if (out_last && out_valid) begin
                    out_valid <= 1'b0;
                    out_last  <= 1'b0;
                    s1_valid  <= 1'b0;
                    s1_last   <= 1'b0;
                    gen_done  <= 1'b0;
                    px        <= 6'd0;
                    py        <= 6'd0;
                end else begin
                    // Stage 1: Coordinate advance & 4x multipliers
                    if (!gen_done) begin
                        s1_valid   <= 1'b1;
                        s1_prod_hl <= prod_hl;
                        s1_prod_hr <= prod_hr;
                        s1_prod_vt <= prod_vt;
                        s1_prod_vb <= prod_vb;
                        s1_x       <= px;
                        s1_y       <= py;
                        s1_last    <= (px == N_r - 6'd1) && (py == N_r - 6'd1);

                        if ((px == N_r - 6'd1) && (py == N_r - 6'd1)) begin
                            gen_done <= 1'b1;
                            px       <= 6'd0;
                            py       <= 6'd0;
                        end else if (px == N_r - 6'd1) begin
                            px <= 6'd0;
                            py <= py + 6'd1;
                        end else begin
                            px <= px + 6'd1;
                        end
                    end else begin
                        s1_valid <= 1'b0;
                        s1_last  <= 1'b0;
                    end

                    // Stage 2: Sum + shift -> output
                    out_valid <= s1_valid;
                    out_pixel <= pred_pixel_s2;
                    out_x     <= s1_x;
                    out_y     <= s1_y;
                    out_last  <= s1_valid && s1_last;
                end
            end
        end else begin
            out_valid <= 1'b0;
            out_last  <= 1'b0;
            s1_valid  <= 1'b0;
            s1_last   <= 1'b0;
            gen_done  <= 1'b0;
            px        <= 6'd0;
            py        <= 6'd0;
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