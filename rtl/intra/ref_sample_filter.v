//=============================================================================
// ref_sample_filter.v
// Intra Prediction Reference Sample Filter
//
// Mapped from HM source:
//   TLibCommon/TComPrediction.cpp
//   Void TComPrediction::xFilterReferenceSamples()
//
// HEVC spec: Section 8.4.4.2
//
// Reference sample layout for an N×N PU:
//   Total = 4N+1 samples stored in a flat array ref[0..4N]
//   Index mapping (N=block size):
//     ref[0]        = p[-1][-1]           corner sample
//     ref[1..N]     = p[-1][0..N-1]       top-left → top-right (left col, bottom to top)
//     ref[N+1..2N]  = p[N-1..-1][-1]     bottom-left → top-left (left col, was wrong)
//
//   HM actual layout (TComPrediction.cpp initAdiArrayTopleft):
//     ref[0]          = corner  p[-1][-1]
//     ref[1..2N]      = left column  p[0..-1][2N-1..-1]  (bottom to top, 2N samples)
//                       Wait - let me be precise per HM:
//
//   HM stores reference samples as:
//     pDst[0]         = p[-1][-1]           (top-left corner)
//     pDst[1..2*N]    = p[-1][0..2N-1]      (left column, TOP to BOTTOM — 2N samples)
//                       Actually this is left column bottom to top in some versions...
//
//   Per HEVC spec Table 8-3 and HM TComPrediction.cpp xPredIntraAng:
//   The reference buffer pSrc is indexed as:
//     pSrc[-1]        = corner             p[-1][-1]
//     pSrc[0..N-1]    = top row            p[-1][0..N-1]    (left to right)
//     pSrc[-1..-2N]   = left col           p[-1][0..-2N+1]  (top to bottom negative idx)
//
//   HM uses pointer arithmetic: src = pSrc+1 for top row, negative indices for left
//   Hardware: flatten to linear array:
//     ref_raw[0]        = p[-1][-1]        corner
//     ref_raw[1..2N]    = p[-1][0..2N-1]   top row (left to right, 2N samples)
//     ref_raw[2N+1..4N] = p[0..2N-1][-1]  left col (top to bottom, 2N samples)
//
// Filter (HM xFilterReferenceSamples, 3-tap [1,2,1]/4):
//   pFlt[i] = (pSrc[i-1] + 2*pSrc[i] + pSrc[i+1] + 2) >> 2
//   Boundary: corner and endpoints are left unfiltered or copied
//
// Filter enable rules (HM TComPrediction.cpp):
//   useStrongIntraSmoothing: for 32×32 only, bilinear smooth if DC value far from corners
//   useFilteredSamples: per mode/size lookup table
//     Mode  0 (Planar): filter for N≥8
//     Mode  1 (DC):     NO filter (always use unfiltered)
//     Mode  2..34:      filter based on mode-specific threshold
//
// HM g_aucIntraModeNumAng, g_aucAngIntraModeOrder not needed here —
// filter enable is determined by mode and TU size only.
//
// Pipeline:
//   Input:  4N+1 raw reference samples (one per cycle, serial)
//   Stage 1: Buffer all 4N+1 samples
//   Stage 2: Apply 3-tap filter combinationally
//   Output: 4N+1 filtered samples (one per cycle, serial)
//   Latency: (4N+1) + 1 cycles per block
//   Max N=32: 129 input cycles + filter + 129 output cycles
//=============================================================================

`include "parameter_pkg.vh"

module ref_sample_filter (
    input  wire         clk,
    input  wire         rst_n,

    // PU context
    input  wire [2:0]   pu_size_log2,       // 2=4×4 .. 5=32×32
    input  wire [5:0]   intra_mode,         // 0=Planar,1=DC,2..34=Angular
    input  wire         is_luma,            // 1=luma, 0=chroma

    // Raw reference sample input (serial, ref[0..4N])
    input  wire         in_valid,
    output wire         in_ready,
    input  wire [`PIXEL_WIDTH-1:0] in_sample,  // 10-bit
    input  wire [7:0]   in_idx,             // 0..4N (max 128)
    input  wire         in_last,            // last sample of block

    // Filtered reference sample output (serial, ref[0..4N])
    output reg          out_valid,
    input  wire         out_ready,
    output reg  [`PIXEL_WIDTH-1:0] out_sample,
    output reg  [7:0]   out_idx,
    output reg          out_last
);

    //-------------------------------------------------------------------------
    // Reference sample buffer — max 4×32+1 = 129 samples
    //-------------------------------------------------------------------------
    localparam MAX_REF = 129;   // 4*32 + 1

    reg [`PIXEL_WIDTH-1:0] ref_buf [0:MAX_REF-1];
`ifndef SYNTHESIS
    integer filt_init_i;
    initial begin
        for (filt_init_i = 0; filt_init_i < MAX_REF; filt_init_i = filt_init_i + 1)
            ref_buf[filt_init_i] = 10'd512;
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            for (filt_init_i = 0; filt_init_i < MAX_REF; filt_init_i = filt_init_i + 1)
                ref_buf[filt_init_i] <= 10'd512;
        end
    end
`endif
    reg [7:0]               buf_count;    // how many samples received
    reg                     buf_full;     // all 4N+1 received
    reg                     buf_last;     // in_last seen

    //-------------------------------------------------------------------------
    // PU size decode
    // N = 1 << pu_size_log2
    // ref_count = 4*N + 1
    //-------------------------------------------------------------------------
    wire [6:0] N      = 7'd1 << pu_size_log2;  // 4,8,16,32
    
    wire [7:0] idx_N  = {1'b0, N};
    wire [7:0] idx_2N = {1'b0, N[5:0], 1'b0};
    wire [7:0] idx_3N = idx_2N + idx_N;
    wire [7:0] idx_4N = {N[5:0], 2'b00};

    wire [7:0] ref_count = idx_4N + 8'd1;  // 4N+1

    //-------------------------------------------------------------------------
    // Filter enable decision
    // HM: needFilteredRefSamples() — returns true when filtered refs needed
    //
    // Rules from HM (TComPrediction.cpp):
    //   DC mode (1):      never filter
    //   Chroma:           never filter (luma-only filtering)
    //   Planar (0):       filter if N >= 8
    //   Angular modes:    filter if distance to nearest H/V > threshold
    //     Thresholds (HEVC Table 8-3):
    //       N=4  (log2=2): never filter (threshold=32)
    //       N=8  (log2=3): threshold=7
    //       N=16 (log2=4): threshold=1
    //       N=32 (log2=5): threshold=0
    //-------------------------------------------------------------------------
    wire filter_dc      = 1'b0;   // DC: never filter
    wire filter_planar  = (intra_mode == `INTRA_PLANAR) && is_luma &&
                          (pu_size_log2 >= 3'd3);  // N >= 8

    // Angular filter threshold (HEVC Table 8-3)
    wire [5:0] ang_thresh = (pu_size_log2 == 3'd2) ? 6'd32 : // N=4: never
                            (pu_size_log2 == 3'd3) ? 6'd7 :  // N=8
                            (pu_size_log2 == 3'd4) ? 6'd1 :  // N=16
                            (pu_size_log2 == 3'd5) ? 6'd0 : 6'd32;

    // Distance to nearest Horizontal (10) or Vertical (26)
    wire [5:0] dist_v = (intra_mode >= 6'd26) ? (intra_mode - 6'd26) : (6'd26 - intra_mode);
    wire [5:0] dist_h = (intra_mode >= 6'd10) ? (intra_mode - 6'd10) : (6'd10 - intra_mode);
    wire [5:0] mode_dist = (dist_v < dist_h) ? dist_v : dist_h;

    wire filter_angular = is_luma &&
                          (intra_mode >= `INTRA_ANG_FIRST) &&
                          (intra_mode <= `INTRA_ANG_LAST) &&
                          (mode_dist > ang_thresh);

    wire use_filter = filter_planar || filter_angular;

    //-------------------------------------------------------------------------
    // Strong intra smoothing (HM: 32×32 luma only)
    // HEVC Spec 8.4.4.2.3:
    // When abs(end + corner - 2*mid) < threshold for both top and left edges:
    //   use bilinear interpolation instead of [1,2,1] filter
    // threshold = 1 << (BIT_DEPTH - 5) = 1 << 5 = 32 for 10-bit
    //-------------------------------------------------------------------------
    localparam STRONG_THRESH = (1 << (`BIT_DEPTH - 5));   // 32

    wire is_strong_cand = is_luma && (pu_size_log2 == 3'd5);  // 32×32 only

    // These are computed after buffer is full
    wire [`PIXEL_WIDTH-1:0] corner    = ref_buf[0];
    wire [`PIXEL_WIDTH-1:0] top_mid   = ref_buf[idx_N];
    wire [`PIXEL_WIDTH-1:0] top_right = ref_buf[idx_2N];     // ref[2N] — top-right
    wire [`PIXEL_WIDTH-1:0] left_mid  = ref_buf[idx_3N];
    wire [`PIXEL_WIDTH-1:0] bot_left  = ref_buf[idx_4N];     // ref[4N] — bottom-left

    // HEVC linearity check: abs(end + corner - 2*mid) < thresh
    wire signed [12:0] strong_top_diff = $signed({2'b0, top_right}) + $signed({2'b0, corner}) - $signed({1'b0, top_mid, 1'b0});
    wire [11:0] abs_strong_top = (strong_top_diff < 0) ? -strong_top_diff[11:0] : strong_top_diff[11:0];

    wire signed [12:0] strong_left_diff = $signed({2'b0, bot_left}) + $signed({2'b0, corner}) - $signed({1'b0, left_mid, 1'b0});
    wire [11:0] abs_strong_left = (strong_left_diff < 0) ? -strong_left_diff[11:0] : strong_left_diff[11:0];
    // Strong intra smoothing: enabled when linearity thresholds are met
    wire use_strong = is_strong_cand && (abs_strong_top < STRONG_THRESH) && (abs_strong_left < STRONG_THRESH);

    //-------------------------------------------------------------------------
    // Input buffer fill FSM
    //-------------------------------------------------------------------------
    wire fire_in = in_valid && in_ready;
    assign in_ready = !buf_full && (out_ready || !out_valid);

    always @(posedge clk) begin
        if (!rst_n) begin
            buf_count <= 8'd0;
            buf_full  <= 1'b0;
            buf_last  <= 1'b0;
        end else if (fire_in) begin
            ref_buf[in_idx] <= in_sample;
            buf_count       <= buf_count + 8'd1;
            buf_last        <= in_last;
            if (in_last || buf_count == ref_count - 8'd1)
                buf_full <= 1'b1;
        end else if (out_last && out_valid && out_ready) begin
            // Reset after full output
            buf_full  <= 1'b0;
            buf_count <= 8'd0;
            buf_last  <= 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // Filter computation — combinational from ref_buf
    // For each position i in 1..4N-1:
    //   pFlt[i] = (ref_buf[i-1] + 2*ref_buf[i] + ref_buf[i+1] + 2) >> 2
    // Boundaries:
    //   pFlt[0]   = ref_buf[0]        (corner: unfiltered)
    //   pFlt[4N]  = ref_buf[4N]       (endpoint: unfiltered)
    //
    // Strong bilinear (32×32 only):
    //   top row: ref_flt[i] = corner + i*(top_right - corner) / 2N  for i=1..2N
    //   left col: ref_flt[i] = corner + (i-2N)*(bot_left-corner)/2N for i=2N+1..4N
    //   Implemented as sequential divides (N is power of 2)
    //-------------------------------------------------------------------------

    // Output FSM
    reg [7:0] out_ptr;
    reg       flushing;

    // Proper neighbor indexing for the flattened 1D array
    //   ref[0] = corner
    //   ref[1..2N] = top row
    //   ref[2N+1..4N] = left col
    wire [7:0] idx_prev = 
        (out_ptr == 8'd0)             ? 8'd1 :
        (out_ptr == idx_2N + 8'd1)    ? 8'd0 : // left col start -> corner
        (out_ptr - 8'd1);

    wire [7:0] idx_next =
        (out_ptr == 8'd0)             ? idx_2N + 8'd1 : // corner -> left col start
        (out_ptr == idx_2N)           ? out_ptr : // top end -> self
        (out_ptr == idx_4N)           ? out_ptr : // left end -> self
        (out_ptr + 8'd1);

    // 3-tap filter for position out_ptr
    wire [11:0] flt_mid   = {2'b0, ref_buf[out_ptr]};
    wire [11:0] flt_prev  = {2'b0, ref_buf[idx_prev]};
    wire [11:0] flt_next  = {2'b0, ref_buf[idx_next]};

    // [1,2,1]/4 filter with +2 rounding (HM)
    wire [11:0] flt_sum   = flt_prev + {flt_mid[10:0], 1'b0} + flt_next + 12'd2;
    wire [`PIXEL_WIDTH-1:0] flt_out = flt_sum[11:2];  // >> 2

    // Strong bilinear for 32×32
    // top row: ref[i] for i=1..64: ( (64-i)*corner + i*top_right + 32 ) >> 6
    wire signed [10:0] delta_top  = $signed({1'b0, top_right}) - $signed({1'b0, corner});
    wire signed [10:0] delta_left = $signed({1'b0, bot_left})  - $signed({1'b0, corner});

    // Bilinear for top row (out_ptr = 1..2N = 1..64)
    wire [7:0]  top_step  = out_ptr;          // i for top row
    wire signed [17:0] bilin_top_full = $signed({7'b0, corner}) +
                         ((delta_top * $signed({1'b0, top_step}) + 18'sd32) >>> 6);
    wire [`PIXEL_WIDTH-1:0] bilin_top = bilin_top_full[`PIXEL_WIDTH-1:0];

    // Bilinear for left col (out_ptr = 2N+1..4N = 65..128)
    wire [7:0]  left_step = out_ptr - idx_2N; // i - 2N
    wire signed [17:0] bilin_left_full = $signed({7'b0, corner}) +
                         ((delta_left * $signed({1'b0, left_step}) + 18'sd32) >>> 6);
    wire [`PIXEL_WIDTH-1:0] bilin_left = bilin_left_full[`PIXEL_WIDTH-1:0];

    wire in_top_row  = (out_ptr >= 8'd1) && (out_ptr <= idx_2N);
    wire in_left_col = (out_ptr > idx_2N);

    wire [`PIXEL_WIDTH-1:0] strong_out = in_top_row  ? bilin_top  :
                                          in_left_col ? bilin_left :
                                          ref_buf[0];  // corner unfiltered for strong

    // Final output mux
    wire is_boundary_pos = (out_ptr == idx_2N) ||
                           (out_ptr == idx_4N);

    wire [`PIXEL_WIDTH-1:0] final_out =
        !use_filter     ? ref_buf[out_ptr] :    // unfiltered (DC or mode-based)
        use_strong      ? strong_out        :    // 32×32 bilinear
        is_boundary_pos ? ref_buf[out_ptr] :    // boundary: always unfiltered
        flt_out;                                 // standard [1,2,1]/4

    //-------------------------------------------------------------------------
    // Output FSM — streams filtered samples after buffer is full
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_ptr   <= 8'd0;
            flushing  <= 1'b0;
            out_sample<= {`PIXEL_WIDTH{1'b0}};
            out_idx   <= 8'd0;
            out_last  <= 1'b0;
        end else begin
            if (out_valid && out_ready) begin
                out_valid <= 1'b0;
            end

            if (!flushing && buf_full && !out_last) begin
                // Start output
                flushing  <= 1'b1;
                out_ptr   <= 8'd0;

            end else if (flushing && (out_ready || !out_valid)) begin
                out_valid  <= 1'b1;
                out_sample <= final_out;
                out_idx    <= out_ptr;
                out_last   <= (out_ptr == ref_count - 8'd1);

                if (out_ptr == ref_count - 8'd1) begin
                    flushing  <= 1'b0;
                end else begin
                    out_ptr   <= out_ptr + 8'd1;
                end
            end

            if (out_last && out_valid && out_ready) begin
                out_last <= 1'b0;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Simulation checks
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && in_valid && !in_ready)
            $display("WARN  [ref_sample_filter] stall mode=%0d size=%0d time=%0t",
                     intra_mode, pu_size_log2, $time);
    end
    // synthesis translate_on

endmodule