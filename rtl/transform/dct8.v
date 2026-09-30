//=============================================================================
// dct8.v
// 8x8 Integer DCT — Forward and Inverse
//
// Mapped from HM source:
//   TLibCommon/TComTrQuant.cpp
//   void partialButterfly8()        — forward 8x8
//   void partialButterflyInverse8() — inverse 8x8
//
// HEVC integer DCT-II 8x8 basis vectors (spec Table 9-15):
//   Row 0 (DC):  64  64  64  64  64  64  64  64
//   Row 1:       89  75  50  18 -18 -50 -75 -89
//   Row 2:       83  36 -36 -83 -83 -36  36  83
//   Row 3:       75 -18 -89 -50  50  89  18 -75
//   Row 4:       64 -64 -64  64  64 -64 -64  64
//   Row 5:       50 -89  18  75 -75 -18  89 -50
//   Row 6:       36 -83  83 -36 -36  83 -83  36
//   Row 7:       18 -50  75 -89  89 -75  50 -18
//
// HM butterfly decomposition (partialButterfly8):
//   E[0..3] = even sums:  src[k] + src[7-k]  for k=0..3
//   O[0..3] = odd diffs:  src[k] - src[7-k]  for k=0..3
//   EE[0..1] = even-even: E[0]+E[3], E[1]+E[2]
//   EO[0..1] = even-odd:  E[0]-E[3], E[1]-E[2]
//   Then: 4 even outputs from EE/EO using DCT-4 like butterfly
//         4 odd  outputs from O using 4-point odd butterfly
//
// Shift values (HM, 10-bit):
//   Forward:
//     shift_1st = g_aucConvertToBit[8]+1+bitDepth-8 = 1+1+10-8 = 4
//     shift_2nd = g_aucConvertToBit[8]+8            = 1+8      = 9
//   Inverse:
//     shift_1st = SHIFT_INV_1ST = 7
//     shift_2nd = 12 - max(bitDepth-8,0)            = 12-2     = 10
//
// Pipeline:
//   2-stage pipeline identical to dct4 (row pass → col pass)
//   Each stage processes all 8 rows/cols in parallel
//   Latency: 2 cycles
//   fwd_inv_n pipelined through stage1 register to avoid race (learned from dct4)
//
// Intermediate width:
//   Max intermediate before shift_1st:
//     O[k] max = 2*32767 = 65534 (17-bit)
//     basis coeff max = 89 (7-bit)
//     product = 89*65534 ≈ 5.8M → 23-bit
//     sum of 4 products ≈ 23.2M → 25-bit
//   Use INT_WIDTH = 32 bits signed throughout (matches HM Int = int32_t)
//=============================================================================

`include "parameter_pkg.vh"

module dct8 (
    input  wire         clk,
    input  wire         rst_n,

    // Control — pipelined internally
    input  wire         fwd_inv_n,      // 1=forward, 0=inverse

    // Input handshake
    input  wire         in_valid,
    output wire         in_ready,
    input  wire [1023:0] in_data,

    // Output handshake
    output reg          out_valid,
    input  wire         out_ready,
    output wire [1023:0] out_data
);

    wire signed [`COEFF_WIDTH-1:0] in_data_arr [0:7][0:7];
    reg  signed [`COEFF_WIDTH-1:0] out_data_arr [0:7][0:7];

    genvar gi, gj;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : gen_flat
            for (gj = 0; gj < 8; gj = gj + 1) begin : gen_flat_col
                assign in_data_arr[gi][gj] = in_data[(gi*8+gj)*16 +: 16];
                assign out_data[(gi*8+gj)*16 +: 16] = out_data_arr[gi][gj];
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // DCT-8 basis coefficients (HEVC spec Table 9-15)
    // Need 8-bit signed: max value = 89 < 127 → [7:0] sufficient
    //-------------------------------------------------------------------------
    localparam signed [7:0] T64 = 8'sd64;
    localparam signed [7:0] T83 = 8'sd83;
    localparam signed [7:0] T36 = 8'sd36;
    localparam signed [7:0] T89 = 8'sd89;
    localparam signed [7:0] T75 = 8'sd75;
    localparam signed [7:0] T50 = 8'sd50;
    localparam signed [7:0] T18 = 8'sd18;

    //-------------------------------------------------------------------------
    // Shift/round constants (HM TComTrQuant.cpp, 10-bit)
    // g_aucConvertToBit[8] = 1  (log2(8)-2 = 1)
    //-------------------------------------------------------------------------
    localparam FWD_SHIFT_1 = 4;                          // 1+1+10-8
    localparam FWD_SHIFT_2 = 9;                          // 1+8
    localparam INV_SHIFT_1 = 7;                          // SHIFT_INV_1ST
    localparam BIT_DEPTH_ADJ = (`BIT_DEPTH > 8) ? (`BIT_DEPTH - 8) : 0;
    localparam INV_SHIFT_2   = 12 - BIT_DEPTH_ADJ;      // 10 for 10-bit

    localparam FWD_RND_1 = (1 << (FWD_SHIFT_1 - 1));   // 8
    localparam FWD_RND_2 = (1 << (FWD_SHIFT_2 - 1));   // 256
    localparam INV_RND_1 = (1 << (INV_SHIFT_1 - 1));   // 64
    localparam INV_RND_2 = (1 << (INV_SHIFT_2 - 1));   // 512

    //-------------------------------------------------------------------------
    // Intermediate width: 32-bit signed matching HM Int = int32_t
    // Prevents overflow proven to corrupt dct4 at 20-bit
    //-------------------------------------------------------------------------
    localparam IW = 32;   // intermediate width

    //-------------------------------------------------------------------------
    // Clip bounds — HM Short range for inter-stage (learned from dct4 Bug 3)
    // Final pixel clip happens in recon_unit.v
    //-------------------------------------------------------------------------
    localparam signed [IW-1:0] CLIP_MAX =  32767;
    localparam signed [IW-1:0] CLIP_MIN = -32768;

    //-------------------------------------------------------------------------
    // Stage 1 registers
    // stage1[row][col] — 16-bit after shift (clipped to Short range)
    // fwd_inv_n_s1 — pipelined control (learned from dct4 Bug 3)
    //-------------------------------------------------------------------------
    reg signed [`COEFF_WIDTH-1:0] stage1 [0:7][0:7];
    reg                            stage1_valid;
    reg                            fwd_inv_n_s1;   // pipelined through stage1

    //-------------------------------------------------------------------------
    // Stall logic — same pattern as dct4
    //-------------------------------------------------------------------------
    wire stall = stage1_valid && !out_ready;
    assign in_ready = !stall;

    //-------------------------------------------------------------------------
    // Clip function macro — applied after each pass (HM Clip3 Short)
    //-------------------------------------------------------------------------
    `define CLIP16(x) \
        (((x) > CLIP_MAX) ? CLIP_MAX[`COEFF_WIDTH-1:0] : \
         ((x) < CLIP_MIN) ? CLIP_MIN[`COEFF_WIDTH-1:0] : \
         (x))

    //=========================================================================
    // STAGE 1 — Row pass (fwd) / Col pass (inv)
    // All 8 rows processed in parallel
    //=========================================================================
    integer r;

    always @(posedge clk) begin : stage1_proc
        integer k;
        if (!rst_n) begin
            stage1_valid  <= 1'b0;
            fwd_inv_n_s1  <= 1'b0;
            for (r = 0; r < 8; r = r + 1)
                for (k = 0; k < 8; k = k + 1)
                    stage1[r][k] <= {`COEFF_WIDTH{1'b0}};
        end else if (!stall) begin
            stage1_valid <= in_valid;
            fwd_inv_n_s1 <= fwd_inv_n;   // pipeline control with data

            if (in_valid) begin
                if (fwd_inv_n) begin
                    //----------------------------------------------------------
                    // FORWARD row pass — partialButterfly8()
                    // For each row r, compute 8-point DCT butterfly
                    //----------------------------------------------------------
                    for (r = 0; r < 8; r = r + 1) begin : fwd_row8
                        reg signed [IW-1:0] E0,E1,E2,E3;
                        reg signed [IW-1:0] O0,O1,O2,O3;
                        reg signed [IW-1:0] EE0,EE1,EO0,EO1;

                        // Even/odd decomposition (HM partialButterfly8)
                    E0 = in_data_arr[r][0] + in_data_arr[r][7];
                    E1 = in_data_arr[r][1] + in_data_arr[r][6];
                    E2 = in_data_arr[r][2] + in_data_arr[r][5];
                    E3 = in_data_arr[r][3] + in_data_arr[r][4];
                    O0 = in_data_arr[r][0] - in_data_arr[r][7];
                    O1 = in_data_arr[r][1] - in_data_arr[r][6];
                    O2 = in_data_arr[r][2] - in_data_arr[r][5];
                    O3 = in_data_arr[r][3] - in_data_arr[r][4];

                        // Even-even / even-odd (maps to DCT-4 on E)
                        EE0 = E0 + E3;
                        EE1 = E1 + E2;
                        EO0 = E0 - E3;
                        EO1 = E1 - E2;

                        // 4 even outputs — same butterfly as DCT-4 on EE/EO
                        stage1[r][0] <= `CLIP16((T64*EE0 + T64*EE1 + FWD_RND_1) >>> FWD_SHIFT_1);
                        stage1[r][2] <= `CLIP16((T83*EO0 + T36*EO1 + FWD_RND_1) >>> FWD_SHIFT_1);
                        stage1[r][4] <= `CLIP16((T64*EE0 - T64*EE1 + FWD_RND_1) >>> FWD_SHIFT_1);
                        stage1[r][6] <= `CLIP16((T36*EO0 - T83*EO1 + FWD_RND_1) >>> FWD_SHIFT_1);

                        // 4 odd outputs — 4-point odd butterfly using O[0..3]
                        stage1[r][1] <= `CLIP16((T89*O0 + T75*O1 + T50*O2 + T18*O3 + FWD_RND_1) >>> FWD_SHIFT_1);
                        stage1[r][3] <= `CLIP16((T75*O0 - T18*O1 - T89*O2 - T50*O3 + FWD_RND_1) >>> FWD_SHIFT_1);
                        stage1[r][5] <= `CLIP16((T50*O0 - T89*O1 + T18*O2 + T75*O3 + FWD_RND_1) >>> FWD_SHIFT_1);
                        stage1[r][7] <= `CLIP16((T18*O0 - T50*O1 + T75*O2 - T89*O3 + FWD_RND_1) >>> FWD_SHIFT_1);
                    end

                end else begin
                    //----------------------------------------------------------
                    // INVERSE col pass — partialButterflyInverse8()
                    // For each col r, apply inverse butterfly to column r
                    // in_data[0..7][r] = input column r
                    //----------------------------------------------------------
                    for (r = 0; r < 8; r = r + 1) begin : inv_col8
                        reg signed [IW-1:0] x [0:7];
                        reg signed [IW-1:0] O0,O1,O2,O3;
                        reg signed [IW-1:0] EE0,EE1,EO0,EO1;
                        reg signed [IW-1:0] E0,E1,E2,E3;

                        // Read column r
                    x[0] = in_data_arr[0][r]; x[1] = in_data_arr[1][r];
                    x[2] = in_data_arr[2][r]; x[3] = in_data_arr[3][r];
                    x[4] = in_data_arr[4][r]; x[5] = in_data_arr[5][r];
                    x[6] = in_data_arr[6][r]; x[7] = in_data_arr[7][r];

                        // Odd outputs (rows 1,3,5,7 of IDCT matrix)
                        O0 = T89*x[1] + T75*x[3] + T50*x[5] + T18*x[7];
                        O1 = T75*x[1] - T18*x[3] - T89*x[5] - T50*x[7];
                        O2 = T50*x[1] - T89*x[3] + T18*x[5] + T75*x[7];
                        O3 = T18*x[1] - T50*x[3] + T75*x[5] - T89*x[7];

                        // Even-even from rows 0,4
                        EE0 = T64*x[0] + T64*x[4];
                        EE1 = T64*x[0] - T64*x[4];

                        // Even-odd from rows 2,6
                        EO0 = T83*x[2] + T36*x[6];
                        EO1 = T36*x[2] - T83*x[6];

                        // Even outputs
                        E0 = EE0 + EO0;
                        E1 = EE1 + EO1;
                        E2 = EE1 - EO1;
                        E3 = EE0 - EO0;

                        // Combine even+odd with shift (INV_SHIFT_1=7)
                        // Clip to Short range per HM Clip3 after each pass
                        stage1[r][0] <= `CLIP16((E0 + O0 + INV_RND_1) >>> INV_SHIFT_1);
                        stage1[r][1] <= `CLIP16((E1 + O1 + INV_RND_1) >>> INV_SHIFT_1);
                        stage1[r][2] <= `CLIP16((E2 + O2 + INV_RND_1) >>> INV_SHIFT_1);
                        stage1[r][3] <= `CLIP16((E3 + O3 + INV_RND_1) >>> INV_SHIFT_1);
                        stage1[r][4] <= `CLIP16((E3 - O3 + INV_RND_1) >>> INV_SHIFT_1);
                        stage1[r][5] <= `CLIP16((E2 - O2 + INV_RND_1) >>> INV_SHIFT_1);
                        stage1[r][6] <= `CLIP16((E1 - O1 + INV_RND_1) >>> INV_SHIFT_1);
                        stage1[r][7] <= `CLIP16((E0 - O0 + INV_RND_1) >>> INV_SHIFT_1);
                    end
                end
            end
        end
    end

    //=========================================================================
    // STAGE 2 — Col pass (fwd) / Row pass (inv)
    // Uses fwd_inv_n_s1 (pipelined) not fwd_inv_n (live)
    //=========================================================================
    integer c;

    always @(posedge clk) begin : stage2_proc
        integer k;
        if (!rst_n) begin
            out_valid <= 1'b0;
            for (c = 0; c < 8; c = c + 1)
                for (k = 0; k < 8; k = k + 1)
                    out_data_arr[c][k] <= {`COEFF_WIDTH{1'b0}};
        end else if (!out_ready) begin
            out_valid <= out_valid;
        end else begin
            out_valid <= stage1_valid;

            if (stage1_valid) begin
                if (fwd_inv_n_s1) begin
                    //----------------------------------------------------------
                    // FORWARD col pass
                    // For each col c, apply butterfly to stage1[0..7][c]
                    //----------------------------------------------------------
                    for (c = 0; c < 8; c = c + 1) begin : fwd_col8
                        reg signed [IW-1:0] E0,E1,E2,E3;
                        reg signed [IW-1:0] O0,O1,O2,O3;
                        reg signed [IW-1:0] EE0,EE1,EO0,EO1;

                        E0 = stage1[0][c] + stage1[7][c];
                        E1 = stage1[1][c] + stage1[6][c];
                        E2 = stage1[2][c] + stage1[5][c];
                        E3 = stage1[3][c] + stage1[4][c];
                        O0 = stage1[0][c] - stage1[7][c];
                        O1 = stage1[1][c] - stage1[6][c];
                        O2 = stage1[2][c] - stage1[5][c];
                        O3 = stage1[3][c] - stage1[4][c];

                        EE0 = E0 + E3; EE1 = E1 + E2;
                        EO0 = E0 - E3; EO1 = E1 - E2;

                    out_data_arr[0][c] <= `CLIP16((T64*EE0 + T64*EE1 + FWD_RND_2) >>> FWD_SHIFT_2);
                    out_data_arr[2][c] <= `CLIP16((T83*EO0 + T36*EO1 + FWD_RND_2) >>> FWD_SHIFT_2);
                    out_data_arr[4][c] <= `CLIP16((T64*EE0 - T64*EE1 + FWD_RND_2) >>> FWD_SHIFT_2);
                    out_data_arr[6][c] <= `CLIP16((T36*EO0 - T83*EO1 + FWD_RND_2) >>> FWD_SHIFT_2);
                    out_data_arr[1][c] <= `CLIP16((T89*O0 + T75*O1 + T50*O2 + T18*O3 + FWD_RND_2) >>> FWD_SHIFT_2);
                    out_data_arr[3][c] <= `CLIP16((T75*O0 - T18*O1 - T89*O2 - T50*O3 + FWD_RND_2) >>> FWD_SHIFT_2);
                    out_data_arr[5][c] <= `CLIP16((T50*O0 - T89*O1 + T18*O2 + T75*O3 + FWD_RND_2) >>> FWD_SHIFT_2);
                    out_data_arr[7][c] <= `CLIP16((T18*O0 - T50*O1 + T75*O2 - T89*O3 + FWD_RND_2) >>> FWD_SHIFT_2);
                    end

                end else begin
                    //----------------------------------------------------------
                    // INVERSE row pass
                    // Row r of stage1 = [stage1[0][r]..stage1[7][r]]
                    //----------------------------------------------------------
                    for (r = 0; r < 8; r = r + 1) begin : inv_row8
                        reg signed [IW-1:0] x [0:7];
                        reg signed [IW-1:0] O0,O1,O2,O3;
                        reg signed [IW-1:0] EE0,EE1,EO0,EO1;
                        reg signed [IW-1:0] E0,E1,E2,E3;

                        // Read row r across stage1 columns
                        x[0] = stage1[0][r]; x[1] = stage1[1][r];
                        x[2] = stage1[2][r]; x[3] = stage1[3][r];
                        x[4] = stage1[4][r]; x[5] = stage1[5][r];
                        x[6] = stage1[6][r]; x[7] = stage1[7][r];

                        O0 = T89*x[1] + T75*x[3] + T50*x[5] + T18*x[7];
                        O1 = T75*x[1] - T18*x[3] - T89*x[5] - T50*x[7];
                        O2 = T50*x[1] - T89*x[3] + T18*x[5] + T75*x[7];
                        O3 = T18*x[1] - T50*x[3] + T75*x[5] - T89*x[7];

                        EE0 = T64*x[0] + T64*x[4];
                        EE1 = T64*x[0] - T64*x[4];
                        EO0 = T83*x[2] + T36*x[6];
                        EO1 = T36*x[2] - T83*x[6];

                        E0 = EE0 + EO0;
                        E1 = EE1 + EO1;
                        E2 = EE1 - EO1;
                        E3 = EE0 - EO0;

                    out_data_arr[r][0] <= `CLIP16((E0 + O0 + INV_RND_2) >>> INV_SHIFT_2);
                    out_data_arr[r][1] <= `CLIP16((E1 + O1 + INV_RND_2) >>> INV_SHIFT_2);
                    out_data_arr[r][2] <= `CLIP16((E2 + O2 + INV_RND_2) >>> INV_SHIFT_2);
                    out_data_arr[r][3] <= `CLIP16((E3 + O3 + INV_RND_2) >>> INV_SHIFT_2);
                    out_data_arr[r][4] <= `CLIP16((E3 - O3 + INV_RND_2) >>> INV_SHIFT_2);
                    out_data_arr[r][5] <= `CLIP16((E2 - O2 + INV_RND_2) >>> INV_SHIFT_2);
                    out_data_arr[r][6] <= `CLIP16((E1 - O1 + INV_RND_2) >>> INV_SHIFT_2);
                    out_data_arr[r][7] <= `CLIP16((E0 - O0 + INV_RND_2) >>> INV_SHIFT_2);
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
            $display("INFO  [dct8] input stalled at time=%0t", $time);
    end

    integer check8_done;
    initial check8_done = 0;
    always @(posedge clk) begin
        if (rst_n && out_valid && fwd_inv_n_s1 && !check8_done) begin
            $display("INFO  [dct8] first fwd output [0][0]=%0d [1][0]=%0d",
                     out_data_arr[0][0], out_data_arr[1][0]);
            check8_done = 1;
        end
    end
    // synthesis translate_on

    // Clean up internal macro
    `undef CLIP16

endmodule