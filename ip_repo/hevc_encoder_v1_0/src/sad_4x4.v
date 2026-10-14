//=============================================================================
// sad_4x4.v
// 4×4 Sum of Absolute Differences (SAD) — Motion Estimation Cost Unit
//
// Mapped from HM source:
//   TLibCommon/TComRdCost.cpp  :: TComRdCost::xGetSAD4()
//   TLibCommon/TComRdCost.h    :: DistParam struct
//
// HM C++ reference (hardware-fixed params: iSubShift=0, iRows=4):
//
//   Distortion TComRdCost::xGetSAD4(DistParam* pcDtParam) {
//     const Pel* piOrg = pcDtParam->pOrg;
//     const Pel* piCur = pcDtParam->pCur;
//     UInt uiSum = 0;
//     for (Int r = 0; r < 4; r++) {               // 4 rows
//       uiSum += abs(piOrg[0]-piCur[0]);           // col 0
//       uiSum += abs(piOrg[1]-piCur[1]);           // col 1
//       uiSum += abs(piOrg[2]-piCur[2]);           // col 2
//       uiSum += abs(piOrg[3]-piCur[3]);           // col 3
//       piOrg += iStrideOrg;
//       piCur += iStrideCur;
//     }
//     return uiSum >> DISTORTION_PRECISION_ADJUSTMENT(bitDepth-8);
//     // DISTORTION_PRECISION_ADJUSTMENT(10-8) = 2  (Main10 profile)
//   }
//
// Hardware mapping decisions:
//   - iSubShift = 0 fixed (full-row computation, no sub-sampling)
//   - iRows     = 4 fixed (4×4 block)
//   - bitDepth  = PIXEL_WIDTH (10 for Main10)
//   - Stride abstraction removed: caller packs block into flat vectors
//   - Three-stage pipeline for timing closure at 250 MHz+
//
// Pixel packing (row-major, LSB = pixel[0][0]):
//   orig_flat[ PIXEL_WIDTH*(4*r + c) +: PIXEL_WIDTH ] = orig[r][c]
//   ref_flat [ PIXEL_WIDTH*(4*r + c) +: PIXEL_WIDTH ] = ref[r][c]
//
// Bit-width analysis (PIXEL_WIDTH=10):
//   abs_diff[i]  : 10-bit  (max = 2^10-1 = 1023)
//   row_sum[r]   : 12-bit  (max = 4 × 1023 = 4092)
//   sad_raw      : 14-bit  (max = 4 × 4092 = 16368)
//   sad_out      : 12-bit  (sad_raw >> 2, max = 4092)
//                           matches HM DISTORTION_PRECISION_ADJUSTMENT
//
// Pipeline stages (PIPELINED=1):
//   Cycle 0  valid_in  →  ABS stage  : 16 absolute differences
//   Cycle 1  s1_valid  →  ROW stage  : 4 partial row sums (4 adders)
//   Cycle 2  s2_valid  →  SUM stage  : 1 final 4-way sum + >>SAD_SHIFT
//   Cycle 3  valid_out →  output registered
//   Latency: 3 clock cycles
//
// PIPELINED=0: purely combinational (valid_out = valid_in, 0-cycle latency)
//=============================================================================

`include "parameter_pkg.vh"

module sad_4x4 #(
    parameter PIXEL_WIDTH  = `PIXEL_WIDTH,       // 10 (Main10)
    parameter PIPELINED    = 1,                  // 1=3-stage pipe, 0=combo

    // Derived — do not override
    parameter SAD_SHIFT    = PIXEL_WIDTH - 8,    // 2 for 10-bit (HM precision adj.)
    parameter DIFF_WIDTH   = PIXEL_WIDTH + 1,    // signed diff: 11-bit
    parameter ABS_WIDTH    = PIXEL_WIDTH,        // abs diff:    10-bit (same range)
    parameter ROW_WIDTH    = ABS_WIDTH + 2,      // row sum of 4: 12-bit
    parameter RAW_WIDTH    = ROW_WIDTH + 2,      // total sum:   14-bit
    parameter SAD_WIDTH    = RAW_WIDTH - SAD_SHIFT // output:    12-bit
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   valid_in,

    // 4×4 original block — packed row-major, 10 bits/pixel, 160 bits total
    input  wire [PIXEL_WIDTH*16-1:0] orig_flat,
    // 4×4 reference block
    input  wire [PIXEL_WIDTH*16-1:0] ref_flat,

    output wire                   valid_out,
    output wire [SAD_WIDTH-1:0]   sad_out       // HM-equivalent distortion value
);

    // =========================================================================
    // Pixel extraction helper (combinational)
    // pixel(flat, row, col) = flat[ PW*(4*r+c) +: PW ]
    // =========================================================================
    genvar r, c;

    // Unpack into 2-D arrays for readability
    wire [PIXEL_WIDTH-1:0] orig [0:3][0:3];
    wire [PIXEL_WIDTH-1:0] reff [0:3][0:3];   // 'ref' is reserved in some tools

    generate
        for (r = 0; r < 4; r = r + 1) begin : unpack_row
            for (c = 0; c < 4; c = c + 1) begin : unpack_col
                assign orig[r][c] = orig_flat[ PIXEL_WIDTH*(4*r+c) +: PIXEL_WIDTH ];
                assign reff[r][c] = ref_flat [ PIXEL_WIDTH*(4*r+c) +: PIXEL_WIDTH ];
            end
        end
    endgenerate

    // =========================================================================
    // STAGE 1 — Absolute Difference
    // HM: uiSum += abs(piOrg[c] - piCur[c])
    // Signed subtraction → abs value
    // =========================================================================
    wire [ABS_WIDTH-1:0] abs_diff_comb [0:3][0:3];
    wire [DIFF_WIDTH-1:0] diff_signed   [0:3][0:3];

    generate
        for (r = 0; r < 4; r = r + 1) begin : abs_row
            for (c = 0; c < 4; c = c + 1) begin : abs_col
                // Sign-extend to DIFF_WIDTH, subtract, take absolute value
                assign diff_signed[r][c] = $signed({1'b0, orig[r][c]})
                                         - $signed({1'b0, reff[r][c]});
                // Absolute value: negate if negative (MSB = sign bit)
                assign abs_diff_comb[r][c] =
                    diff_signed[r][c][DIFF_WIDTH-1]
                        ? (~diff_signed[r][c][ABS_WIDTH-1:0] + 1'b1)
                        :   diff_signed[r][c][ABS_WIDTH-1:0];
            end
        end
    endgenerate

    // Pipeline registers — Stage 1
    reg [ABS_WIDTH-1:0] s1_abs [0:3][0:3];
    reg                 s1_valid;

    generate
        if (PIPELINED) begin : pipe_s1
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    s1_valid <= 1'b0;
                end else begin
                    s1_valid <= valid_in;
                    begin : s1_latch
                        integer i, j;
                        for (i = 0; i < 4; i = i + 1)
                            for (j = 0; j < 4; j = j + 1)
                                s1_abs[i][j] <= abs_diff_comb[i][j];
                    end
                end
            end
        end else begin : combo_s1
            always @(*) begin
                s1_valid = valid_in;
                begin : s1_passthru
                    integer i, j;
                    for (i = 0; i < 4; i = i + 1)
                        for (j = 0; j < 4; j = j + 1)
                            s1_abs[i][j] = abs_diff_comb[i][j];
                end
            end
        end
    endgenerate

    // =========================================================================
    // STAGE 2 — Row Partial Sums
    // HM equivalent: one inner-loop iteration
    //   uiSum += abs[r][0] + abs[r][1] + abs[r][2] + abs[r][3]
    // Each row sum fits in ROW_WIDTH = 12 bits
    // =========================================================================
    wire [ROW_WIDTH-1:0] row_sum_comb [0:3];

    generate
        for (r = 0; r < 4; r = r + 1) begin : row_add
            assign row_sum_comb[r] = ({2'b0, s1_abs[r][0]}
                                    + {2'b0, s1_abs[r][1]})
                                    + ({2'b0, s1_abs[r][2]}
                                    + {2'b0, s1_abs[r][3]});
        end
    endgenerate

    // Pipeline registers — Stage 2
    reg [ROW_WIDTH-1:0] s2_row [0:3];
    reg                 s2_valid;

    generate
        if (PIPELINED) begin : pipe_s2
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    s2_valid <= 1'b0;
                end else begin
                    s2_valid <= s1_valid;
                    begin : s2_latch
                        integer i;
                        for (i = 0; i < 4; i = i + 1)
                            s2_row[i] <= row_sum_comb[i];
                    end
                end
            end
        end else begin : combo_s2
            always @(*) begin
                s2_valid = s1_valid;
                begin : s2_passthru
                    integer i;
                    for (i = 0; i < 4; i = i + 1)
                        s2_row[i] = row_sum_comb[i];
                end
            end
        end
    endgenerate

    // =========================================================================
    // STAGE 3 — Final Accumulation + Precision Shift
    // HM: uiSum << iSubShift  (=0, no-op)
    //     return uiSum >> DISTORTION_PRECISION_ADJUSTMENT(bitDepth-8)
    //                   = uiSum >> 2   (for 10-bit Main10)
    //
    // sad_raw: 14-bit (max 16368)
    // sad_out: 12-bit (sad_raw >> 2, max 4092)
    // =========================================================================
    wire [RAW_WIDTH-1:0] sad_raw_comb;

    assign sad_raw_comb = ({2'b0, s2_row[0]} + {2'b0, s2_row[1]})
                        + ({2'b0, s2_row[2]} + {2'b0, s2_row[3]});

    // Output registers — Stage 3
    reg [SAD_WIDTH-1:0] sad_r;
    reg                 valid_r;

    generate
        if (PIPELINED) begin : pipe_s3
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    valid_r <= 1'b0;
                    sad_r   <= {SAD_WIDTH{1'b0}};
                end else begin
                    valid_r <= s2_valid;
                    // Arithmetic right-shift by SAD_SHIFT (=2 for 10-bit)
                    // sad_raw is always non-negative, so logical == arithmetic
                    sad_r   <= sad_raw_comb[RAW_WIDTH-1:SAD_SHIFT];
                end
            end
        end else begin : combo_s3
            always @(*) begin
                valid_r = s2_valid;
                sad_r   = sad_raw_comb[RAW_WIDTH-1:SAD_SHIFT];
            end
        end
    endgenerate

    assign valid_out = valid_r;
    assign sad_out   = sad_r;

    // =========================================================================
    // Simulation assertions
    // =========================================================================
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && valid_in) begin
            // Sanity: pixels must be in [0, 2^PIXEL_WIDTH - 1] range
            begin : check_range
                integer i, j;
                for (i = 0; i < 4; i = i + 1)
                    for (j = 0; j < 4; j = j + 1) begin
                        if (orig[i][j] > {PIXEL_WIDTH{1'b1}})
                            $display("WARN [sad_4x4] orig[%0d][%0d] = %0d out of range",
                                     i, j, orig[i][j]);
                        if (reff[i][j] > {PIXEL_WIDTH{1'b1}})
                            $display("WARN [sad_4x4] ref[%0d][%0d] = %0d out of range",
                                     i, j, reff[i][j]);
                    end
            end
        end
    end
    // synthesis translate_on

endmodule