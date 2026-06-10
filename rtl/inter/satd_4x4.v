//=============================================================================
// satd_4x4.v
// 4×4 Sum of Absolute Transformed Differences (SATD) — Hadamard Cost Unit
// Used for fractional-pel ME cost and intra mode pre-screening
//
// Mapped from HM source:
//   TLibCommon/TComRdCost.cpp :: TComRdCost::xCalcHADs4x4()
//   TLibCommon/TComRdCost.cpp :: TComRdCost::xGetHADs()
//
// HM C++ reference (hardware-fixed: iStep=1, iStrideOrg/Cur=stride, 10-bit):
//
//   Int TComRdCost::xCalcHADs4x4(const Pel *piOrg, const Pel *piCur,
//                                 Int iStrideOrg, Int iStrideCur, Int iStep)
//   {
//     Int k, satd=0, diff[16], m[16], d[16];
//
//     Step 0: residual differences
//     for (k=0; k<4; k++) {
//       diff[k*4+0] = piOrg[0] - piCur[0];
//       diff[k*4+1] = piOrg[1] - piCur[1];
//       diff[k*4+2] = piOrg[2] - piCur[2];
//       diff[k*4+3] = piOrg[3] - piCur[3];
//       piOrg += iStrideOrg; piCur += iStrideCur;
//     }
//
//     Step 1: Horizontal butterfly (4-point Walsh-Hadamard per row)
//     Groups: (col0,col3) and (col1,col2)
//     m[0]  = diff[0]  + diff[3];   m[1]  = diff[1]  + diff[2];
//     m[2]  = diff[1]  - diff[2];   m[3]  = diff[0]  - diff[3];
//     m[4]  = diff[4]  + diff[7];   m[5]  = diff[5]  + diff[6];
//     m[6]  = diff[5]  - diff[6];   m[7]  = diff[4]  - diff[7];
//     m[8]  = diff[8]  + diff[11];  m[9]  = diff[9]  + diff[10];
//     m[10] = diff[9]  - diff[10];  m[11] = diff[8]  - diff[11];
//     m[12] = diff[12] + diff[15];  m[13] = diff[13] + diff[14];
//     m[14] = diff[13] - diff[14];  m[15] = diff[12] - diff[15];
//
//     Step 2: Vertical butterfly (4-point WHT per column)
//     Groups: (row0,row3) and (row1,row2)
//     d[0]  = m[0]+m[12]; d[1]  = m[1]+m[13]; d[2]  = m[2]+m[14]; d[3]  = m[3]+m[15];
//     d[4]  = m[4]+m[8];  d[5]  = m[5]+m[9];  d[6]  = m[6]+m[10]; d[7]  = m[7]+m[11];
//     d[8]  = m[4]-m[8];  d[9]  = m[5]-m[9];  d[10] = m[6]-m[10]; d[11] = m[7]-m[11];
//     d[12] = m[0]-m[12]; d[13] = m[1]-m[13]; d[14] = m[2]-m[14]; d[15] = m[3]-m[15];
//
//     Step 3: Sum of absolute values
//     for (k=0; k<16; k++) satd += abs(d[k]);
//
//     satd = ((satd+1) >> 1);   // normalize: undo 1-stage gain (round-half-up)
//     return satd >> DISTORTION_PRECISION_ADJUSTMENT(bitDepth-8); // >>2 for 10-bit
//   }
//
// Hardware mapping — 4-stage pipeline:
//
//   Stage 1 (DIFF+HBUT): residual diff + horizontal butterfly → m[0..15] reg
//   Stage 2 (VBUT):      vertical butterfly                   → d[0..15] reg
//   Stage 3 (ABS+PSUM):  16 abs values + 4 partial row sums  → psum[0..3] reg
//   Stage 4 (SUM+SHIFT): final accumulation + rounding + >>3  → satd_out reg
//   Total latency: 4 clock cycles
//
// Bit-width analysis (PIXEL_WIDTH=10):
//   diff[i]  : 11-bit signed  (range -1023..+1023)
//   m[i]     : 12-bit signed  (range -2046..+2046,  max = 2×1023)
//   d[i]     : 13-bit signed  (range -4092..+4092,  max = 2×2046)
//   |d[i]|   : 12-bit unsigned(range 0..4092)
//   psum     : 14-bit unsigned(range 0..4×4092=16368, per 4-element row)
//   sum_abs  : 16-bit unsigned(range 0..16×4092=65472)
//   rounded  : 15-bit unsigned((sum_abs+1)>>1, max 32736)
//   satd_out : 13-bit unsigned(rounded>>2, max 8184)
//=============================================================================

`include "parameter_pkg.vh"

module satd_4x4 #(
    parameter PIXEL_WIDTH = `PIXEL_WIDTH,   // 10 (Main10)

    // Derived — do not override
    parameter DIFF_W  = PIXEL_WIDTH + 1,    // 11: signed diff
    parameter BUTT_W  = PIXEL_WIDTH + 2,    // 12: after horiz butterfly
    parameter TRAN_W  = PIXEL_WIDTH + 3,    // 13: after vert butterfly
    parameter ABS_W   = PIXEL_WIDTH + 2,    // 12: abs of transformed coeff
    parameter PSUM_W  = PIXEL_WIDTH + 4,    // 14: partial sum of 4 abs vals
    parameter SUM_W   = PIXEL_WIDTH + 6,    // 16: sum of 16 abs vals
    parameter RND_W   = PIXEL_WIDTH + 5,    // 15: after (sum+1)>>1
    parameter SAD_SHIFT = PIXEL_WIDTH - 8,  //  2: HM precision adjustment
    parameter SATD_W  = RND_W - SAD_SHIFT   // 13: final output
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       valid_in,

    // 4×4 original block — packed row-major, 10 bits/pixel (160 bits)
    // orig_flat[PIXEL_WIDTH*(4*r+c) +: PIXEL_WIDTH] = orig[r][c]
    input  wire [PIXEL_WIDTH*16-1:0]  orig_flat,
    // 4×4 reference block (same layout)
    input  wire [PIXEL_WIDTH*16-1:0]  ref_flat,

    output reg                        valid_out,
    output reg  [SATD_W-1:0]          satd_out
);

    // =========================================================================
    // Pixel unpack
    // =========================================================================
    wire [PIXEL_WIDTH-1:0] orig [0:3][0:3];
    wire [PIXEL_WIDTH-1:0] reff [0:3][0:3];
    genvar gr, gc;
    generate
        for (gr = 0; gr < 4; gr = gr + 1) begin : unp_r
            for (gc = 0; gc < 4; gc = gc + 1) begin : unp_c
                assign orig[gr][gc] = orig_flat[PIXEL_WIDTH*(4*gr+gc) +: PIXEL_WIDTH];
                assign reff[gr][gc] = ref_flat [PIXEL_WIDTH*(4*gr+gc) +: PIXEL_WIDTH];
            end
        end
    endgenerate

    // =========================================================================
    // STAGE 1 — Residual Diff + Horizontal Butterfly
    //
    // HM Step 0: diff[r][c] = piOrg[r][c] - piCur[r][c]
    // HM Step 1: horizontal WHT butterfly per row
    //   m[r][0] = diff[r][0] + diff[r][3]   (sum of outer pair)
    //   m[r][1] = diff[r][1] + diff[r][2]   (sum of inner pair)
    //   m[r][2] = diff[r][1] - diff[r][2]   (diff of inner pair)
    //   m[r][3] = diff[r][0] - diff[r][3]   (diff of outer pair)
    //
    // Combined: compute diff and butterfly in same cycle (purely combinational)
    // Register m[] at stage 1 output for timing closure
    // =========================================================================
    wire signed [DIFF_W-1:0] diff_w [0:3][0:3]; // combinational diff
    wire signed [BUTT_W-1:0] m_comb [0:3][0:3]; // horizontal butterfly

    generate
        for (gr = 0; gr < 4; gr = gr + 1) begin : hbut_r
            for (gc = 0; gc < 4; gc = gc + 1) begin : diff_w_assign
                // Sign-extend and subtract: HM piOrg[c] - piCur[c]
                assign diff_w[gr][gc] = $signed({1'b0, orig[gr][gc]})
                                      - $signed({1'b0, reff[gr][gc]});
            end

            // Horizontal butterfly: groups (col0,col3) and (col1,col2)
            // m[r][0] = diff[r][0] + diff[r][3]
            assign m_comb[gr][0] = diff_w[gr][0] + diff_w[gr][3];
            // m[r][1] = diff[r][1] + diff[r][2]
            assign m_comb[gr][1] = diff_w[gr][1] + diff_w[gr][2];
            // m[r][2] = diff[r][1] - diff[r][2]
            assign m_comb[gr][2] = diff_w[gr][1] - diff_w[gr][2];
            // m[r][3] = diff[r][0] - diff[r][3]
            assign m_comb[gr][3] = diff_w[gr][0] - diff_w[gr][3];
        end
    endgenerate

    // Stage 1 registers
    reg signed [BUTT_W-1:0] s1_m [0:3][0:3];
    reg                      s1_valid;

    always @(posedge clk or negedge rst_n) begin : s1_reg
        integer i, j;
        if (!rst_n) begin
            s1_valid <= 1'b0;
            for (i = 0; i < 4; i = i + 1)
                for (j = 0; j < 4; j = j + 1)
                    s1_m[i][j] <= {BUTT_W{1'b0}};
        end else begin
            s1_valid <= valid_in;
            for (i = 0; i < 4; i = i + 1)
                for (j = 0; j < 4; j = j + 1)
                    s1_m[i][j] <= m_comb[i][j];
        end
    end

    // =========================================================================
    // STAGE 2 — Vertical Butterfly
    //
    // HM Step 2: vertical WHT butterfly per column
    //   Groups: (row0,row3) and (row1,row2)
    //
    //   d[0][c]  = m[0][c] + m[3][c]   (sum of outer rows)
    //   d[1][c]  = m[1][c] + m[2][c]   (sum of inner rows)
    //   d[2][c]  = m[1][c] - m[2][c]   (diff of inner rows)
    //   d[3][c]  = m[0][c] - m[3][c]   (diff of outer rows)
    //
    // Note HM d[] flat indexing maps to d[row][col]:
    //   d[0..3]   → d[0][0..3]
    //   d[4..7]   → d[1][0..3]
    //   d[8..11]  → d[2][0..3]
    //   d[12..15] → d[3][0..3]
    // =========================================================================
    wire signed [TRAN_W-1:0] d_comb [0:3][0:3];

    generate
        for (gc = 0; gc < 4; gc = gc + 1) begin : vbut_c
            // Row pair (0,3) — outer
            assign d_comb[0][gc] = s1_m[0][gc] + s1_m[3][gc]; // d[0..3]  in HM
            assign d_comb[3][gc] = s1_m[0][gc] - s1_m[3][gc]; // d[12..15] in HM
            // Row pair (1,2) — inner
            assign d_comb[1][gc] = s1_m[1][gc] + s1_m[2][gc]; // d[4..7]  in HM
            assign d_comb[2][gc] = s1_m[1][gc] - s1_m[2][gc]; // d[8..11] in HM
        end
    endgenerate

    // Stage 2 registers
    reg signed [TRAN_W-1:0] s2_d [0:3][0:3];
    reg                      s2_valid;

    always @(posedge clk or negedge rst_n) begin : s2_reg
        integer i, j;
        if (!rst_n) begin
            s2_valid <= 1'b0;
            for (i = 0; i < 4; i = i + 1)
                for (j = 0; j < 4; j = j + 1)
                    s2_d[i][j] <= {TRAN_W{1'b0}};
        end else begin
            s2_valid <= s1_valid;
            for (i = 0; i < 4; i = i + 1)
                for (j = 0; j < 4; j = j + 1)
                    s2_d[i][j] <= d_comb[i][j];
        end
    end

    // =========================================================================
    // STAGE 3 — Absolute Value + Partial Row Sums
    //
    // HM Step 3: for (k=0; k<16; k++) satd += abs(d[k])
    // Hardware: compute abs of all 16, then sum per row (4 adders of 4)
    // =========================================================================
    wire [ABS_W-1:0] abs_d [0:3][0:3];
    wire [PSUM_W-1:0] psum_comb [0:3]; // partial sum per row

    generate
        for (gr = 0; gr < 4; gr = gr + 1) begin : abs_row
            for (gc = 0; gc < 4; gc = gc + 1) begin : abs_elem
                // Absolute value of signed TRAN_W-bit number
                // MSB is sign bit; negate if negative
                assign abs_d[gr][gc] = s2_d[gr][gc][TRAN_W-1]
                    ? (~s2_d[gr][gc][ABS_W-1:0] + 1'b1)
                    :   s2_d[gr][gc][ABS_W-1:0];
            end
            // Sum 4 abs values per row (balanced 2-level tree)
            assign psum_comb[gr] = ({2'b0, abs_d[gr][0]} + {2'b0, abs_d[gr][1]})
                                 + ({2'b0, abs_d[gr][2]} + {2'b0, abs_d[gr][3]});
        end
    endgenerate

    // Stage 3 registers
    reg [PSUM_W-1:0] s3_psum [0:3];
    reg               s3_valid;

    always @(posedge clk or negedge rst_n) begin : s3_reg
        integer i;
        if (!rst_n) begin
            s3_valid <= 1'b0;
            for (i = 0; i < 4; i = i + 1)
                s3_psum[i] <= {PSUM_W{1'b0}};
        end else begin
            s3_valid <= s2_valid;
            for (i = 0; i < 4; i = i + 1)
                s3_psum[i] <= psum_comb[i];
        end
    end

    // =========================================================================
    // STAGE 4 — Final Sum + HM Normalization + Precision Adjustment
    //
    // HM:   satd = ((satd+1) >> 1)        rounding normalize (undo 1-stage gain)
    //       return satd >> 2              DISTORTION_PRECISION_ADJUSTMENT(10-8)
    //
    // Combined: satd_out = ((sum_abs + 1) >> 1) >> SAD_SHIFT
    //                    = (sum_abs + 1) >> (1 + SAD_SHIFT)
    //                    = (sum_abs + 1) >> 3    for 10-bit
    //
    // sum_abs : 16-bit (max 65472)
    // +1      : 16-bit (max 65473 — no overflow, 2^16=65536)
    // >>3     : 13-bit (max 8184)  ← SATD_W = RND_W - SAD_SHIFT = 15-2 = 13
    // =========================================================================
    wire [SUM_W-1:0]  sum_abs;
    wire [SUM_W-1:0]  sum_rounded; // sum_abs + 1 before shift
    wire [SATD_W-1:0] satd_comb;

    assign sum_abs     = ({2'b0, s3_psum[0]} + {2'b0, s3_psum[1]})
                       + ({2'b0, s3_psum[2]} + {2'b0, s3_psum[3]});

    assign sum_rounded = sum_abs + {{(SUM_W-1){1'b0}}, 1'b1}; // +1 for rounding

    // Combined >>1 and >>SAD_SHIFT = >>3 for Main10
    assign satd_comb   = sum_rounded[SUM_W-1 : 1 + SAD_SHIFT];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            satd_out  <= {SATD_W{1'b0}};
        end else begin
            valid_out <= s3_valid;
            satd_out  <= satd_comb;
        end
    end

    // =========================================================================
    // Simulation assertions
    // =========================================================================
    // synthesis translate_off
    always @(posedge clk) begin
        if (s3_valid) begin
            if (sum_abs > 16'd65472)
                $display("WARN [satd_4x4] sum_abs=%0d exceeds theoretical max 65472",
                         sum_abs);
        end
    end
    // synthesis translate_on

endmodule