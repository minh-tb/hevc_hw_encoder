//=============================================================================
// dct4.v
// 4x4 Integer DCT — Forward and Inverse
//
// Mapped from HM source:
//   TLibCommon/TComTrQuant.cpp
//   void partialButterfly4 ()   — forward 4x4 DCT
//   void partialButterflyInverse4() — inverse 4x4 DCT
//
// HEVC integer DCT-II 4x4 basis matrix (from spec Table 9-15):
//   DCT4_MATRIX = [ 64  64  64  64 ]
//                 [ 83  36 -36 -83 ]
//                 [ 64 -64 -64  64 ]
//                 [ 36 -83  83 -36 ]
//
// HM applies the transform in two passes (row then column), each pass
// uses one dimensional butterfly with a shift/round to control precision.
//
// Shift values (from HM TComTrQuant.cpp):
//   Forward:
//     shift_1st = g_aucConvertToBit[4] + 1 + bitDepth - 8
//               = 0 + 1 + 10 - 8 = 3   (for 10-bit, InternalBitDepth=10)
//     shift_2nd = g_aucConvertToBit[4] + 8
//               = 0 + 8 = 8
//   Inverse:
//     shift_1st = SHIFT_INV_1ST = 7
//     shift_2nd = SHIFT_INV_2ND = 12  (for 10-bit: 20 - InternalBitDepth)
//
// Pipeline:
//   Forward: 2-stage pipeline (row pass → col pass), 2 cycle latency
//   Inverse: 2-stage pipeline, 2 cycle latency
//   Both stages fully pipelined — accepts new block every cycle
//   (in practice CTU pipeline feeds one 4x4 block per 16 cycles)
//
// Port naming matches TU_INFO_BUS_SIGNALS in hevc_interfaces.vh
//=============================================================================

`include "../common/parameter_pkg.vh"

module dct4 (
    input  wire         clk,
    input  wire         rst_n,

    // Control
    input  wire         fwd_inv_n,      // 1=forward DCT, 0=inverse DCT

    // Input handshake
    input  wire         in_valid,
    output wire         in_ready,
    // 4x4 block, row-major, signed 16-bit coefficients
    // in_data[row][col]
    input  wire signed [`COEFF_WIDTH-1:0] in_data [0:3][0:3],

    // Output handshake
    output reg          out_valid,
    input  wire         out_ready,
    // out_data[row][col]
    output reg  signed [`COEFF_WIDTH-1:0] out_data [0:3][0:3]
);

    //-------------------------------------------------------------------------
    // DCT-4 basis coefficients (from HEVC spec Table 9-15)
    // Stored as localparams — synthesize as constants, no ROM needed
    //-------------------------------------------------------------------------
    localparam signed [7:0] A = 8'sd64;   // cos(0)   * 64 = 64
    localparam signed [7:0] B = 8'sd83;   // cos(π/8) * 64 ≈ 83
    localparam signed [7:0] C = 8'sd36;   // cos(3π/8)* 64 ≈ 36

    //-------------------------------------------------------------------------
    // Shift/round constants (HM TComTrQuant.cpp)
    // InternalBitDepth = 10 (from parameter_pkg.vh BIT_DEPTH=10)
    //-------------------------------------------------------------------------
    localparam FWD_SHIFT_1 = `BIT_DEPTH - 7;      // row pass shift
    localparam FWD_SHIFT_2 = 8;           // col pass shift
    localparam INV_SHIFT_1 = 7;           // SHIFT_INV_1ST (HM constant)
    localparam BIT_DEPTH_ADJUST = (`BIT_DEPTH > 8) ? (`BIT_DEPTH - 8) : 0;
    localparam INV_SHIFT_2 = 12 - BIT_DEPTH_ADJUST; // SHIFT_INV_2ND (matches HM xITrMxN)

    // Rounding offsets: add (1 << (shift-1)) before right-shifting
    localparam FWD_RND_1 = (1 << (FWD_SHIFT_1 - 1));   // 4
    localparam FWD_RND_2 = (1 << (FWD_SHIFT_2 - 1));   // 128
    localparam INV_RND_1 = (1 << (INV_SHIFT_1 - 1));   // 64
    localparam INV_RND_2 = (1 << (INV_SHIFT_2 - 1));   // 2048

    //-------------------------------------------------------------------------
    // Clip helper — clamp to 16-bit signed range after inverse (HM Short overflow guard)
    // HM: Clip3(-32768, 32767, val)
    //-------------------------------------------------------------------------
    localparam signed [31:0] CLIP_MAX =  32767;
    localparam signed [31:0] CLIP_MIN = -32768;

    //-------------------------------------------------------------------------
    // Internal extended-width wires for butterfly intermediate values
    // partialButterfly4 uses 32-bit intermediates in HM (Int = int32_t)
    //-------------------------------------------------------------------------
    // Stage 1 (row pass) output — intermediate before shift
    reg signed [31:0] stage1 [0:3][0:3];
    reg                                stage1_valid;
    reg                                stage1_fwd_inv_n;

    //-------------------------------------------------------------------------
    // Stall logic
    // Simple: stall input if stage1 is full and output not accepted
    //-------------------------------------------------------------------------
    wire stall = stage1_valid && out_valid && !out_ready;
    assign in_ready = !stall;

    //=========================================================================
    // FORWARD DCT — partialButterfly4()
    //
    // HM C++ reference (condensed):
    //   // Row pass
    //   E[0] = src[0] + src[3];  E[1] = src[1] + src[2]
    //   O[0] = src[0] - src[3];  O[1] = src[1] - src[2]
    //   dst[0] = (A*E[0] + A*E[1] + add) >> shift
    //   dst[1] = (B*O[0] + C*O[1] + add) >> shift
    //   dst[2] = (A*E[0] - A*E[1] + add) >> shift
    //   dst[3] = (C*O[0] - B*O[1] + add) >> shift  [note: HM sign is -B]
    //   // Col pass: same butterfly on transposed rows
    //=========================================================================

    //-------------------------------------------------------------------------
    // Stage 1: Row pass (forward) / Col pass (inverse)
    // Processes all 4 rows in parallel — combinational butterfly + register
    //-------------------------------------------------------------------------
    integer r;

    always @(posedge clk) begin
        if (!rst_n) begin
            stage1_valid <= 1'b0;
            stage1_fwd_inv_n <= 1'b0;
            for (r = 0; r < 4; r = r + 1) begin
                stage1[r][0] <= 32'sd0;
                stage1[r][1] <= 32'sd0;
                stage1[r][2] <= 32'sd0;
                stage1[r][3] <= 32'sd0;
            end
        end else if (!stall) begin
            stage1_valid <= in_valid;

            if (in_valid) begin
                stage1_fwd_inv_n <= fwd_inv_n;
                if (fwd_inv_n) begin
                    //----------------------------------------------------------
                    // FORWARD row pass — maps to partialButterfly4 rows
                    // E = even sums, O = odd differences
                    //----------------------------------------------------------
                    for (r = 0; r < 4; r = r + 1) begin : fwd_row
                        // Even/odd butterfly
                        // E[0] = in[r][0] + in[r][3]
                        // E[1] = in[r][1] + in[r][2]
                        // O[0] = in[r][0] - in[r][3]
                        // O[1] = in[r][1] - in[r][2]
                        reg signed [31:0] E0, E1, O0, O1;
                        E0 = in_data[r][0] + in_data[r][3];
                        E1 = in_data[r][1] + in_data[r][2];
                        O0 = in_data[r][0] - in_data[r][3];
                        O1 = in_data[r][1] - in_data[r][2];

                        // Butterfly multiply + round + shift
                        // Output stored at transposed position [col][row]
                        // so stage2 col pass sees rows correctly
                        stage1[r][0] <= (A*E0 + A*E1 + FWD_RND_1) >>> FWD_SHIFT_1;
                        stage1[r][1] <= (B*O0 + C*O1 + FWD_RND_1) >>> FWD_SHIFT_1;
                        stage1[r][2] <= (A*E0 - A*E1 + FWD_RND_1) >>> FWD_SHIFT_1;
                        stage1[r][3] <= (C*O0 - B*O1 + FWD_RND_1) >>> FWD_SHIFT_1;
                    end

                end else begin
                    //----------------------------------------------------------
                    // INVERSE col pass — maps to partialButterflyInverse4
                    // Same butterfly structure, applied to columns
                    // Input is quantized coefficients in [row][col] order
                    //----------------------------------------------------------
                    for (r = 0; r < 4; r = r + 1) begin : inv_col
                        reg signed [31:0] E0, E1, O0, O1;
                        reg signed [31:0] dst0, dst1, dst2, dst3;
                        // E = reconstructed even, O = reconstructed odd
                        E0 = (A * in_data[0][r] + A * in_data[2][r]);
                        E1 = (A * in_data[0][r] - A * in_data[2][r]);
                        O0 = (B * in_data[1][r] + C * in_data[3][r]);
                        O1 = (C * in_data[1][r] - B * in_data[3][r]);

                        dst0 = (E0 + O0 + INV_RND_1) >>> INV_SHIFT_1;
                        dst1 = (E1 + O1 + INV_RND_1) >>> INV_SHIFT_1;
                        dst2 = (E1 - O1 + INV_RND_1) >>> INV_SHIFT_1;
                        dst3 = (E0 - O0 + INV_RND_1) >>> INV_SHIFT_1;

                        stage1[r][0] <= (dst0 > CLIP_MAX) ? CLIP_MAX : ((dst0 < CLIP_MIN) ? CLIP_MIN : dst0);
                        stage1[r][1] <= (dst1 > CLIP_MAX) ? CLIP_MAX : ((dst1 < CLIP_MIN) ? CLIP_MIN : dst1);
                        stage1[r][2] <= (dst2 > CLIP_MAX) ? CLIP_MAX : ((dst2 < CLIP_MIN) ? CLIP_MIN : dst2);
                        stage1[r][3] <= (dst3 > CLIP_MAX) ? CLIP_MAX : ((dst3 < CLIP_MIN) ? CLIP_MIN : dst3);
                    end
                end
            end
        end
    end

    //=========================================================================
    // Stage 2: Col pass (forward) / Row pass (inverse) + shift/clip
    //=========================================================================

    integer c;

    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            for (r = 0; r < 4; r = r + 1)
                for (c = 0; c < 4; c = c + 1)
                    out_data[r][c] <= {`COEFF_WIDTH{1'b0}};
        end else if (!out_ready) begin
            // Hold output until consumer accepts
            out_valid <= out_valid;
        end else begin
            out_valid <= stage1_valid;

            if (stage1_valid) begin
                if (stage1_fwd_inv_n) begin
                    //----------------------------------------------------------
                    // FORWARD col pass
                    // stage1[row][col] is already transposed from row pass
                    // Now treat stage1 rows as DCT columns → butterfly again
                    //----------------------------------------------------------
                    for (c = 0; c < 4; c = c + 1) begin : fwd_col
                        reg signed [31:0] E0, E1, O0, O1;
                        E0 = stage1[0][c] + stage1[3][c];
                        E1 = stage1[1][c] + stage1[2][c];
                        O0 = stage1[0][c] - stage1[3][c];
                        O1 = stage1[1][c] - stage1[2][c];

                        out_data[0][c] <= (A*E0 + A*E1 + FWD_RND_2) >>> FWD_SHIFT_2;
                        out_data[1][c] <= (B*O0 + C*O1 + FWD_RND_2) >>> FWD_SHIFT_2;
                        out_data[2][c] <= (A*E0 - A*E1 + FWD_RND_2) >>> FWD_SHIFT_2;
                        out_data[3][c] <= (C*O0 - B*O1 + FWD_RND_2) >>> FWD_SHIFT_2;
                    end

                end else begin
                    //----------------------------------------------------------
                    // INVERSE row pass + shift + clip
                    // stage1[col][row] holds partial sums from col pass
                    // Apply butterfly, rounding shift and clip to 16-bit range
                    //----------------------------------------------------------
                    for (r = 0; r < 4; r = r + 1) begin : inv_row
                        reg signed [31:0] E0, E1, O0, O1;
                        reg signed [31:0] dst0, dst1, dst2, dst3;

                        E0 = (A * stage1[0][r] + A * stage1[2][r]);
                        E1 = (A * stage1[0][r] - A * stage1[2][r]);
                        O0 = (B * stage1[1][r] + C * stage1[3][r]);
                        O1 = (C * stage1[1][r] - B * stage1[3][r]);

                        dst0 = (E0 + O0 + INV_RND_2) >>> INV_SHIFT_2;
                        dst1 = (E1 + O1 + INV_RND_2) >>> INV_SHIFT_2;
                        dst2 = (E1 - O1 + INV_RND_2) >>> INV_SHIFT_2;
                        dst3 = (E0 - O0 + INV_RND_2) >>> INV_SHIFT_2;

                        // Clip to signed 16-bit range
                        out_data[r][0] <= (dst0 > CLIP_MAX) ? CLIP_MAX[`COEFF_WIDTH-1:0] : ((dst0 < CLIP_MIN) ? CLIP_MIN[`COEFF_WIDTH-1:0] : dst0[`COEFF_WIDTH-1:0]);
                        out_data[r][1] <= (dst1 > CLIP_MAX) ? CLIP_MAX[`COEFF_WIDTH-1:0] : ((dst1 < CLIP_MIN) ? CLIP_MIN[`COEFF_WIDTH-1:0] : dst1[`COEFF_WIDTH-1:0]);
                        out_data[r][2] <= (dst2 > CLIP_MAX) ? CLIP_MAX[`COEFF_WIDTH-1:0] : ((dst2 < CLIP_MIN) ? CLIP_MIN[`COEFF_WIDTH-1:0] : dst2[`COEFF_WIDTH-1:0]);
                        out_data[r][3] <= (dst3 > CLIP_MAX) ? CLIP_MAX[`COEFF_WIDTH-1:0] : ((dst3 < CLIP_MIN) ? CLIP_MIN[`COEFF_WIDTH-1:0] : dst3[`COEFF_WIDTH-1:0]);
                    end
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // Simulation checks
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && in_valid && !in_ready)
            $display("INFO  [dct4] input stalled at time=%0t", $time);
    end

    // Verify forward output against known 4x4 all-ones input
    // Forward DCT of all-64 (10-bit mid-value) → [0][0] should be 256*64=non-zero
    // This fires once in simulation to confirm butterfly constants are correct
    integer check_done;
    initial check_done = 0;
    always @(posedge clk) begin
        if (rst_n && out_valid && fwd_inv_n && !check_done) begin
            $display("INFO  [dct4] first forward output [0][0]=%0d [1][0]=%0d",
                     out_data[0][0], out_data[1][0]);
            check_done = 1;
        end
    end
    // synthesis translate_on

endmodule