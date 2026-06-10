//=============================================================================
// hpel_filter_luma.v
// 8-tap Quarter-Pel Luma Interpolation Filter — generates H, V, HV positions
//
// Mapped from HM source:
//   TLibCommon/TComInterpolationFilter.cpp :: TComInterpolationFilter::filter<N>()
//   TLibCommon/TComInterpolationFilter.h   :: IF_INTERNAL_PREC, IF_FILTER_PREC
//   TLibCommon/TComRom.cpp                 :: g_lumaFilter[frac][tap]
//
// HM half-pel luma filter coefficients (frac=2, g_lumaFilter[2]):
//   { -1, 4, -11, 40, 40, -11, 4, -1 }  — sums to 64 (= 2^IF_FILTER_PREC)
//   Symmetric: coeff[k] == coeff[7-k]
//
// HM filter formula (one output sample, isFirst=isLast=true for H-only pass):
//   sum = Σ g_lumaFilter[2][k] × src[pos + k - 3]  for k = 0..7
//   out = ClipBD( (sum + 32) >> 6,  bitDepth )      // >>IF_FILTER_PREC, +round
//
// For HV (two-pass, HM: isFirst=true then isLast=true):
//   H-pass intermediate (no >>6 yet, stored at 64× scale):
//     h_int = Σ coeff[k] × src_h[r][pos + k - 3]   (signed, unshifted)
//   V-pass on H intermediate:
//     hv_sum = Σ coeff[k] × h_int[pos + k - 3][c]
//     out_hv = ClipBD( (hv_sum + 2048) >> 12,  bitDepth )
//                          >>12 = >>6 H-pass + >>6 V-pass, round = 2^11
//
// Symmetry exploitation (halves multiplier count):
//   p[0..3] = pair sums: p[j] = src[j] + src[7-j]
//   sum = 40×p[3]  - 11×p[2]  + 4×p[1]  - p[0]
//   Implemented as shift-and-add (no multipliers needed):
//     40 = 32+8 = (<<5)+(<<3)
//     11 = 8+2+1 = (<<3)+(<<1)+1
//      4 = (<<2)
//      1 = identity
//
// Architecture — 3-stage pipeline:
//
//   Stage 1: Compute h_int[BLK_EXT][BLK_SIZE] and v_sum[BLK_SIZE][BLK_SIZE]
//            in parallel from ref_ext_flat (all combinational → registered)
//            BLK_EXT = BLK_SIZE+7 rows of H intermediates needed for HV V-pass
//
//   Stage 2: Normalize h_int[row+3] → h_out (H done)
//            Apply V filter on s1_hint → hv_sum[BLK_SIZE][BLK_SIZE]
//            Pass s1_vsum through (registered)
//
//   Stage 3: Normalize v_out from s2_vsum (>>6, clip)
//            Normalize hv_out from s2_hvsum (>>12, clip)
//            Pass h_out through → outputs valid
//
//   Total latency: 3 clock cycles
//
// Bit-width analysis (PIXEL_WIDTH=10):
//   Pixel input   : 10-bit unsigned   [0, 1023]
//   Pair sum      : 11-bit unsigned   [0, 2046]
//   H/V sum (int) : 18-bit signed     [-24552, +90024]  (H_INT_W)
//   HV pair sum   : 19-bit signed     [-49104, +180048]
//   HV total sum  : 25-bit signed     [-4321152, +8511360] (HV_SUM_W)
//   After >>6     : 10-bit + clip     [0, 1023]
//   After >>12    : 10-bit + clip     [0, 1023]
//
// Reference block layout (ref_ext_flat, row-major):
//   ref_ext_flat[PW*(BLK_EXT*r + c) +: PW] = ref_ext[r][c]
//   Origin offset: (3, 3) = first integer-pel sample aligned to block corner
//   Rows  0..2  = 3 pixels above block (filter border)
//   Rows  3..6  = block rows (for BLK_SIZE=4)
//   Rows  7..10 = 4 pixels below block
//   Cols  0..2  = 3 pixels left
//   Cols  3..6  = block cols
//   Cols  7..10 = 4 pixels right
//=============================================================================

`include "parameter_pkg.vh"

module hpel_filter_luma #(
    parameter PIXEL_WIDTH = `PIXEL_WIDTH,         // 10
    parameter BLK_SIZE    = 4,                    // output block (NxN)

    // Derived — do not override
    parameter BLK_EXT     = BLK_SIZE + 7,         // 11: extended reference rows/cols
    parameter H_INT_W     = PIXEL_WIDTH + 8,      // 18: H intermediate (64× pixel scale)
    parameter HV_SUM_W    = PIXEL_WIDTH + 15      // 25: HV sum (4096× scale)
)(
    input  wire clk,
    input  wire rst_n,
    input  wire valid_in,
    input  wire [1:0] frac_x,
    input  wire [1:0] frac_y,

    // Extended reference block: BLK_EXT × BLK_EXT = 11×11 pixels (for BLK_SIZE=4)
    // ref_ext[r][c] = ref_ext_flat[ PW*(BLK_EXT*r + c) +: PW ]
    input  wire [PIXEL_WIDTH*BLK_EXT*BLK_EXT - 1 : 0] ref_ext_flat,

    // Three half-pel output blocks (all computed in parallel, same latency)
    // out[r][c] = out_flat[ PW*(BLK_SIZE*r + c) +: PW ]
    output reg  valid_out,
    output reg  [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE - 1 : 0] h_out_flat,   // H half-pel
    output reg  [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE - 1 : 0] v_out_flat,   // V half-pel
    output reg  [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE - 1 : 0] hv_out_flat   // HV diagonal
);

    // =========================================================================
    // Helper functions
    // =========================================================================

    function automatic signed [H_INT_W-1:0] fir8;
        input [1:0] frac;
        input [PIXEL_WIDTH-1:0] p0, p1, p2, p3, p4, p5, p6, p7;
        reg signed [H_INT_W-1:0] sum;
        begin
            case (frac)
                2'd1: sum = -1*$signed({1'b0,p0}) + 4*$signed({1'b0,p1}) - 10*$signed({1'b0,p2}) + 58*$signed({1'b0,p3}) + 17*$signed({1'b0,p4}) - 5*$signed({1'b0,p5}) + 1*$signed({1'b0,p6});
                2'd2: sum = -1*$signed({1'b0,p0}) + 4*$signed({1'b0,p1}) - 11*$signed({1'b0,p2}) + 40*$signed({1'b0,p3}) + 40*$signed({1'b0,p4}) - 11*$signed({1'b0,p5}) + 4*$signed({1'b0,p6}) - 1*$signed({1'b0,p7});
                2'd3: sum =  1*$signed({1'b0,p1}) - 5*$signed({1'b0,p2}) + 17*$signed({1'b0,p3}) + 58*$signed({1'b0,p4}) - 10*$signed({1'b0,p5}) + 4*$signed({1'b0,p6}) - 1*$signed({1'b0,p7});
                default: sum = 64*$signed({1'b0,p3}); // Should not be reached for integer
            endcase
            fir8 = sum;
        end
    endfunction

    function automatic signed [HV_SUM_W-1:0] fir8_hint;
        input [1:0] frac;
        input signed [H_INT_W-1:0] p0, p1, p2, p3, p4, p5, p6, p7;
        reg signed [HV_SUM_W-1:0] sum;
        begin
            case (frac)
                2'd1: sum = -1*p0 + 4*p1 - 10*p2 + 58*p3 + 17*p4 - 5*p5 + 1*p6;
                2'd2: sum = -1*p0 + 4*p1 - 11*p2 + 40*p3 + 40*p4 - 11*p5 + 4*p6 - 1*p7;
                2'd3: sum =  1*p1 - 5*p2 + 17*p3 + 58*p4 - 10*p5 + 4*p6 - 1*p7;
                default: sum = 64*p3;
            endcase
            fir8_hint = sum;
        end
    endfunction

    // Clip signed value to [0, 2^PIXEL_WIDTH - 1]
    function automatic [PIXEL_WIDTH-1:0] clip_px;
        input signed [HV_SUM_W-1:0] v;
        begin
            if (v[HV_SUM_W-1]) // MSB check natively protects against negative numbers
                clip_px = {PIXEL_WIDTH{1'b0}};
            else if (v > $signed({{(HV_SUM_W-PIXEL_WIDTH){1'b0}}, {PIXEL_WIDTH{1'b1}}}))
                clip_px = {PIXEL_WIDTH{1'b1}};
            else
                clip_px = v[PIXEL_WIDTH-1:0];
        end
    endfunction

    // =========================================================================
    // Reference pixel extraction helper (combinational)
    // =========================================================================
    function automatic [PIXEL_WIDTH-1:0] ref_px;
        input [PIXEL_WIDTH*BLK_EXT*BLK_EXT-1:0] flat;
        input integer r, c;
        begin
            ref_px = flat[PIXEL_WIDTH*(BLK_EXT*r + c) +: PIXEL_WIDTH];
        end
    endfunction

    // =========================================================================
    // STAGE 1 — Horizontal FIR + Vertical FIR on integer pixels
    // Computed combinationally from ref_ext_flat, registered at stage end
    //
    // h_int[r][c]:  H filter applied to row r at output column c
    //               r ∈ [0..BLK_EXT-1], c ∈ [0..BLK_SIZE-1]
    //               Input cols for tap: c, c+1, ..., c+7 within ref_ext
    //
    // v_sum[rb][cb]: V filter applied to column cb+3 (integer pixels)
    //                rb ∈ [0..BLK_SIZE-1], cb ∈ [0..BLK_SIZE-1]
    //                Input rows for tap: rb, rb+1, ..., rb+7 within ref_ext
    // =========================================================================

    // Stage 1 output registers
    reg signed [H_INT_W-1:0]  s1_hint [0:BLK_EXT-1][0:BLK_SIZE-1]; // H intermediate
    reg signed [H_INT_W-1:0]  s1_vsum [0:BLK_SIZE-1][0:BLK_SIZE-1]; // V sum (integers)
    reg                        s1_valid;
    reg [1:0]                  s1_frac_y;

    // Combinational h_int and v_sum computation
    genvar gr, gc;
    integer i, j;

    // Stage 1 register update
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            s1_frac_y <= 2'd0;
        end else begin
            s1_valid <= valid_in;
            s1_frac_y <= frac_y;

            // ---- H intermediate: BLK_EXT rows × BLK_SIZE cols ----
            for (i = 0; i < BLK_EXT; i = i + 1) begin   // row 0..10
                for (j = 0; j < BLK_SIZE; j = j + 1) begin  // out col 0..3
                    // 8 taps: ref_ext[i][j+0..j+7], pairs for symmetry
                    begin : h_compute
                        s1_hint[i][j] <= fir8(frac_x,
                            ref_px(ref_ext_flat, i, j+0),
                            ref_px(ref_ext_flat, i, j+1),
                            ref_px(ref_ext_flat, i, j+2),
                            ref_px(ref_ext_flat, i, j+3),
                            ref_px(ref_ext_flat, i, j+4),
                            ref_px(ref_ext_flat, i, j+5),
                            ref_px(ref_ext_flat, i, j+6),
                            ref_px(ref_ext_flat, i, j+7)
                        );
                    end
                end
            end

            // ---- V sum on integer pixels: BLK_SIZE × BLK_SIZE ----
            for (i = 0; i < BLK_SIZE; i = i + 1) begin   // block row 0..3
                for (j = 0; j < BLK_SIZE; j = j + 1) begin  // block col 0..3
                    // V tap at col j+3, rows i..i+7  (integer pixels)
                    begin : v_compute
                        s1_vsum[i][j] <= fir8(frac_y,
                            ref_px(ref_ext_flat, i+0, j+3),
                            ref_px(ref_ext_flat, i+1, j+3),
                            ref_px(ref_ext_flat, i+2, j+3),
                            ref_px(ref_ext_flat, i+3, j+3),
                            ref_px(ref_ext_flat, i+4, j+3),
                            ref_px(ref_ext_flat, i+5, j+3),
                            ref_px(ref_ext_flat, i+6, j+3),
                            ref_px(ref_ext_flat, i+7, j+3)
                        );
                    end
                end
            end
        end
    end

    // =========================================================================
    // STAGE 2 — Normalize H output, compute HV sums, pass V sum
    //
    // h_out[rb][cb]:  normalize s1_hint[rb+3][cb] → (h_int+32)>>6, clip
    //                 (rows 3..3+BLK_SIZE-1 of h_int = block rows)
    //
    // hv_sum[rb][cb]: V filter applied to s1_hint column cb, rows rb..rb+7
    //                 (V filter on H-intermediate = HV position)
    //
    // s2_vsum: pass-through of s1_vsum for normalization in Stage 3
    // =========================================================================
    reg [PIXEL_WIDTH-1:0]      s2_hout  [0:BLK_SIZE-1][0:BLK_SIZE-1];
    reg signed [HV_SUM_W-1:0]  s2_hvsum [0:BLK_SIZE-1][0:BLK_SIZE-1];
    reg signed [H_INT_W-1:0]   s2_vsum  [0:BLK_SIZE-1][0:BLK_SIZE-1];
    reg                         s2_valid;

    localparam signed [31:0] H_ROUND  = 32;    // rounding for >>6 (H/V normalize): 2^5
    localparam signed [31:0] HV_ROUND = 2048;  // rounding for >>12 (HV normalize): 2^11

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
        end else begin
            s2_valid <= s1_valid;

            for (i = 0; i < BLK_SIZE; i = i + 1) begin
                for (j = 0; j < BLK_SIZE; j = j + 1) begin

                    // ---- H output: normalize h_int at block row i+3 ----
                    // HM: out = ClipBD((h_int + 32) >> 6, bitDepth)
                    begin : h_norm
                        reg signed [HV_SUM_W-1:0] shifted_h;
                        shifted_h = (s1_hint[i+3][j] + H_ROUND) >>> 6;
                        s2_hout[i][j] <= clip_px(shifted_h);
                    end

                    // ---- HV sum: V filter on H intermediates (col j, rows i..i+7) ----
                    // HM: second filter pass on unshifted H intermediate
                    begin : hv_sum_calc
                        s2_hvsum[i][j] <= fir8_hint(s1_frac_y,
                            s1_hint[i+0][j],
                            s1_hint[i+1][j],
                            s1_hint[i+2][j],
                            s1_hint[i+3][j],
                            s1_hint[i+4][j],
                            s1_hint[i+5][j],
                            s1_hint[i+6][j],
                            s1_hint[i+7][j]
                        );
                    end

                    // Pass-through V sum for normalization in Stage 3
                    s2_vsum[i][j] <= s1_vsum[i][j];
                end
            end
        end
    end

    // =========================================================================
    // STAGE 3 — Output register: normalize V and HV, pack all three outputs
    //
    // H output: already normalized (s2_hout), pack into h_out_flat
    // V output: (s2_vsum + 32) >> 6, clip → v_out_flat
    // HV output: (s2_hvsum + 2048) >> 12, clip → hv_out_flat
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out  <= 1'b0;
            h_out_flat  <= {(PIXEL_WIDTH*BLK_SIZE*BLK_SIZE){1'b0}};
            v_out_flat  <= {(PIXEL_WIDTH*BLK_SIZE*BLK_SIZE){1'b0}};
            hv_out_flat <= {(PIXEL_WIDTH*BLK_SIZE*BLK_SIZE){1'b0}};
        end else begin
            valid_out <= s2_valid;

            for (i = 0; i < BLK_SIZE; i = i + 1) begin
                for (j = 0; j < BLK_SIZE; j = j + 1) begin

                    // H output — pass s2_hout directly
                    h_out_flat[PIXEL_WIDTH*(BLK_SIZE*i+j) +: PIXEL_WIDTH]
                        <= s2_hout[i][j];

                    // V output — normalize s2_vsum
                    // HM: ClipBD((v_sum + 32) >> 6, bitDepth)
                    begin : v_norm
                        reg signed [HV_SUM_W-1:0] shifted_v;
                        shifted_v = (s2_vsum[i][j] + H_ROUND) >>> 6;
                        v_out_flat[PIXEL_WIDTH*(BLK_SIZE*i+j) +: PIXEL_WIDTH]
                            <= clip_px(shifted_v);
                    end

                    // HV output — normalize s2_hvsum
                    // HM: ClipBD((hv_sum + 2048) >> 12, bitDepth)
                    begin : hv_norm
                        reg signed [HV_SUM_W-1:0] shifted_hv;
                        shifted_hv = (s2_hvsum[i][j] + HV_ROUND) >>> 12;
                        hv_out_flat[PIXEL_WIDTH*(BLK_SIZE*i+j) +: PIXEL_WIDTH]
                            <= clip_px(shifted_hv);
                    end
                end
            end
        end
    end

    // =========================================================================
    // Simulation checks
    // =========================================================================
    // synthesis translate_off
    always @(posedge clk) begin
        if (valid_in) begin : px_check
            integer ri, ci;
            for (ri = 0; ri < BLK_EXT; ri = ri + 1)
                for (ci = 0; ci < BLK_EXT; ci = ci + 1)
                    if (ref_px(ref_ext_flat, ri, ci) > {PIXEL_WIDTH{1'b1}})
                        $display("WARN [hpel_luma] ref_ext[%0d][%0d]=%0d out of range",
                                 ri, ci, ref_px(ref_ext_flat, ri, ci));
        end
    end
    // synthesis translate_on

endmodule