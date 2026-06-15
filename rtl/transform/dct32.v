//=============================================================================
// dct32.v
// 32x32 Integer DCT — Forward and Inverse
//
// Mapped from HM source:
//   TLibCommon/TComTrQuant.cpp
//   void partialButterfly32()        — forward 32x32
//   void partialButterflyInverse32() — inverse 32x32
//
// HEVC integer DCT-II 32x32 basis coefficients (spec Table 9-15):
//   Even rows reuse all DCT-16 values (T64..T09)
//   Odd rows (new for 32-point, 16 values):
//     T90 T90 T88 T85 T82 T78 T73 T67
//     T61 T54 T46 T38 T31 T22 T13 T04
//   Note: T90 appears twice at different indices — these are
//         distinct values 90 and 90 (row 1 col 0 = 90, row 1 col 1 = 90)
//         In HM g_aiT32[1][0..31]:
//         90 90 88 85 82 78 73 67 61 54 46 38 31 22 13 4
//        -4-13-22-31-38-46-54-61-67-73-78-82-85-88-90-90
//
// HM butterfly decomposition (partialButterfly32):
//   E[0..15] = src[k] + src[31-k]  for k=0..15   (even sums)
//   O[0..15] = src[k] - src[31-k]  for k=0..15   (odd diffs)
//   Then DCT-16 on E → 16 even outputs
//        16 odd outputs from O[0..15] via 16-point odd butterfly
//
// Shift values (HM, 10-bit):
//   g_aucConvertToBit[32] = 3
//   Forward:
//     shift_1st = 3+1+10-8 = 6
//     shift_2nd = 3+8      = 11
//   Inverse:
//     shift_1st = 7
//     shift_2nd = 12 - max(10-8,0) = 10
//
// Intermediate width:
//   O[k] max = 2*32767 = 65534
//   Basis coeff max = 90
//   Sum of 16 products = 16 * 90 * 65534 ≈ 94.4M → 27-bit
//   Use IW=32 (matches HM Int = int32_t)
//
// Pipeline: 2-stage, 2-cycle latency, fwd_inv_n pipelined through stage1
// This is the largest DCT — TU_LOG2_MAX=5 in config → max TU is 32x32
//=============================================================================

`include "parameter_pkg.vh"

module dct32 (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         fwd_inv_n,

    input  wire         in_valid,
    output wire         in_ready,
    input  wire [16383:0] in_data,

    output reg          out_valid,
    input  wire         out_ready,
    output wire [16383:0] out_data
);

    wire signed [`COEFF_WIDTH-1:0] in_data_arr [0:31][0:31];
    reg  signed [`COEFF_WIDTH-1:0] out_data_arr [0:31][0:31];

    genvar gi, gj;
    generate
        for (gi = 0; gi < 32; gi = gi + 1) begin : gen_flat
            for (gj = 0; gj < 32; gj = gj + 1) begin : gen_flat_col
                assign in_data_arr[gi][gj] = in_data[(gi*32+gj)*16 +: 16];
                assign out_data[(gi*32+gj)*16 +: 16] = out_data_arr[gi][gj];
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // DCT-32 basis coefficients (HEVC spec Table 9-15)
    // All ≤ 90 — 8-bit signed sufficient (max 127)
    //-------------------------------------------------------------------------
    // Inherited from DCT-16
    localparam signed [7:0] T64 = 8'sd64;
    localparam signed [7:0] T83 = 8'sd83;
    localparam signed [7:0] T36 = 8'sd36;
    localparam signed [7:0] T89 = 8'sd89;
    localparam signed [7:0] T75 = 8'sd75;
    localparam signed [7:0] T50 = 8'sd50;
    localparam signed [7:0] T18 = 8'sd18;
    localparam signed [7:0] T90 = 8'sd90;
    localparam signed [7:0] T87 = 8'sd87;
    localparam signed [7:0] T80 = 8'sd80;
    localparam signed [7:0] T70 = 8'sd70;
    localparam signed [7:0] T57 = 8'sd57;
    localparam signed [7:0] T43 = 8'sd43;
    localparam signed [7:0] T25 = 8'sd25;
    localparam signed [7:0] T09 = 8'sd9;
    // New for 32-point odd butterfly (g_aiT32 odd rows)
    localparam signed [7:0] T90b= 8'sd90;  // row1 col1 = 90 (same value, distinct position)
    localparam signed [7:0] T88 = 8'sd88;
    localparam signed [7:0] T85 = 8'sd85;
    localparam signed [7:0] T82 = 8'sd82;
    localparam signed [7:0] T78 = 8'sd78;
    localparam signed [7:0] T73 = 8'sd73;
    localparam signed [7:0] T67 = 8'sd67;
    localparam signed [7:0] T61 = 8'sd61;
    localparam signed [7:0] T54 = 8'sd54;
    localparam signed [7:0] T46 = 8'sd46;
    localparam signed [7:0] T38 = 8'sd38;
    localparam signed [7:0] T31 = 8'sd31;
    localparam signed [7:0] T22 = 8'sd22;
    localparam signed [7:0] T13 = 8'sd13;
    localparam signed [7:0] T04 = 8'sd4;

    //-------------------------------------------------------------------------
    // Shift/round constants (HM, 10-bit)
    // g_aucConvertToBit[32] = 3
    //-------------------------------------------------------------------------
    localparam FWD_SHIFT_1 = 6;
    localparam FWD_SHIFT_2 = 11;
    localparam INV_SHIFT_1 = 7;
    localparam BIT_DEPTH_ADJ = (`BIT_DEPTH > 8) ? (`BIT_DEPTH - 8) : 0;
    localparam INV_SHIFT_2   = 12 - BIT_DEPTH_ADJ;      // 10 for 10-bit

    localparam FWD_RND_1 = (1 << (FWD_SHIFT_1 - 1));   // 32
    localparam FWD_RND_2 = (1 << (FWD_SHIFT_2 - 1));   // 1024
    localparam INV_RND_1 = (1 << (INV_SHIFT_1 - 1));   // 64
    localparam INV_RND_2 = (1 << (INV_SHIFT_2 - 1));   // 512

    localparam IW = 32;

    localparam signed [IW-1:0] CLIP_MAX =  32767;
    localparam signed [IW-1:0] CLIP_MIN = -32768;

    `define CLIP16(x) \
        (((x) > CLIP_MAX) ? CLIP_MAX[`COEFF_WIDTH-1:0] : \
         ((x) < CLIP_MIN) ? CLIP_MIN[`COEFF_WIDTH-1:0] : \
         (x))

    //-------------------------------------------------------------------------
    // Stage 1 registers + pipelined control
    //-------------------------------------------------------------------------
    reg signed [`COEFF_WIDTH-1:0] stage1 [0:31][0:31];
    reg                            stage1_valid;
    reg                            fwd_inv_n_s1;

    wire stall = stage1_valid && out_valid && !out_ready;
    assign in_ready = !stall;

    //=========================================================================
    // STAGE 1 — Row pass (fwd) / Col pass (inv)
    //=========================================================================
    integer r;

    // Macro: 16-output odd butterfly for 32-pt (maps to g_aiT32 odd rows)
    // Used in both forward row pass and inverse col pass
    // Input:  o[0..15]  — odd difference array
    // Output: result[0..15] via out_data or stage1 assignment
    // All 16 odd row coefficients from HM g_aiT32:
    //   Row  1: 90 90 88 85 82 78 73 67 61 54 46 38 31 22 13  4
    //   Row  3: 90 82 67 46 22 -4-31-54-73-85-90-88-78-61-38-13
    //   Row  5: 88 67 31-13-54-82-90-78-46 -4 38 73 90 85 61 22
    //   Row  7: 85 46-13-67-90-73-22 38 82 88 54 -4-61-90-78-31
    //   Row  9: 82 22-54-90-61 13 78 85 31-46-90-67  4 73 88 38
    //   Row 11: 78 -4-82-73 13 85 67-22-88-61 31 90 54-38-90-46
    //   Row 13: 73-31-90-22 78 67-38-90-13 82 61-46-88 -4 85 54
    //   Row 15: 67-54-78 38 85-22-90  4 90 13-88 31 82-46-73 61
    //   Row 17: 61-73-46 82 31-88-13 90 -4-90 22 85-38-78 54 67
    //   Row 19: 54-85 -4 88-46-61 82 13-90 38 73-78-22 90-31-67
    //   Row 21: 46-90 38 54-90 31 61-88 22 67-85 13 73-82  4 78
    //   Row 23: 38-88 73 -4-67 90-46-31 85-78 13 61-90 54 22-82
    //   Row 25: 31-78 90-61  4 54-88 82-38-22 73-90 67-13-46 85
    //   Row 27: 22-61 85-90 73-38 -4 46-78 90-82 54-13-31 67-88
    //   Row 29: 13-38 61-78 88-90 85-73 54-31  4 22-46 67-82 90
    //   Row 31:  4-13 22-31 38-46 54-61 67-73 78-82 85-88 90-90

    always @(posedge clk) begin : stage1_proc
        integer k;
        if (!rst_n) begin
            stage1_valid <= 1'b0;
            fwd_inv_n_s1 <= 1'b0;
            for (r = 0; r < 32; r = r + 1)
                for (k = 0; k < 32; k = k + 1)
                    stage1[r][k] <= {`COEFF_WIDTH{1'b0}};
        end else if (!stall) begin
            stage1_valid <= in_valid;
            fwd_inv_n_s1 <= fwd_inv_n;

            if (in_valid) begin
                if (fwd_inv_n) begin
                    //----------------------------------------------------------
                    // FORWARD row pass — partialButterfly32()
                    //----------------------------------------------------------
                    for (r = 0; r < 32; r = r + 1) begin : fwd_row32
                        reg signed [IW-1:0] E [0:15];
                        reg signed [IW-1:0] O [0:15];
                        reg signed [IW-1:0] EE[0:7];
                        reg signed [IW-1:0] EO[0:7];
                        reg signed [IW-1:0] EEE[0:3];
                        reg signed [IW-1:0] EEO[0:3];
                        reg signed [IW-1:0] EEEE[0:1];
                        reg signed [IW-1:0] EEEO[0:1];

                        // Even/odd decomposition
                        E[0] =in_data_arr[r][0] +in_data_arr[r][31]; E[1] =in_data_arr[r][1] +in_data_arr[r][30];
                        E[2] =in_data_arr[r][2] +in_data_arr[r][29]; E[3] =in_data_arr[r][3] +in_data_arr[r][28];
                        E[4] =in_data_arr[r][4] +in_data_arr[r][27]; E[5] =in_data_arr[r][5] +in_data_arr[r][26];
                        E[6] =in_data_arr[r][6] +in_data_arr[r][25]; E[7] =in_data_arr[r][7] +in_data_arr[r][24];
                        E[8] =in_data_arr[r][8] +in_data_arr[r][23]; E[9] =in_data_arr[r][9] +in_data_arr[r][22];
                        E[10]=in_data_arr[r][10]+in_data_arr[r][21]; E[11]=in_data_arr[r][11]+in_data_arr[r][20];
                        E[12]=in_data_arr[r][12]+in_data_arr[r][19]; E[13]=in_data_arr[r][13]+in_data_arr[r][18];
                        E[14]=in_data_arr[r][14]+in_data_arr[r][17]; E[15]=in_data_arr[r][15]+in_data_arr[r][16];
                        O[0] =in_data_arr[r][0] -in_data_arr[r][31]; O[1] =in_data_arr[r][1] -in_data_arr[r][30];
                        O[2] =in_data_arr[r][2] -in_data_arr[r][29]; O[3] =in_data_arr[r][3] -in_data_arr[r][28];
                        O[4] =in_data_arr[r][4] -in_data_arr[r][27]; O[5] =in_data_arr[r][5] -in_data_arr[r][26];
                        O[6] =in_data_arr[r][6] -in_data_arr[r][25]; O[7] =in_data_arr[r][7] -in_data_arr[r][24];
                        O[8] =in_data_arr[r][8] -in_data_arr[r][23]; O[9] =in_data_arr[r][9] -in_data_arr[r][22];
                        O[10]=in_data_arr[r][10]-in_data_arr[r][21]; O[11]=in_data_arr[r][11]-in_data_arr[r][20];
                        O[12]=in_data_arr[r][12]-in_data_arr[r][19]; O[13]=in_data_arr[r][13]-in_data_arr[r][18];
                        O[14]=in_data_arr[r][14]-in_data_arr[r][17]; O[15]=in_data_arr[r][15]-in_data_arr[r][16];

                        // DCT-16 layer on E[0..15]
                        EE[0]=E[0]+E[15]; EE[1]=E[1]+E[14]; EE[2]=E[2]+E[13]; EE[3]=E[3]+E[12];
                        EE[4]=E[4]+E[11]; EE[5]=E[5]+E[10]; EE[6]=E[6]+E[9];  EE[7]=E[7]+E[8];
                        EO[0]=E[0]-E[15]; EO[1]=E[1]-E[14]; EO[2]=E[2]-E[13]; EO[3]=E[3]-E[12];
                        EO[4]=E[4]-E[11]; EO[5]=E[5]-E[10]; EO[6]=E[6]-E[9];  EO[7]=E[7]-E[8];

                        EEE[0]=EE[0]+EE[7]; EEE[1]=EE[1]+EE[6]; EEE[2]=EE[2]+EE[5]; EEE[3]=EE[3]+EE[4];
                        EEO[0]=EE[0]-EE[7]; EEO[1]=EE[1]-EE[6]; EEO[2]=EE[2]-EE[5]; EEO[3]=EE[3]-EE[4];

                        EEEE[0]=EEE[0]+EEE[3]; EEEE[1]=EEE[1]+EEE[2];
                        EEEO[0]=EEE[0]-EEE[3]; EEEO[1]=EEE[1]-EEE[2];

                        // 4 DC-like outputs (rows 0,8,16,24)
                        stage1[r][0]  <= `CLIP16((T64*EEEE[0]+T64*EEEE[1]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][16] <= `CLIP16((T64*EEEE[0]-T64*EEEE[1]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][8]  <= `CLIP16((T83*EEEO[0]+T36*EEEO[1]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][24] <= `CLIP16((T36*EEEO[0]-T83*EEEO[1]+FWD_RND_1)>>>FWD_SHIFT_1);

                        // 4 EEO outputs (rows 4,12,20,28)
                        stage1[r][4]  <= `CLIP16((T89*EEO[0]+T75*EEO[1]+T50*EEO[2]+T18*EEO[3]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][12] <= `CLIP16((T75*EEO[0]-T18*EEO[1]-T89*EEO[2]-T50*EEO[3]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][20] <= `CLIP16((T50*EEO[0]-T89*EEO[1]+T18*EEO[2]+T75*EEO[3]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][28] <= `CLIP16((T18*EEO[0]-T50*EEO[1]+T75*EEO[2]-T89*EEO[3]+FWD_RND_1)>>>FWD_SHIFT_1);

                        // 8 EO outputs (rows 2,6,10,14,18,22,26,30)
                        stage1[r][2]  <= `CLIP16((T90*EO[0]+T87*EO[1]+T80*EO[2]+T70*EO[3]+T57*EO[4]+T43*EO[5]+T25*EO[6]+T09*EO[7]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][6]  <= `CLIP16((T87*EO[0]+T57*EO[1]+T09*EO[2]-T43*EO[3]-T80*EO[4]-T90*EO[5]-T70*EO[6]-T25*EO[7]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][10] <= `CLIP16((T80*EO[0]+T09*EO[1]-T70*EO[2]-T87*EO[3]-T25*EO[4]+T57*EO[5]+T90*EO[6]+T43*EO[7]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][14] <= `CLIP16((T70*EO[0]-T43*EO[1]-T87*EO[2]+T09*EO[3]+T90*EO[4]+T25*EO[5]-T80*EO[6]-T57*EO[7]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][18] <= `CLIP16((T57*EO[0]-T80*EO[1]-T25*EO[2]+T90*EO[3]-T09*EO[4]-T87*EO[5]+T43*EO[6]+T70*EO[7]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][22] <= `CLIP16((T43*EO[0]-T90*EO[1]+T57*EO[2]+T25*EO[3]-T87*EO[4]+T70*EO[5]+T09*EO[6]-T80*EO[7]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][26] <= `CLIP16((T25*EO[0]-T70*EO[1]+T90*EO[2]-T80*EO[3]+T43*EO[4]+T09*EO[5]-T57*EO[6]+T87*EO[7]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][30] <= `CLIP16((T09*EO[0]-T25*EO[1]+T43*EO[2]-T57*EO[3]+T70*EO[4]-T80*EO[5]+T87*EO[6]-T90*EO[7]+FWD_RND_1)>>>FWD_SHIFT_1);

                        // 16 odd outputs (rows 1,3,5,...,31) — g_aiT32 odd rows
                        stage1[r][1]  <= `CLIP16((T90*O[0]+T90b*O[1]+T88*O[2]+T85*O[3]+T82*O[4]+T78*O[5]+T73*O[6]+T67*O[7]+T61*O[8]+T54*O[9]+T46*O[10]+T38*O[11]+T31*O[12]+T22*O[13]+T13*O[14]+T04*O[15]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][3]  <= `CLIP16((T90*O[0]+T82*O[1]+T67*O[2]+T46*O[3]+T22*O[4]-T04*O[5]-T31*O[6]-T54*O[7]-T73*O[8]-T85*O[9]-T90*O[10]-T88*O[11]-T78*O[12]-T61*O[13]-T38*O[14]-T13*O[15]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][5]  <= `CLIP16((T88*O[0]+T67*O[1]+T31*O[2]-T13*O[3]-T54*O[4]-T82*O[5]-T90*O[6]-T78*O[7]-T46*O[8]-T04*O[9]+T38*O[10]+T73*O[11]+T90*O[12]+T85*O[13]+T61*O[14]+T22*O[15]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][7]  <= `CLIP16((T85*O[0]+T46*O[1]-T13*O[2]-T67*O[3]-T90*O[4]-T73*O[5]-T22*O[6]+T38*O[7]+T82*O[8]+T88*O[9]+T54*O[10]-T04*O[11]-T61*O[12]-T90*O[13]-T78*O[14]-T31*O[15]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][9]  <= `CLIP16((T82*O[0]+T22*O[1]-T54*O[2]-T90*O[3]-T61*O[4]+T13*O[5]+T78*O[6]+T85*O[7]+T31*O[8]-T46*O[9]-T90*O[10]-T67*O[11]+T04*O[12]+T73*O[13]+T88*O[14]+T38*O[15]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][11] <= `CLIP16((T78*O[0]-T04*O[1]-T82*O[2]-T73*O[3]+T13*O[4]+T85*O[5]+T67*O[6]-T22*O[7]-T88*O[8]-T61*O[9]+T31*O[10]+T90*O[11]+T54*O[12]-T38*O[13]-T90*O[14]-T46*O[15]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][13] <= `CLIP16((T73*O[0]-T31*O[1]-T90*O[2]-T22*O[3]+T78*O[4]+T67*O[5]-T38*O[6]-T90*O[7]-T13*O[8]+T82*O[9]+T61*O[10]-T46*O[11]-T88*O[12]-T04*O[13]+T85*O[14]+T54*O[15]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][15] <= `CLIP16((T67*O[0]-T54*O[1]-T78*O[2]+T38*O[3]+T85*O[4]-T22*O[5]-T90*O[6]+T04*O[7]+T90*O[8]+T13*O[9]-T88*O[10]+T31*O[11]+T82*O[12]-T46*O[13]-T73*O[14]+T61*O[15]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][17] <= `CLIP16((T61*O[0]-T73*O[1]-T46*O[2]+T82*O[3]+T31*O[4]-T88*O[5]-T13*O[6]+T90*O[7]-T04*O[8]-T90*O[9]+T22*O[10]+T85*O[11]-T38*O[12]-T78*O[13]+T54*O[14]+T67*O[15]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][19] <= `CLIP16((T54*O[0]-T85*O[1]-T04*O[2]+T88*O[3]-T46*O[4]-T61*O[5]+T82*O[6]+T13*O[7]-T90*O[8]+T38*O[9]+T73*O[10]-T78*O[11]-T22*O[12]+T90*O[13]-T31*O[14]-T67*O[15]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][21] <= `CLIP16((T46*O[0]-T90*O[1]+T38*O[2]+T54*O[3]-T90*O[4]+T31*O[5]+T61*O[6]-T88*O[7]+T22*O[8]+T67*O[9]-T85*O[10]+T13*O[11]+T73*O[12]-T82*O[13]+T04*O[14]+T78*O[15]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][23] <= `CLIP16((T38*O[0]-T88*O[1]+T73*O[2]-T04*O[3]-T67*O[4]+T90*O[5]-T46*O[6]-T31*O[7]+T85*O[8]-T78*O[9]+T13*O[10]+T61*O[11]-T90*O[12]+T54*O[13]+T22*O[14]-T82*O[15]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][25] <= `CLIP16((T31*O[0]-T78*O[1]+T90*O[2]-T61*O[3]+T04*O[4]+T54*O[5]-T88*O[6]+T82*O[7]-T38*O[8]-T22*O[9]+T73*O[10]-T90*O[11]+T67*O[12]-T13*O[13]-T46*O[14]+T85*O[15]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][27] <= `CLIP16((T22*O[0]-T61*O[1]+T85*O[2]-T90*O[3]+T73*O[4]-T38*O[5]-T04*O[6]+T46*O[7]-T78*O[8]+T90*O[9]-T82*O[10]+T54*O[11]-T13*O[12]-T31*O[13]+T67*O[14]-T88*O[15]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][29] <= `CLIP16((T13*O[0]-T38*O[1]+T61*O[2]-T78*O[3]+T88*O[4]-T90*O[5]+T85*O[6]-T73*O[7]+T54*O[8]-T31*O[9]+T04*O[10]+T22*O[11]-T46*O[12]+T67*O[13]-T82*O[14]+T90*O[15]+FWD_RND_1)>>>FWD_SHIFT_1);
                        stage1[r][31] <= `CLIP16((T04*O[0]-T13*O[1]+T22*O[2]-T31*O[3]+T38*O[4]-T46*O[5]+T54*O[6]-T61*O[7]+T67*O[8]-T73*O[9]+T78*O[10]-T82*O[11]+T85*O[12]-T88*O[13]+T90*O[14]-T90b*O[15]+FWD_RND_1)>>>FWD_SHIFT_1);
                    end

                end else begin
                    //----------------------------------------------------------
                    // INVERSE col pass — partialButterflyInverse32()
                    //----------------------------------------------------------
                    for (r = 0; r < 32; r = r + 1) begin : inv_col32
                        reg signed [IW-1:0] x [0:31];
                        reg signed [IW-1:0] O [0:15];
                        reg signed [IW-1:0] EO[0:7];
                        reg signed [IW-1:0] EEO[0:3];
                        reg signed [IW-1:0] EEEO[0:1];
                        reg signed [IW-1:0] EEEE[0:1];
                        reg signed [IW-1:0] EEE[0:3];
                        reg signed [IW-1:0] EE[0:7];
                        reg signed [IW-1:0] E [0:15];

                        // Read column r
                        x[0]=in_data_arr[0][r];  x[1]=in_data_arr[1][r];  x[2]=in_data_arr[2][r];  x[3]=in_data_arr[3][r];
                        x[4]=in_data_arr[4][r];  x[5]=in_data_arr[5][r];  x[6]=in_data_arr[6][r];  x[7]=in_data_arr[7][r];
                        x[8]=in_data_arr[8][r];  x[9]=in_data_arr[9][r];  x[10]=in_data_arr[10][r];x[11]=in_data_arr[11][r];
                        x[12]=in_data_arr[12][r];x[13]=in_data_arr[13][r];x[14]=in_data_arr[14][r];x[15]=in_data_arr[15][r];
                        x[16]=in_data_arr[16][r];x[17]=in_data_arr[17][r];x[18]=in_data_arr[18][r];x[19]=in_data_arr[19][r];
                        x[20]=in_data_arr[20][r];x[21]=in_data_arr[21][r];x[22]=in_data_arr[22][r];x[23]=in_data_arr[23][r];
                        x[24]=in_data_arr[24][r];x[25]=in_data_arr[25][r];x[26]=in_data_arr[26][r];x[27]=in_data_arr[27][r];
                        x[28]=in_data_arr[28][r];x[29]=in_data_arr[29][r];x[30]=in_data_arr[30][r];x[31]=in_data_arr[31][r];

                        // 16 odd outputs from odd-indexed rows
                        O[0] =T90*x[1]+T90b*x[3]+T88*x[5]+T85*x[7]+T82*x[9]+T78*x[11]+T73*x[13]+T67*x[15]+T61*x[17]+T54*x[19]+T46*x[21]+T38*x[23]+T31*x[25]+T22*x[27]+T13*x[29]+T04*x[31];
                        O[1] =T90*x[1]+T82*x[3]+T67*x[5]+T46*x[7]+T22*x[9]-T04*x[11]-T31*x[13]-T54*x[15]-T73*x[17]-T85*x[19]-T90*x[21]-T88*x[23]-T78*x[25]-T61*x[27]-T38*x[29]-T13*x[31];
                        O[2] =T88*x[1]+T67*x[3]+T31*x[5]-T13*x[7]-T54*x[9]-T82*x[11]-T90*x[13]-T78*x[15]-T46*x[17]-T04*x[19]+T38*x[21]+T73*x[23]+T90*x[25]+T85*x[27]+T61*x[29]+T22*x[31];
                        O[3] =T85*x[1]+T46*x[3]-T13*x[5]-T67*x[7]-T90*x[9]-T73*x[11]-T22*x[13]+T38*x[15]+T82*x[17]+T88*x[19]+T54*x[21]-T04*x[23]-T61*x[25]-T90*x[27]-T78*x[29]-T31*x[31];
                        O[4] =T82*x[1]+T22*x[3]-T54*x[5]-T90*x[7]-T61*x[9]+T13*x[11]+T78*x[13]+T85*x[15]+T31*x[17]-T46*x[19]-T90*x[21]-T67*x[23]+T04*x[25]+T73*x[27]+T88*x[29]+T38*x[31];
                        O[5] =T78*x[1]-T04*x[3]-T82*x[5]-T73*x[7]+T13*x[9]+T85*x[11]+T67*x[13]-T22*x[15]-T88*x[17]-T61*x[19]+T31*x[21]+T90*x[23]+T54*x[25]-T38*x[27]-T90*x[29]-T46*x[31];
                        O[6] =T73*x[1]-T31*x[3]-T90*x[5]-T22*x[7]+T78*x[9]+T67*x[11]-T38*x[13]-T90*x[15]-T13*x[17]+T82*x[19]+T61*x[21]-T46*x[23]-T88*x[25]-T04*x[27]+T85*x[29]+T54*x[31];
                        O[7] =T67*x[1]-T54*x[3]-T78*x[5]+T38*x[7]+T85*x[9]-T22*x[11]-T90*x[13]+T04*x[15]+T90*x[17]+T13*x[19]-T88*x[21]+T31*x[23]+T82*x[25]-T46*x[27]-T73*x[29]+T61*x[31];
                        O[8] =T61*x[1]-T73*x[3]-T46*x[5]+T82*x[7]+T31*x[9]-T88*x[11]-T13*x[13]+T90*x[15]-T04*x[17]-T90*x[19]+T22*x[21]+T85*x[23]-T38*x[25]-T78*x[27]+T54*x[29]+T67*x[31];
                        O[9] =T54*x[1]-T85*x[3]-T04*x[5]+T88*x[7]-T46*x[9]-T61*x[11]+T82*x[13]+T13*x[15]-T90*x[17]+T38*x[19]+T73*x[21]-T78*x[23]-T22*x[25]+T90*x[27]-T31*x[29]-T67*x[31];
                        O[10]=T46*x[1]-T90*x[3]+T38*x[5]+T54*x[7]-T90*x[9]+T31*x[11]+T61*x[13]-T88*x[15]+T22*x[17]+T67*x[19]-T85*x[21]+T13*x[23]+T73*x[25]-T82*x[27]+T04*x[29]+T78*x[31];
                        O[11]=T38*x[1]-T88*x[3]+T73*x[5]-T04*x[7]-T67*x[9]+T90*x[11]-T46*x[13]-T31*x[15]+T85*x[17]-T78*x[19]+T13*x[21]+T61*x[23]-T90*x[25]+T54*x[27]+T22*x[29]-T82*x[31];
                        O[12]=T31*x[1]-T78*x[3]+T90*x[5]-T61*x[7]+T04*x[9]+T54*x[11]-T88*x[13]+T82*x[15]-T38*x[17]-T22*x[19]+T73*x[21]-T90*x[23]+T67*x[25]-T13*x[27]-T46*x[29]+T85*x[31];
                        O[13]=T22*x[1]-T61*x[3]+T85*x[5]-T90*x[7]+T73*x[9]-T38*x[11]-T04*x[13]+T46*x[15]-T78*x[17]+T90*x[19]-T82*x[21]+T54*x[23]-T13*x[25]-T31*x[27]+T67*x[29]-T88*x[31];
                        O[14]=T13*x[1]-T38*x[3]+T61*x[5]-T78*x[7]+T88*x[9]-T90*x[11]+T85*x[13]-T73*x[15]+T54*x[17]-T31*x[19]+T04*x[21]+T22*x[23]-T46*x[25]+T67*x[27]-T82*x[29]+T90*x[31];
                        O[15]=T04*x[1]-T13*x[3]+T22*x[5]-T31*x[7]+T38*x[9]-T46*x[11]+T54*x[13]-T61*x[15]+T67*x[17]-T73*x[19]+T78*x[21]-T82*x[23]+T85*x[25]-T88*x[27]+T90*x[29]-T90b*x[31];

                        // EO from rows 2,6,10,14,18,22,26,30
                        EO[0]=T90*x[2]+T87*x[6]+T80*x[10]+T70*x[14]+T57*x[18]+T43*x[22]+T25*x[26]+T09*x[30];
                        EO[1]=T87*x[2]+T57*x[6]+T09*x[10]-T43*x[14]-T80*x[18]-T90*x[22]-T70*x[26]-T25*x[30];
                        EO[2]=T80*x[2]+T09*x[6]-T70*x[10]-T87*x[14]-T25*x[18]+T57*x[22]+T90*x[26]+T43*x[30];
                        EO[3]=T70*x[2]-T43*x[6]-T87*x[10]+T09*x[14]+T90*x[18]+T25*x[22]-T80*x[26]-T57*x[30];
                        EO[4]=T57*x[2]-T80*x[6]-T25*x[10]+T90*x[14]-T09*x[18]-T87*x[22]+T43*x[26]+T70*x[30];
                        EO[5]=T43*x[2]-T90*x[6]+T57*x[10]+T25*x[14]-T87*x[18]+T70*x[22]+T09*x[26]-T80*x[30];
                        EO[6]=T25*x[2]-T70*x[6]+T90*x[10]-T80*x[14]+T43*x[18]+T09*x[22]-T57*x[26]+T87*x[30];
                        EO[7]=T09*x[2]-T25*x[6]+T43*x[10]-T57*x[14]+T70*x[18]-T80*x[22]+T87*x[26]-T90*x[30];

                        // EEO from rows 4,12,20,28
                        EEO[0]=T89*x[4]+T75*x[12]+T50*x[20]+T18*x[28];
                        EEO[1]=T75*x[4]-T18*x[12]-T89*x[20]-T50*x[28];
                        EEO[2]=T50*x[4]-T89*x[12]+T18*x[20]+T75*x[28];
                        EEO[3]=T18*x[4]-T50*x[12]+T75*x[20]-T89*x[28];

                        // EEEO from rows 8,24
                        EEEO[0]=T83*x[8]+T36*x[24];
                        EEEO[1]=T36*x[8]-T83*x[24];

                        // EEEE from rows 0,16
                        EEEE[0]=T64*x[0]+T64*x[16];
                        EEEE[1]=T64*x[0]-T64*x[16];

                        // Reconstruct EEE, EE, E
                        EEE[0]=EEEE[0]+EEEO[0]; EEE[1]=EEEE[1]+EEEO[1];
                        EEE[2]=EEEE[1]-EEEO[1]; EEE[3]=EEEE[0]-EEEO[0];

                        EE[0]=EEE[0]+EEO[0]; EE[1]=EEE[1]+EEO[1]; EE[2]=EEE[2]+EEO[2]; EE[3]=EEE[3]+EEO[3];
                        EE[4]=EEE[3]-EEO[3]; EE[5]=EEE[2]-EEO[2]; EE[6]=EEE[1]-EEO[1]; EE[7]=EEE[0]-EEO[0];

                        E[0]=EE[0]+EO[0];  E[1]=EE[1]+EO[1];  E[2]=EE[2]+EO[2];  E[3]=EE[3]+EO[3];
                        E[4]=EE[4]+EO[4];  E[5]=EE[5]+EO[5];  E[6]=EE[6]+EO[6];  E[7]=EE[7]+EO[7];
                        E[8]=EE[7]-EO[7];  E[9]=EE[6]-EO[6];  E[10]=EE[5]-EO[5]; E[11]=EE[4]-EO[4];
                        E[12]=EE[3]-EO[3]; E[13]=EE[2]-EO[2]; E[14]=EE[1]-EO[1]; E[15]=EE[0]-EO[0];

                        // Combine E+O, shift, clip
                        stage1[r][0]  <= `CLIP16((E[0] +O[0] +INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][1]  <= `CLIP16((E[1] +O[1] +INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][2]  <= `CLIP16((E[2] +O[2] +INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][3]  <= `CLIP16((E[3] +O[3] +INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][4]  <= `CLIP16((E[4] +O[4] +INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][5]  <= `CLIP16((E[5] +O[5] +INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][6]  <= `CLIP16((E[6] +O[6] +INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][7]  <= `CLIP16((E[7] +O[7] +INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][8]  <= `CLIP16((E[8] +O[8] +INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][9]  <= `CLIP16((E[9] +O[9] +INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][10] <= `CLIP16((E[10]+O[10]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][11] <= `CLIP16((E[11]+O[11]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][12] <= `CLIP16((E[12]+O[12]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][13] <= `CLIP16((E[13]+O[13]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][14] <= `CLIP16((E[14]+O[14]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][15] <= `CLIP16((E[15]+O[15]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][16] <= `CLIP16((E[15]-O[15]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][17] <= `CLIP16((E[14]-O[14]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][18] <= `CLIP16((E[13]-O[13]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][19] <= `CLIP16((E[12]-O[12]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][20] <= `CLIP16((E[11]-O[11]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][21] <= `CLIP16((E[10]-O[10]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][22] <= `CLIP16((E[9] -O[9] +INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][23] <= `CLIP16((E[8] -O[8] +INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][24] <= `CLIP16((E[7] -O[7] +INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][25] <= `CLIP16((E[6] -O[6] +INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][26] <= `CLIP16((E[5] -O[5] +INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][27] <= `CLIP16((E[4] -O[4] +INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][28] <= `CLIP16((E[3] -O[3] +INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][29] <= `CLIP16((E[2] -O[2] +INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][30] <= `CLIP16((E[1] -O[1] +INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][31] <= `CLIP16((E[0] -O[0] +INV_RND_1)>>>INV_SHIFT_1);
                    end
                end
            end
        end
    end

    //=========================================================================
    // STAGE 2 — Col pass (fwd) / Row pass (inv)
    // Identical butterfly structure to Stage 1 — operates on stage1 array
    //=========================================================================
    integer c;

    always @(posedge clk) begin : stage2_proc
        integer k;
        if (!rst_n) begin
            out_valid <= 1'b0;
            for (c = 0; c < 32; c = c + 1)
                for (k = 0; k < 32; k = k + 1)
                    out_data_arr[c][k] <= {`COEFF_WIDTH{1'b0}};
        end else if (!out_ready) begin
            out_valid <= out_valid;
        end else begin
            out_valid <= stage1_valid;

            if (stage1_valid) begin
                if (fwd_inv_n_s1) begin
                    //----------------------------------------------------------
                    // FORWARD col pass — same butterfly on stage1 columns
                    //----------------------------------------------------------
                    for (c = 0; c < 32; c = c + 1) begin : fwd_col32
                        reg signed [IW-1:0] E [0:15];
                        reg signed [IW-1:0] O [0:15];
                        reg signed [IW-1:0] EE[0:7];
                        reg signed [IW-1:0] EO[0:7];
                        reg signed [IW-1:0] EEE[0:3];
                        reg signed [IW-1:0] EEO[0:3];
                        reg signed [IW-1:0] EEEE[0:1];
                        reg signed [IW-1:0] EEEO[0:1];

                        E[0]=stage1[0][c]+stage1[31][c];  E[1]=stage1[1][c]+stage1[30][c];
                        E[2]=stage1[2][c]+stage1[29][c];  E[3]=stage1[3][c]+stage1[28][c];
                        E[4]=stage1[4][c]+stage1[27][c];  E[5]=stage1[5][c]+stage1[26][c];
                        E[6]=stage1[6][c]+stage1[25][c];  E[7]=stage1[7][c]+stage1[24][c];
                        E[8]=stage1[8][c]+stage1[23][c];  E[9]=stage1[9][c]+stage1[22][c];
                        E[10]=stage1[10][c]+stage1[21][c];E[11]=stage1[11][c]+stage1[20][c];
                        E[12]=stage1[12][c]+stage1[19][c];E[13]=stage1[13][c]+stage1[18][c];
                        E[14]=stage1[14][c]+stage1[17][c];E[15]=stage1[15][c]+stage1[16][c];
                        O[0]=stage1[0][c]-stage1[31][c];  O[1]=stage1[1][c]-stage1[30][c];
                        O[2]=stage1[2][c]-stage1[29][c];  O[3]=stage1[3][c]-stage1[28][c];
                        O[4]=stage1[4][c]-stage1[27][c];  O[5]=stage1[5][c]-stage1[26][c];
                        O[6]=stage1[6][c]-stage1[25][c];  O[7]=stage1[7][c]-stage1[24][c];
                        O[8]=stage1[8][c]-stage1[23][c];  O[9]=stage1[9][c]-stage1[22][c];
                        O[10]=stage1[10][c]-stage1[21][c];O[11]=stage1[11][c]-stage1[20][c];
                        O[12]=stage1[12][c]-stage1[19][c];O[13]=stage1[13][c]-stage1[18][c];
                        O[14]=stage1[14][c]-stage1[17][c];O[15]=stage1[15][c]-stage1[16][c];

                        EE[0]=E[0]+E[15]; EE[1]=E[1]+E[14]; EE[2]=E[2]+E[13]; EE[3]=E[3]+E[12];
                        EE[4]=E[4]+E[11]; EE[5]=E[5]+E[10]; EE[6]=E[6]+E[9];  EE[7]=E[7]+E[8];
                        EO[0]=E[0]-E[15]; EO[1]=E[1]-E[14]; EO[2]=E[2]-E[13]; EO[3]=E[3]-E[12];
                        EO[4]=E[4]-E[11]; EO[5]=E[5]-E[10]; EO[6]=E[6]-E[9];  EO[7]=E[7]-E[8];

                        EEE[0]=EE[0]+EE[7]; EEE[1]=EE[1]+EE[6]; EEE[2]=EE[2]+EE[5]; EEE[3]=EE[3]+EE[4];
                        EEO[0]=EE[0]-EE[7]; EEO[1]=EE[1]-EE[6]; EEO[2]=EE[2]-EE[5]; EEO[3]=EE[3]-EE[4];

                        EEEE[0]=EEE[0]+EEE[3]; EEEE[1]=EEE[1]+EEE[2];
                        EEEO[0]=EEE[0]-EEE[3]; EEEO[1]=EEE[1]-EEE[2];

                        out_data_arr[0][c]  <= `CLIP16((T64*EEEE[0]+T64*EEEE[1]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[16][c] <= `CLIP16((T64*EEEE[0]-T64*EEEE[1]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[8][c]  <= `CLIP16((T83*EEEO[0]+T36*EEEO[1]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[24][c] <= `CLIP16((T36*EEEO[0]-T83*EEEO[1]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[4][c]  <= `CLIP16((T89*EEO[0]+T75*EEO[1]+T50*EEO[2]+T18*EEO[3]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[12][c] <= `CLIP16((T75*EEO[0]-T18*EEO[1]-T89*EEO[2]-T50*EEO[3]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[20][c] <= `CLIP16((T50*EEO[0]-T89*EEO[1]+T18*EEO[2]+T75*EEO[3]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[28][c] <= `CLIP16((T18*EEO[0]-T50*EEO[1]+T75*EEO[2]-T89*EEO[3]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[2][c]  <= `CLIP16((T90*EO[0]+T87*EO[1]+T80*EO[2]+T70*EO[3]+T57*EO[4]+T43*EO[5]+T25*EO[6]+T09*EO[7]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[6][c]  <= `CLIP16((T87*EO[0]+T57*EO[1]+T09*EO[2]-T43*EO[3]-T80*EO[4]-T90*EO[5]-T70*EO[6]-T25*EO[7]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[10][c] <= `CLIP16((T80*EO[0]+T09*EO[1]-T70*EO[2]-T87*EO[3]-T25*EO[4]+T57*EO[5]+T90*EO[6]+T43*EO[7]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[14][c] <= `CLIP16((T70*EO[0]-T43*EO[1]-T87*EO[2]+T09*EO[3]+T90*EO[4]+T25*EO[5]-T80*EO[6]-T57*EO[7]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[18][c] <= `CLIP16((T57*EO[0]-T80*EO[1]-T25*EO[2]+T90*EO[3]-T09*EO[4]-T87*EO[5]+T43*EO[6]+T70*EO[7]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[22][c] <= `CLIP16((T43*EO[0]-T90*EO[1]+T57*EO[2]+T25*EO[3]-T87*EO[4]+T70*EO[5]+T09*EO[6]-T80*EO[7]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[26][c] <= `CLIP16((T25*EO[0]-T70*EO[1]+T90*EO[2]-T80*EO[3]+T43*EO[4]+T09*EO[5]-T57*EO[6]+T87*EO[7]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[30][c] <= `CLIP16((T09*EO[0]-T25*EO[1]+T43*EO[2]-T57*EO[3]+T70*EO[4]-T80*EO[5]+T87*EO[6]-T90*EO[7]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[1][c]  <= `CLIP16((T90*O[0]+T90b*O[1]+T88*O[2]+T85*O[3]+T82*O[4]+T78*O[5]+T73*O[6]+T67*O[7]+T61*O[8]+T54*O[9]+T46*O[10]+T38*O[11]+T31*O[12]+T22*O[13]+T13*O[14]+T04*O[15]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[3][c]  <= `CLIP16((T90*O[0]+T82*O[1]+T67*O[2]+T46*O[3]+T22*O[4]-T04*O[5]-T31*O[6]-T54*O[7]-T73*O[8]-T85*O[9]-T90*O[10]-T88*O[11]-T78*O[12]-T61*O[13]-T38*O[14]-T13*O[15]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[5][c]  <= `CLIP16((T88*O[0]+T67*O[1]+T31*O[2]-T13*O[3]-T54*O[4]-T82*O[5]-T90*O[6]-T78*O[7]-T46*O[8]-T04*O[9]+T38*O[10]+T73*O[11]+T90*O[12]+T85*O[13]+T61*O[14]+T22*O[15]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[7][c]  <= `CLIP16((T85*O[0]+T46*O[1]-T13*O[2]-T67*O[3]-T90*O[4]-T73*O[5]-T22*O[6]+T38*O[7]+T82*O[8]+T88*O[9]+T54*O[10]-T04*O[11]-T61*O[12]-T90*O[13]-T78*O[14]-T31*O[15]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[9][c]  <= `CLIP16((T82*O[0]+T22*O[1]-T54*O[2]-T90*O[3]-T61*O[4]+T13*O[5]+T78*O[6]+T85*O[7]+T31*O[8]-T46*O[9]-T90*O[10]-T67*O[11]+T04*O[12]+T73*O[13]+T88*O[14]+T38*O[15]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[11][c] <= `CLIP16((T78*O[0]-T04*O[1]-T82*O[2]-T73*O[3]+T13*O[4]+T85*O[5]+T67*O[6]-T22*O[7]-T88*O[8]-T61*O[9]+T31*O[10]+T90*O[11]+T54*O[12]-T38*O[13]-T90*O[14]-T46*O[15]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[13][c] <= `CLIP16((T73*O[0]-T31*O[1]-T90*O[2]-T22*O[3]+T78*O[4]+T67*O[5]-T38*O[6]-T90*O[7]-T13*O[8]+T82*O[9]+T61*O[10]-T46*O[11]-T88*O[12]-T04*O[13]+T85*O[14]+T54*O[15]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[15][c] <= `CLIP16((T67*O[0]-T54*O[1]-T78*O[2]+T38*O[3]+T85*O[4]-T22*O[5]-T90*O[6]+T04*O[7]+T90*O[8]+T13*O[9]-T88*O[10]+T31*O[11]+T82*O[12]-T46*O[13]-T73*O[14]+T61*O[15]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[17][c] <= `CLIP16((T61*O[0]-T73*O[1]-T46*O[2]+T82*O[3]+T31*O[4]-T88*O[5]-T13*O[6]+T90*O[7]-T04*O[8]-T90*O[9]+T22*O[10]+T85*O[11]-T38*O[12]-T78*O[13]+T54*O[14]+T67*O[15]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[19][c] <= `CLIP16((T54*O[0]-T85*O[1]-T04*O[2]+T88*O[3]-T46*O[4]-T61*O[5]+T82*O[6]+T13*O[7]-T90*O[8]+T38*O[9]+T73*O[10]-T78*O[11]-T22*O[12]+T90*O[13]-T31*O[14]-T67*O[15]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[21][c] <= `CLIP16((T46*O[0]-T90*O[1]+T38*O[2]+T54*O[3]-T90*O[4]+T31*O[5]+T61*O[6]-T88*O[7]+T22*O[8]+T67*O[9]-T85*O[10]+T13*O[11]+T73*O[12]-T82*O[13]+T04*O[14]+T78*O[15]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[23][c] <= `CLIP16((T38*O[0]-T88*O[1]+T73*O[2]-T04*O[3]-T67*O[4]+T90*O[5]-T46*O[6]-T31*O[7]+T85*O[8]-T78*O[9]+T13*O[10]+T61*O[11]-T90*O[12]+T54*O[13]+T22*O[14]-T82*O[15]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[25][c] <= `CLIP16((T31*O[0]-T78*O[1]+T90*O[2]-T61*O[3]+T04*O[4]+T54*O[5]-T88*O[6]+T82*O[7]-T38*O[8]-T22*O[9]+T73*O[10]-T90*O[11]+T67*O[12]-T13*O[13]-T46*O[14]+T85*O[15]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[27][c] <= `CLIP16((T22*O[0]-T61*O[1]+T85*O[2]-T90*O[3]+T73*O[4]-T38*O[5]-T04*O[6]+T46*O[7]-T78*O[8]+T90*O[9]-T82*O[10]+T54*O[11]-T13*O[12]-T31*O[13]+T67*O[14]-T88*O[15]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[29][c] <= `CLIP16((T13*O[0]-T38*O[1]+T61*O[2]-T78*O[3]+T88*O[4]-T90*O[5]+T85*O[6]-T73*O[7]+T54*O[8]-T31*O[9]+T04*O[10]+T22*O[11]-T46*O[12]+T67*O[13]-T82*O[14]+T90*O[15]+FWD_RND_2)>>>FWD_SHIFT_2);
                        out_data_arr[31][c] <= `CLIP16((T04*O[0]-T13*O[1]+T22*O[2]-T31*O[3]+T38*O[4]-T46*O[5]+T54*O[6]-T61*O[7]+T67*O[8]-T73*O[9]+T78*O[10]-T82*O[11]+T85*O[12]-T88*O[13]+T90*O[14]-T90b*O[15]+FWD_RND_2)>>>FWD_SHIFT_2);
                    end

                end else begin
                    //----------------------------------------------------------
                    // INVERSE row pass — same butterfly on stage1 rows
                    //----------------------------------------------------------
                    for (r = 0; r < 32; r = r + 1) begin : inv_row32
                        reg signed [IW-1:0] x [0:31];
                        reg signed [IW-1:0] O [0:15];
                        reg signed [IW-1:0] EO[0:7];
                        reg signed [IW-1:0] EEO[0:3];
                        reg signed [IW-1:0] EEEO[0:1];
                        reg signed [IW-1:0] EEEE[0:1];
                        reg signed [IW-1:0] EEE[0:3];
                        reg signed [IW-1:0] EE[0:7];
                        reg signed [IW-1:0] E [0:15];

                        x[0]=stage1[0][r];  x[1]=stage1[1][r];  x[2]=stage1[2][r];  x[3]=stage1[3][r];
                        x[4]=stage1[4][r];  x[5]=stage1[5][r];  x[6]=stage1[6][r];  x[7]=stage1[7][r];
                        x[8]=stage1[8][r];  x[9]=stage1[9][r];  x[10]=stage1[10][r];x[11]=stage1[11][r];
                        x[12]=stage1[12][r];x[13]=stage1[13][r];x[14]=stage1[14][r];x[15]=stage1[15][r];
                        x[16]=stage1[16][r];x[17]=stage1[17][r];x[18]=stage1[18][r];x[19]=stage1[19][r];
                        x[20]=stage1[20][r];x[21]=stage1[21][r];x[22]=stage1[22][r];x[23]=stage1[23][r];
                        x[24]=stage1[24][r];x[25]=stage1[25][r];x[26]=stage1[26][r];x[27]=stage1[27][r];
                        x[28]=stage1[28][r];x[29]=stage1[29][r];x[30]=stage1[30][r];x[31]=stage1[31][r];

                        O[0] =T90*x[1]+T90b*x[3]+T88*x[5]+T85*x[7]+T82*x[9]+T78*x[11]+T73*x[13]+T67*x[15]+T61*x[17]+T54*x[19]+T46*x[21]+T38*x[23]+T31*x[25]+T22*x[27]+T13*x[29]+T04*x[31];
                        O[1] =T90*x[1]+T82*x[3]+T67*x[5]+T46*x[7]+T22*x[9]-T04*x[11]-T31*x[13]-T54*x[15]-T73*x[17]-T85*x[19]-T90*x[21]-T88*x[23]-T78*x[25]-T61*x[27]-T38*x[29]-T13*x[31];
                        O[2] =T88*x[1]+T67*x[3]+T31*x[5]-T13*x[7]-T54*x[9]-T82*x[11]-T90*x[13]-T78*x[15]-T46*x[17]-T04*x[19]+T38*x[21]+T73*x[23]+T90*x[25]+T85*x[27]+T61*x[29]+T22*x[31];
                        O[3] =T85*x[1]+T46*x[3]-T13*x[5]-T67*x[7]-T90*x[9]-T73*x[11]-T22*x[13]+T38*x[15]+T82*x[17]+T88*x[19]+T54*x[21]-T04*x[23]-T61*x[25]-T90*x[27]-T78*x[29]-T31*x[31];
                        O[4] =T82*x[1]+T22*x[3]-T54*x[5]-T90*x[7]-T61*x[9]+T13*x[11]+T78*x[13]+T85*x[15]+T31*x[17]-T46*x[19]-T90*x[21]-T67*x[23]+T04*x[25]+T73*x[27]+T88*x[29]+T38*x[31];
                        O[5] =T78*x[1]-T04*x[3]-T82*x[5]-T73*x[7]+T13*x[9]+T85*x[11]+T67*x[13]-T22*x[15]-T88*x[17]-T61*x[19]+T31*x[21]+T90*x[23]+T54*x[25]-T38*x[27]-T90*x[29]-T46*x[31];
                        O[6] =T73*x[1]-T31*x[3]-T90*x[5]-T22*x[7]+T78*x[9]+T67*x[11]-T38*x[13]-T90*x[15]-T13*x[17]+T82*x[19]+T61*x[21]-T46*x[23]-T88*x[25]-T04*x[27]+T85*x[29]+T54*x[31];
                        O[7] =T67*x[1]-T54*x[3]-T78*x[5]+T38*x[7]+T85*x[9]-T22*x[11]-T90*x[13]+T04*x[15]+T90*x[17]+T13*x[19]-T88*x[21]+T31*x[23]+T82*x[25]-T46*x[27]-T73*x[29]+T61*x[31];
                        O[8] =T61*x[1]-T73*x[3]-T46*x[5]+T82*x[7]+T31*x[9]-T88*x[11]-T13*x[13]+T90*x[15]-T04*x[17]-T90*x[19]+T22*x[21]+T85*x[23]-T38*x[25]-T78*x[27]+T54*x[29]+T67*x[31];
                        O[9] =T54*x[1]-T85*x[3]-T04*x[5]+T88*x[7]-T46*x[9]-T61*x[11]+T82*x[13]+T13*x[15]-T90*x[17]+T38*x[19]+T73*x[21]-T78*x[23]-T22*x[25]+T90*x[27]-T31*x[29]-T67*x[31];
                        O[10]=T46*x[1]-T90*x[3]+T38*x[5]+T54*x[7]-T90*x[9]+T31*x[11]+T61*x[13]-T88*x[15]+T22*x[17]+T67*x[19]-T85*x[21]+T13*x[23]+T73*x[25]-T82*x[27]+T04*x[29]+T78*x[31];
                        O[11]=T38*x[1]-T88*x[3]+T73*x[5]-T04*x[7]-T67*x[9]+T90*x[11]-T46*x[13]-T31*x[15]+T85*x[17]-T78*x[19]+T13*x[21]+T61*x[23]-T90*x[25]+T54*x[27]+T22*x[29]-T82*x[31];
                        O[12]=T31*x[1]-T78*x[3]+T90*x[5]-T61*x[7]+T04*x[9]+T54*x[11]-T88*x[13]+T82*x[15]-T38*x[17]-T22*x[19]+T73*x[21]-T90*x[23]+T67*x[25]-T13*x[27]-T46*x[29]+T85*x[31];
                        O[13]=T22*x[1]-T61*x[3]+T85*x[5]-T90*x[7]+T73*x[9]-T38*x[11]-T04*x[13]+T46*x[15]-T78*x[17]+T90*x[19]-T82*x[21]+T54*x[23]-T13*x[25]-T31*x[27]+T67*x[29]-T88*x[31];
                        O[14]=T13*x[1]-T38*x[3]+T61*x[5]-T78*x[7]+T88*x[9]-T90*x[11]+T85*x[13]-T73*x[15]+T54*x[17]-T31*x[19]+T04*x[21]+T22*x[23]-T46*x[25]+T67*x[27]-T82*x[29]+T90*x[31];
                        O[15]=T04*x[1]-T13*x[3]+T22*x[5]-T31*x[7]+T38*x[9]-T46*x[11]+T54*x[13]-T61*x[15]+T67*x[17]-T73*x[19]+T78*x[21]-T82*x[23]+T85*x[25]-T88*x[27]+T90*x[29]-T90b*x[31];

                        EO[0]=T90*x[2]+T87*x[6]+T80*x[10]+T70*x[14]+T57*x[18]+T43*x[22]+T25*x[26]+T09*x[30];
                        EO[1]=T87*x[2]+T57*x[6]+T09*x[10]-T43*x[14]-T80*x[18]-T90*x[22]-T70*x[26]-T25*x[30];
                        EO[2]=T80*x[2]+T09*x[6]-T70*x[10]-T87*x[14]-T25*x[18]+T57*x[22]+T90*x[26]+T43*x[30];
                        EO[3]=T70*x[2]-T43*x[6]-T87*x[10]+T09*x[14]+T90*x[18]+T25*x[22]-T80*x[26]-T57*x[30];
                        EO[4]=T57*x[2]-T80*x[6]-T25*x[10]+T90*x[14]-T09*x[18]-T87*x[22]+T43*x[26]+T70*x[30];
                        EO[5]=T43*x[2]-T90*x[6]+T57*x[10]+T25*x[14]-T87*x[18]+T70*x[22]+T09*x[26]-T80*x[30];
                        EO[6]=T25*x[2]-T70*x[6]+T90*x[10]-T80*x[14]+T43*x[18]+T09*x[22]-T57*x[26]+T87*x[30];
                        EO[7]=T09*x[2]-T25*x[6]+T43*x[10]-T57*x[14]+T70*x[18]-T80*x[22]+T87*x[26]-T90*x[30];

                        EEO[0]=T89*x[4]+T75*x[12]+T50*x[20]+T18*x[28];
                        EEO[1]=T75*x[4]-T18*x[12]-T89*x[20]-T50*x[28];
                        EEO[2]=T50*x[4]-T89*x[12]+T18*x[20]+T75*x[28];
                        EEO[3]=T18*x[4]-T50*x[12]+T75*x[20]-T89*x[28];

                        EEEO[0]=T83*x[8]+T36*x[24];
                        EEEO[1]=T36*x[8]-T83*x[24];
                        EEEE[0]=T64*x[0]+T64*x[16];
                        EEEE[1]=T64*x[0]-T64*x[16];

                        EEE[0]=EEEE[0]+EEEO[0]; EEE[1]=EEEE[1]+EEEO[1];
                        EEE[2]=EEEE[1]-EEEO[1]; EEE[3]=EEEE[0]-EEEO[0];

                        EE[0]=EEE[0]+EEO[0]; EE[1]=EEE[1]+EEO[1]; EE[2]=EEE[2]+EEO[2]; EE[3]=EEE[3]+EEO[3];
                        EE[4]=EEE[3]-EEO[3]; EE[5]=EEE[2]-EEO[2]; EE[6]=EEE[1]-EEO[1]; EE[7]=EEE[0]-EEO[0];

                        E[0]=EE[0]+EO[0];  E[1]=EE[1]+EO[1];  E[2]=EE[2]+EO[2];  E[3]=EE[3]+EO[3];
                        E[4]=EE[4]+EO[4];  E[5]=EE[5]+EO[5];  E[6]=EE[6]+EO[6];  E[7]=EE[7]+EO[7];
                        E[8]=EE[7]-EO[7];  E[9]=EE[6]-EO[6];  E[10]=EE[5]-EO[5]; E[11]=EE[4]-EO[4];
                        E[12]=EE[3]-EO[3]; E[13]=EE[2]-EO[2]; E[14]=EE[1]-EO[1]; E[15]=EE[0]-EO[0];

                        out_data_arr[r][0]  <= `CLIP16((E[0] +O[0] +INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][1]  <= `CLIP16((E[1] +O[1] +INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][2]  <= `CLIP16((E[2] +O[2] +INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][3]  <= `CLIP16((E[3] +O[3] +INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][4]  <= `CLIP16((E[4] +O[4] +INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][5]  <= `CLIP16((E[5] +O[5] +INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][6]  <= `CLIP16((E[6] +O[6] +INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][7]  <= `CLIP16((E[7] +O[7] +INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][8]  <= `CLIP16((E[8] +O[8] +INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][9]  <= `CLIP16((E[9] +O[9] +INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][10] <= `CLIP16((E[10]+O[10]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][11] <= `CLIP16((E[11]+O[11]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][12] <= `CLIP16((E[12]+O[12]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][13] <= `CLIP16((E[13]+O[13]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][14] <= `CLIP16((E[14]+O[14]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][15] <= `CLIP16((E[15]+O[15]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][16] <= `CLIP16((E[15]-O[15]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][17] <= `CLIP16((E[14]-O[14]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][18] <= `CLIP16((E[13]-O[13]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][19] <= `CLIP16((E[12]-O[12]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][20] <= `CLIP16((E[11]-O[11]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][21] <= `CLIP16((E[10]-O[10]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][22] <= `CLIP16((E[9] -O[9] +INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][23] <= `CLIP16((E[8] -O[8] +INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][24] <= `CLIP16((E[7] -O[7] +INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][25] <= `CLIP16((E[6] -O[6] +INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][26] <= `CLIP16((E[5] -O[5] +INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][27] <= `CLIP16((E[4] -O[4] +INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][28] <= `CLIP16((E[3] -O[3] +INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][29] <= `CLIP16((E[2] -O[2] +INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][30] <= `CLIP16((E[1] -O[1] +INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][31] <= `CLIP16((E[0] -O[0] +INV_RND_2)>>>INV_SHIFT_2);
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
            $display("INFO  [dct32] input stalled at time=%0t", $time);
    end
    integer check32_done;
    initial check32_done = 0;
    always @(posedge clk) begin
        if (rst_n && out_valid && fwd_inv_n_s1 && !check32_done) begin
            $display("INFO  [dct32] first fwd output [0][0]=%0d [1][0]=%0d",
                     out_data_arr[0][0], out_data_arr[1][0]);
            check32_done = 1;
        end
    end
    // synthesis translate_on

    `undef CLIP16

endmodule