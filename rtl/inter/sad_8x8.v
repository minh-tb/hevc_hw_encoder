//=============================================================================
// sad_8x8.v
// 8×8 Sum of Absolute Differences — Motion Estimation Cost Unit
//
// Mapped from HM source:
//   TLibCommon/TComRdCost.cpp  :: TComRdCost::xGetSAD8()
//   TLibCommon/TComRdCost.h    :: DistParam struct
//
// HM C++ reference (hardware-fixed: iSubShift=0, iRows=8, bitDepth=10):
//
//   Distortion TComRdCost::xGetSAD8(DistParam* pcDtParam) {
//     const Pel* piOrg = pcDtParam->pOrg;
//     const Pel* piCur = pcDtParam->pCur;
//     UInt uiSum = 0;
//     for (Int r = 0; r < 8; r++) {
//       uiSum += abs(piOrg[0]-piCur[0]);
//       uiSum += abs(piOrg[1]-piCur[1]);
//       ...
//       uiSum += abs(piOrg[7]-piCur[7]);
//       piOrg += iStrideOrg;
//       piCur += iStrideCur;
//     }
//     return uiSum >> DISTORTION_PRECISION_ADJUSTMENT(bitDepth-8); // >>2
//   }
//
// Hardware decomposition:
//   Partition 8×8 into 4 quadrants of 4×4, each handled by sad_4x4:
//
//     orig/ref[0..3][0..3] → sad_4x4 inst Q00 (top-left)
//     orig/ref[0..3][4..7] → sad_4x4 inst Q01 (top-right)
//     orig/ref[4..7][0..3] → sad_4x4 inst Q10 (bottom-left)
//     orig/ref[4..7][4..7] → sad_4x4 inst Q11 (bottom-right)
//
//   To strictly match HM integer precision, the right-shift MUST be
//   performed at the very end. Right-shifts are NOT distributive!
//   We instantiate sad_4x4 with SAD_SHIFT=0 so they output raw sums.
//
// Pixel packing (row-major, LSB = pixel[0][0]):
//   orig_flat[ PIXEL_WIDTH*(8*r + c) +: PIXEL_WIDTH ] = orig[r][c]
//
// Bit-width analysis (PIXEL_WIDTH=10):
//   sad_4x4 output (SAD_4_RAW=14): max 16368 per quadrant
//   raw sum of 4 quadrants (SUM_WIDTH=16): max 65472
//   Shifted SAD_WIDTH=14: max 16368
//
// Pipeline:
//   sad_4x4 latency  = 3 cycles  (PIPELINED=1)
//   Adder stage      = +1 cycle  (registered sum of 4 quadrants)
//   Total latency    = 4 cycles
//
//   valid_in ──[3 cy, sad_4x4 × 4]──► q_valid ──[1 cy, adder]──► valid_out
//=============================================================================

`include "parameter_pkg.vh"

module sad_8x8 #(
    parameter PIXEL_WIDTH = `PIXEL_WIDTH,   // 10 (Main10)

    // Derived
    parameter SAD_SHIFT   = PIXEL_WIDTH - 8,       // 2 for 10-bit
    parameter SAD_4_RAW   = PIXEL_WIDTH + 4,       // 14-bit raw sum per 4x4
    parameter SUM_WIDTH   = SAD_4_RAW + 2,         // 16-bit total raw sum
    parameter SAD_WIDTH   = SUM_WIDTH - SAD_SHIFT  // 14-bit output
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       valid_in,

    // 8×8 original block — packed row-major, 10 bits/pixel, 640 bits total
    input  wire [PIXEL_WIDTH*64-1:0]  orig_flat,
    // 8×8 reference block
    input  wire [PIXEL_WIDTH*64-1:0]  ref_flat,

    output wire                       valid_out,
    output wire [SAD_WIDTH-1:0]       sad_out
);

    // =========================================================================
    // Extract 4×4 quadrant flat vectors from the 8×8 input
    //
    // 8×8 layout (r=row 0..7, c=col 0..7):
    //   Q00: rows 0-3, cols 0-3   Q01: rows 0-3, cols 4-7
    //   Q10: rows 4-7, cols 0-3   Q11: rows 4-7, cols 4-7
    //
    // src pixel: orig_flat[ PW*(8*r + c) +: PW ]
    // dst pixel: qXY_flat [ PW*(4*(r%4) + (c%4)) +: PW ]
    // =========================================================================
    wire [PIXEL_WIDTH*16-1:0] orig_q00, orig_q01, orig_q10, orig_q11;
    wire [PIXEL_WIDTH*16-1:0] ref_q00,  ref_q01,  ref_q10,  ref_q11;

    genvar r, c;
    generate
        for (r = 0; r < 4; r = r + 1) begin : quad_row
            for (c = 0; c < 4; c = c + 1) begin : quad_col
                // Top-left quadrant: block rows 0..3, cols 0..3
                assign orig_q00[PIXEL_WIDTH*(4*r+c) +: PIXEL_WIDTH] =
                    orig_flat[PIXEL_WIDTH*(8*r + c) +: PIXEL_WIDTH];
                assign ref_q00 [PIXEL_WIDTH*(4*r+c) +: PIXEL_WIDTH] =
                    ref_flat [PIXEL_WIDTH*(8*r + c) +: PIXEL_WIDTH];

                // Top-right quadrant: block rows 0..3, cols 4..7
                assign orig_q01[PIXEL_WIDTH*(4*r+c) +: PIXEL_WIDTH] =
                    orig_flat[PIXEL_WIDTH*(8*r + (c+4)) +: PIXEL_WIDTH];
                assign ref_q01 [PIXEL_WIDTH*(4*r+c) +: PIXEL_WIDTH] =
                    ref_flat [PIXEL_WIDTH*(8*r + (c+4)) +: PIXEL_WIDTH];

                // Bottom-left quadrant: block rows 4..7, cols 0..3
                assign orig_q10[PIXEL_WIDTH*(4*r+c) +: PIXEL_WIDTH] =
                    orig_flat[PIXEL_WIDTH*(8*(r+4) + c) +: PIXEL_WIDTH];
                assign ref_q10 [PIXEL_WIDTH*(4*r+c) +: PIXEL_WIDTH] =
                    ref_flat [PIXEL_WIDTH*(8*(r+4) + c) +: PIXEL_WIDTH];

                // Bottom-right quadrant: block rows 4..7, cols 4..7
                assign orig_q11[PIXEL_WIDTH*(4*r+c) +: PIXEL_WIDTH] =
                    orig_flat[PIXEL_WIDTH*(8*(r+4) + (c+4)) +: PIXEL_WIDTH];
                assign ref_q11 [PIXEL_WIDTH*(4*r+c) +: PIXEL_WIDTH] =
                    ref_flat [PIXEL_WIDTH*(8*(r+4) + (c+4)) +: PIXEL_WIDTH];
            end
        end
    endgenerate

    // =========================================================================
    // Four sad_4x4 instances — one per quadrant (all run in parallel)
    // Each has PIPELINED=1 → 3-cycle latency, 12-bit SAD output
    // =========================================================================
    wire                   q_valid_00, q_valid_01, q_valid_10, q_valid_11;
    wire [SAD_4_RAW-1:0]   q_sad_00,   q_sad_01,   q_sad_10,   q_sad_11;

    sad_4x4 #(.PIXEL_WIDTH(PIXEL_WIDTH), .PIPELINED(1), .SAD_SHIFT(0)) u_q00 (
        .clk(clk), .rst_n(rst_n),
        .valid_in (valid_in),
        .orig_flat(orig_q00), .ref_flat(ref_q00),
        .valid_out(q_valid_00), .sad_out(q_sad_00)
    );
    sad_4x4 #(.PIXEL_WIDTH(PIXEL_WIDTH), .PIPELINED(1), .SAD_SHIFT(0)) u_q01 (
        .clk(clk), .rst_n(rst_n),
        .valid_in (valid_in),
        .orig_flat(orig_q01), .ref_flat(ref_q01),
        .valid_out(q_valid_01), .sad_out(q_sad_01)
    );
    sad_4x4 #(.PIXEL_WIDTH(PIXEL_WIDTH), .PIPELINED(1), .SAD_SHIFT(0)) u_q10 (
        .clk(clk), .rst_n(rst_n),
        .valid_in (valid_in),
        .orig_flat(orig_q10), .ref_flat(ref_q10),
        .valid_out(q_valid_10), .sad_out(q_sad_10)
    );
    sad_4x4 #(.PIXEL_WIDTH(PIXEL_WIDTH), .PIPELINED(1), .SAD_SHIFT(0)) u_q11 (
        .clk(clk), .rst_n(rst_n),
        .valid_in (valid_in),
        .orig_flat(orig_q11), .ref_flat(ref_q11),
        .valid_out(q_valid_11), .sad_out(q_sad_11)
    );

    // All four fire together (same valid_in, same latency) — use Q00 as master
    wire q_valid = q_valid_00;

    // =========================================================================
    // Adder stage — sum four 12-bit quadrant SADs into 14-bit total
    // Registered for timing: this is the critical path (4 inputs → 1 adder)
    //
    // Adder tree: (Q00+Q01) + (Q10+Q11) — balanced two-level add
    // =========================================================================
    reg [SAD_WIDTH-1:0] sad_r;
    reg                 valid_r;

    wire [SUM_WIDTH-1:0] raw_sum_comb = ({2'b0, q_sad_00} + {2'b0, q_sad_01})
                                      + ({2'b0, q_sad_10} + {2'b0, q_sad_11});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sad_r   <= {SAD_WIDTH{1'b0}};
            valid_r <= 1'b0;
        end else begin
            valid_r <= q_valid;
            sad_r   <= raw_sum_comb[SUM_WIDTH-1:SAD_SHIFT];
        end
    end

    assign valid_out = valid_r;
    assign sad_out   = sad_r;

    // =========================================================================
    // Simulation assertions
    // =========================================================================
    // synthesis translate_off
    always @(posedge clk) begin : consistency_check
        // All four quadrant valids must be synchronous
        if (q_valid_00 !== q_valid_01 || q_valid_00 !== q_valid_10 ||
            q_valid_00 !== q_valid_11)
            $display("ERROR [sad_8x8] quadrant valid mismatch at t=%0t — check sad_4x4 latency symmetry", $time);
    end
    // synthesis translate_on

endmodule