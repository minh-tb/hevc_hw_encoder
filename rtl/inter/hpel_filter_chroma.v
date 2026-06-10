//=============================================================================
// hpel_filter_chroma.v
// 4-tap Chroma Interpolation Filter — H, V, HV positions
//
// Mapped from HM source:
//   TLibCommon/TComInterpolationFilter.cpp :: filter<NTAPS_CHROMA=4>()
//   TLibCommon/TComRom.cpp                 :: g_chromaFilter[frac][tap]
//
// HM chroma filter coefficients (g_chromaFilter, all 8 fractional positions):
//   frac=0: {  0, 64,  0,  0 }  integer-pel
//   frac=1: { -2, 58, 10, -2 }  1/8-pel
//   frac=2: { -4, 54, 16, -2 }  2/8-pel
//   frac=3: { -6, 46, 28, -4 }  3/8-pel
//   frac=4: { -4, 36, 36, -4 }  half-pel  ← THIS MODULE (hpel_filter_chroma)
//   frac=5: { -4, 28, 46, -6 }  5/8-pel
//   frac=6: { -2, 16, 54, -4 }  3/4-pel
//   frac=7: { -2, 10, 58, -2 }  7/8-pel
//
// Half-pel coefficients (frac=4): { -4, 36, 36, -4 }
//   Sum = 64 = 2^IF_FILTER_PREC ✓
//   Symmetric: coeff[0]=coeff[3]=-4, coeff[1]=coeff[2]=36
//
// HM filter formula (isFirst=isLast=true, bitDepth=10):
//   sum = -4×src[-1] + 36×src[0] + 36×src[+1] - 4×src[+2]
//   out = ClipBD( (sum + 32) >> 6,  bitDepth )
//
// Symmetry exploitation (2 pairs instead of 4):
//   p0 = src[-1] + src[+2]   (outer pair, coeff -4)
//   p1 = src[ 0] + src[+1]   (inner pair, coeff +36)
//   sum = 36×p1 - 4×p0
//       = (32+4)×p1 - 4×p0
//       = (p1<<5) + (p1<<2) - (p0<<2)   ← shift-and-add only
//
// Chroma MV relationship (HEVC 4:2:0):
//   chroma_mv = luma_mv / 2 (quarter-pel chroma = half-pel luma)
//   Chroma fractional step = 1/8-pel; frac=4 = half-chroma-pel = half-luma-pel
//
// Border requirement (4-tap, tap offsets -1..+2):
//   BLK_EXT = BLK_SIZE + 3  (1 pixel left border + 2 pixels right border)
//   For 4×4: BLK_EXT = 7  (vs 11 for 8-tap luma)
//
// Architecture — 3-stage pipeline (identical structure to hpel_filter_luma):
//
//   Stage 1: H intermediate h_int[BLK_EXT][BLK_SIZE] + V sum v_sum[BLK][BLK]
//            Computed from ref_ext_flat → registered (s1_hint, s1_vsum)
//
//   Stage 2: H output (normalize s1_hint[row+1][c] → clip) [border offset=1 for 4-tap]
//            HV sum: V-filter applied to s1_hint columns (V-on-H)
//            Pass s1_vsum through
//
//   Stage 3: Output register — normalize v_out (>>6), hv_out (>>12), pack all
//
//   Latency: 3 clock cycles
//
// Bit-width analysis (PIXEL_WIDTH=10):
//   Pixel input    : 10-bit unsigned  [0, 1023]
//   Pair sum (int) : 11-bit unsigned  [0, 2046]
//   H/V int sum    : 18-bit signed    [-8184, +73656] → after clip(>>6): [0,1023]
//   HV pair (hint) : 19-bit signed    [-16368, +147312]
//   HV total sum   : 24-bit signed    [-1178496, +5368704] → after clip(>>12): [0,1023]
//
// Reference layout (ref_ext_flat, row-major):
//   ref_ext[r][c] = ref_ext_flat[ PW*(BLK_EXT*r + c) +: PW ]
//   For BLK_SIZE=4, BLK_EXT=7:
//     Row/col 0   = 1 pixel before block (4-tap left border)
//     Rows/cols 1..4 = block region
//     Rows/cols 5..6 = 2 pixels after block (4-tap right border)
//   Integer-pel block corner at (1, 1) in extended coordinates
//=============================================================================

`include "parameter_pkg.vh"

module hpel_filter_chroma #(
    parameter PIXEL_WIDTH = `PIXEL_WIDTH,         // 10
    parameter BLK_SIZE    = 4,                    // output chroma block (NxN)

    // Derived — do not override
    parameter BLK_EXT     = BLK_SIZE + 3,         //  7: 1 border before + 2 after
    parameter H_INT_W     = PIXEL_WIDTH + 8,      // 18: H intermediate (64× scale)
    parameter HV_SUM_W    = PIXEL_WIDTH + 14      // 24: HV sum (4096× scale)
)(
    input  wire clk,
    input  wire rst_n,
    input  wire valid_in,
    input  wire [2:0] frac_x,
    input  wire [2:0] frac_y,

    // Extended reference block: BLK_EXT × BLK_EXT pixels (7×7 for BLK_SIZE=4)
    // ref_ext[r][c] = ref_ext_flat[ PW*(BLK_EXT*r + c) +: PW ]
    input  wire [PIXEL_WIDTH*BLK_EXT*BLK_EXT - 1 : 0] ref_ext_flat,

    // Three half-pel interpolated output blocks (all valid simultaneously)
    output reg  valid_out,
    output reg  [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE - 1 : 0] h_out_flat,
    output reg  [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE - 1 : 0] v_out_flat,
    output reg  [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE - 1 : 0] hv_out_flat
);

    // =========================================================================
    // Rounding and border constants
    // =========================================================================
    localparam signed [31:0] H_ROUND  = 32;    // rounding for >>6:  2^5 = 64/2
    localparam signed [31:0] HV_ROUND = 2048;  // rounding for >>12: 2^11 = 4096/2
    localparam BLK_BORDER = 1;     // pixels before block in extended ref (4-tap: 1)

    // =========================================================================
    // Reference pixel extractor
    // =========================================================================
    function automatic [PIXEL_WIDTH-1:0] ref_px;
        input [PIXEL_WIDTH*BLK_EXT*BLK_EXT-1:0] flat;
        input integer r, c;
        begin ref_px = flat[PIXEL_WIDTH*(BLK_EXT*r + c) +: PIXEL_WIDTH]; end
    endfunction

    // =========================================================================
    // 4-tap FIR
    // =========================================================================
    function automatic signed [H_INT_W-1:0] fir4;
        input [2:0] frac;
        input [PIXEL_WIDTH-1:0] p0, p1, p2, p3;
        reg signed [H_INT_W-1:0] sum;
        begin
            case (frac)
                3'd1: sum = -2*$signed({1'b0,p0}) + 58*$signed({1'b0,p1}) + 10*$signed({1'b0,p2}) - 2*$signed({1'b0,p3});
                3'd2: sum = -4*$signed({1'b0,p0}) + 54*$signed({1'b0,p1}) + 16*$signed({1'b0,p2}) - 2*$signed({1'b0,p3});
                3'd3: sum = -6*$signed({1'b0,p0}) + 46*$signed({1'b0,p1}) + 28*$signed({1'b0,p2}) - 4*$signed({1'b0,p3});
                3'd4: sum = -4*$signed({1'b0,p0}) + 36*$signed({1'b0,p1}) + 36*$signed({1'b0,p2}) - 4*$signed({1'b0,p3});
                3'd5: sum = -4*$signed({1'b0,p0}) + 28*$signed({1'b0,p1}) + 46*$signed({1'b0,p2}) - 6*$signed({1'b0,p3});
                3'd6: sum = -2*$signed({1'b0,p0}) + 16*$signed({1'b0,p1}) + 54*$signed({1'b0,p2}) - 4*$signed({1'b0,p3});
                3'd7: sum = -2*$signed({1'b0,p0}) + 10*$signed({1'b0,p1}) + 58*$signed({1'b0,p2}) - 2*$signed({1'b0,p3});
                default: sum = 64*$signed({1'b0,p1});
            endcase
            fir4 = sum;
        end
    endfunction

    function automatic signed [HV_SUM_W-1:0] fir4_hint;
        input [2:0] frac;
        input signed [H_INT_W-1:0] p0, p1, p2, p3;
        reg signed [HV_SUM_W-1:0] sum;
        begin
            case (frac)
                3'd1: sum = -2*p0 + 58*p1 + 10*p2 - 2*p3;
                3'd2: sum = -4*p0 + 54*p1 + 16*p2 - 2*p3;
                3'd3: sum = -6*p0 + 46*p1 + 28*p2 - 4*p3;
                3'd4: sum = -4*p0 + 36*p1 + 36*p2 - 4*p3;
                3'd5: sum = -4*p0 + 28*p1 + 46*p2 - 6*p3;
                3'd6: sum = -2*p0 + 16*p1 + 54*p2 - 4*p3;
                3'd7: sum = -2*p0 + 10*p1 + 58*p2 - 2*p3;
                default: sum = 64*p1;
            endcase
            fir4_hint = sum;
        end
    endfunction

    // =========================================================================
    // Clip signed value to [0, 2^PIXEL_WIDTH - 1]
    // =========================================================================
    function automatic [PIXEL_WIDTH-1:0] clip_px;
        input signed [HV_SUM_W-1:0] v;
        begin
            if (v[HV_SUM_W-1]) // MSB check prevents negative wrapping issues
                clip_px = {PIXEL_WIDTH{1'b0}};
            else if (v > $signed({{(HV_SUM_W-PIXEL_WIDTH){1'b0}}, {PIXEL_WIDTH{1'b1}}}))
                clip_px = {PIXEL_WIDTH{1'b1}};
            else
                clip_px = v[PIXEL_WIDTH-1:0];
        end
    endfunction

    // =========================================================================
    // STAGE 1 — H intermediate + V sum on integer pixels
    //
    // h_int[r][c] (r=0..BLK_EXT-1, c=0..BLK_SIZE-1):
    //   4-tap H filter at row r, output column c
    //   Taps: ref_ext[r][c+0], ref_ext[r][c+1], ref_ext[r][c+2], ref_ext[r][c+3]
    //   (offset: col c maps to ref_ext col c, inner pair at c+1..c+2)
    //   Pairs: p0=ref[c+0]+ref[c+3], p1=ref[c+1]+ref[c+2]
    //
    // v_sum[rb][cb] (rb=0..BLK_SIZE-1, cb=0..BLK_SIZE-1):
    //   4-tap V filter on integer pixels at col cb+BLK_BORDER, rows rb..rb+3
    //   Taps: ref_ext[rb+0][cb+1], ..., ref_ext[rb+3][cb+1]
    //   Pairs: p0=ref[rb+0]+ref[rb+3], p1=ref[rb+1]+ref[rb+2]
    // =========================================================================
    reg signed [H_INT_W-1:0]  s1_hint [0:BLK_EXT-1][0:BLK_SIZE-1];
    reg signed [H_INT_W-1:0]  s1_vsum [0:BLK_SIZE-1][0:BLK_SIZE-1];
    reg                        s1_valid;
    reg [2:0]                  s1_frac_y;

    integer i, j;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            s1_frac_y <= 3'd0;
        end else begin
            s1_valid <= valid_in;
            s1_frac_y <= frac_y;

            // ---- H intermediate: all BLK_EXT rows ----
            for (i = 0; i < BLK_EXT; i = i + 1) begin
                for (j = 0; j < BLK_SIZE; j = j + 1) begin
                    begin : s1_h
                        s1_hint[i][j] <= fir4(frac_x,
                            ref_px(ref_ext_flat, i, j+0),
                            ref_px(ref_ext_flat, i, j+1),
                            ref_px(ref_ext_flat, i, j+2),
                            ref_px(ref_ext_flat, i, j+3)
                        );
                    end
                end
            end

            // ---- V sum on integer pixels ----
            for (i = 0; i < BLK_SIZE; i = i + 1) begin
                for (j = 0; j < BLK_SIZE; j = j + 1) begin
                    begin : s1_v
                        s1_vsum[i][j] <= fir4(frac_y,
                            ref_px(ref_ext_flat, i+0, j+BLK_BORDER),
                            ref_px(ref_ext_flat, i+1, j+BLK_BORDER),
                            ref_px(ref_ext_flat, i+2, j+BLK_BORDER),
                            ref_px(ref_ext_flat, i+3, j+BLK_BORDER)
                        );
                    end
                end
            end
        end
    end

    // =========================================================================
    // STAGE 2 — Normalize H output, compute HV sums, pass V sum
    //
    // H output: normalize s1_hint[rb + BLK_BORDER][cb] → (hint + 32) >> 6, clip
    //   BLK_BORDER=1 because the block's first row is at row 1 in extended coords
    //
    // HV sum: 4-tap V filter applied to s1_hint column cb, rows rb..rb+3
    //   same tap indexing as integer V sum, but on H-intermediates
    //
    // V sum: pass-through for Stage 3 normalization
    // =========================================================================
    reg [PIXEL_WIDTH-1:0]      s2_hout  [0:BLK_SIZE-1][0:BLK_SIZE-1];
    reg signed [HV_SUM_W-1:0]  s2_hvsum [0:BLK_SIZE-1][0:BLK_SIZE-1];
    reg signed [H_INT_W-1:0]   s2_vsum  [0:BLK_SIZE-1][0:BLK_SIZE-1];
    reg                         s2_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
        end else begin
            s2_valid <= s1_valid;

            for (i = 0; i < BLK_SIZE; i = i + 1) begin
                for (j = 0; j < BLK_SIZE; j = j + 1) begin

                    // ---- H output: normalize h_int at block row i+BLK_BORDER ----
                    begin : s2_h
                        reg signed [HV_SUM_W-1:0] sh;
                        sh = (s1_hint[i + BLK_BORDER][j] + H_ROUND) >>> 6;
                        s2_hout[i][j] <= clip_px(sh);
                    end

                    // ---- HV sum: 4-tap V on H-intermediates ----
                    begin : s2_hv
                        s2_hvsum[i][j] <= fir4_hint(s1_frac_y,
                            s1_hint[i+0][j],
                            s1_hint[i+1][j],
                            s1_hint[i+2][j],
                            s1_hint[i+3][j]
                        );
                    end

                    // Pass-through V sum
                    s2_vsum[i][j] <= s1_vsum[i][j];
                end
            end
        end
    end

    // =========================================================================
    // STAGE 3 — Normalize and pack all three outputs
    // H:  s2_hout  → already normalized, pack directly
    // V:  (s2_vsum  + 32)   >> 6,  clip → v_out_flat
    // HV: (s2_hvsum + 2048) >> 12, clip → hv_out_flat
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out   <= 1'b0;
            h_out_flat  <= {(PIXEL_WIDTH*BLK_SIZE*BLK_SIZE){1'b0}};
            v_out_flat  <= {(PIXEL_WIDTH*BLK_SIZE*BLK_SIZE){1'b0}};
            hv_out_flat <= {(PIXEL_WIDTH*BLK_SIZE*BLK_SIZE){1'b0}};
        end else begin
            valid_out <= s2_valid;

            for (i = 0; i < BLK_SIZE; i = i + 1) begin
                for (j = 0; j < BLK_SIZE; j = j + 1) begin

                    // H: direct pack
                    h_out_flat[PIXEL_WIDTH*(BLK_SIZE*i+j) +: PIXEL_WIDTH]
                        <= s2_hout[i][j];

                    // V: normalize
                    begin : s3_v
                        reg signed [HV_SUM_W-1:0] sv;
                        sv = (s2_vsum[i][j] + H_ROUND) >>> 6;
                        v_out_flat[PIXEL_WIDTH*(BLK_SIZE*i+j) +: PIXEL_WIDTH] <= clip_px(sv);
                    end

                    // HV: normalize
                    begin : s3_hv
                        reg signed [HV_SUM_W-1:0] shv;
                        shv = (s2_hvsum[i][j] + HV_ROUND) >>> 12;
                        hv_out_flat[PIXEL_WIDTH*(BLK_SIZE*i+j) +: PIXEL_WIDTH] <= clip_px(shv);
                    end
                end
            end
        end
    end

    // =========================================================================
    // synthesis translate_off
    always @(posedge clk) begin
        if (valid_in) begin : bound_check
            integer ri, ci;
            for (ri = 0; ri < BLK_EXT; ri = ri + 1)
                for (ci = 0; ci < BLK_EXT; ci = ci + 1)
                    if (ref_px(ref_ext_flat, ri, ci) > {PIXEL_WIDTH{1'b1}})
                        $display("WARN [hpel_chroma] ref[%0d][%0d]=%0d OOR at t=%0t",
                                 ri, ci, ref_px(ref_ext_flat, ri, ci), $time);
        end
    end
    // synthesis translate_on

endmodule