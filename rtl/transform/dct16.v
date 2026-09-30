//=============================================================================
// dct16.v
// 16x16 Integer DCT — Forward and Inverse
//
// Mapped from HM source:
//   TLibCommon/TComTrQuant.cpp
//   void partialButterfly16()        — forward 16x16
//   void partialButterflyInverse16() — inverse 16x16
//
// HEVC integer DCT-II 16x16 basis coefficients (spec Table 9-15):
//   Even rows reuse DCT-8 values:
//     T64, T83, T36, T89, T75, T50, T18
//   Odd rows (new for 16-point):
//     T90, T87, T80, T70, T57, T43, T25, T09
//
// HM butterfly decomposition (partialButterfly16):
//   E[0..7]  = src[k] + src[15-k]   for k=0..7   (even sums)
//   O[0..7]  = src[k] - src[15-k]   for k=0..7   (odd diffs)
//   EE[0..3] = E[k] + E[7-k]        for k=0..3   (even-even)
//   EO[0..3] = E[k] - E[7-k]        for k=0..3   (even-odd)
//   Then DCT-8 on EE/EO → 8 even outputs
//        8 odd outputs from O[0..7] via 8-point odd butterfly
//
// Shift values (HM, 10-bit):
//   g_aucConvertToBit[16] = 2
//   Forward:
//     shift_1st = 2+1+10-8 = 5
//     shift_2nd = 2+8      = 10
//   Inverse:
//     shift_1st = 7
//     shift_2nd = 12 - max(10-8,0) = 10
//
// Intermediate width:
//   O[k] max = 2*32767 = 65534
//   Basis coeff max = 90
//   Sum of 8 products = 8 * 90 * 65534 ≈ 47.2M → 26-bit
//   Use IW=32 (matches HM Int = int32_t)
//
// Pipeline: 2-stage, 2-cycle latency, fwd_inv_n pipelined through stage1
//=============================================================================

`include "parameter_pkg.vh"

module dct16 (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         fwd_inv_n,

    input  wire         in_valid,
    output wire         in_ready,
    input  wire [4095:0] in_data,

    output reg          out_valid,
    input  wire         out_ready,
    output wire [4095:0] out_data
);

    wire signed [`COEFF_WIDTH-1:0] in_data_arr [0:15][0:15];
    reg  signed [`COEFF_WIDTH-1:0] out_data_arr [0:15][0:15];

    genvar gi, gj;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : gen_flat
            for (gj = 0; gj < 16; gj = gj + 1) begin : gen_flat_col
                assign in_data_arr[gi][gj] = in_data[(gi*16+gj)*16 +: 16];
                assign out_data[(gi*16+gj)*16 +: 16] = out_data_arr[gi][gj];
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // DCT-16 basis coefficients (HEVC spec Table 9-15)
    // All values ≤ 90, fit in 8-bit signed (max 127)
    //-------------------------------------------------------------------------
    // Shared with DCT-8
    localparam signed [7:0] T64 = 8'sd64;
    localparam signed [7:0] T83 = 8'sd83;
    localparam signed [7:0] T36 = 8'sd36;
    localparam signed [7:0] T89 = 8'sd89;
    localparam signed [7:0] T75 = 8'sd75;
    localparam signed [7:0] T50 = 8'sd50;
    localparam signed [7:0] T18 = 8'sd18;
    // New for 16-point odd butterfly
    localparam signed [7:0] T90 = 8'sd90;
    localparam signed [7:0] T87 = 8'sd87;
    localparam signed [7:0] T80 = 8'sd80;
    localparam signed [7:0] T70 = 8'sd70;
    localparam signed [7:0] T57 = 8'sd57;
    localparam signed [7:0] T43 = 8'sd43;
    localparam signed [7:0] T25 = 8'sd25;
    localparam signed [7:0] T09 = 8'sd9;

    //-------------------------------------------------------------------------
    // Shift/round constants
    //-------------------------------------------------------------------------
    localparam FWD_SHIFT_1 = 5;
    localparam FWD_SHIFT_2 = 10;
    localparam INV_SHIFT_1 = 7;
    localparam BIT_DEPTH_ADJ = (`BIT_DEPTH > 8) ? (`BIT_DEPTH - 8) : 0;
    localparam INV_SHIFT_2   = 12 - BIT_DEPTH_ADJ;      // 10 for 10-bit

    localparam FWD_RND_1 = (1 << (FWD_SHIFT_1 - 1));   // 16
    localparam FWD_RND_2 = (1 << (FWD_SHIFT_2 - 1));   // 512
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
    // Stage 1 registers
    //-------------------------------------------------------------------------
    reg signed [`COEFF_WIDTH-1:0] stage1 [0:15][0:15];
    reg                            stage1_valid;
    reg                            fwd_inv_n_s1;

    wire stall = stage1_valid && !out_ready;
    assign in_ready = !stall;

    //=========================================================================
    // STAGE 1 — Row pass (fwd) / Col pass (inv)
    //=========================================================================
    integer r;

    always @(posedge clk) begin : stage1_proc
        integer k;
        if (!rst_n) begin
            stage1_valid <= 1'b0;
            fwd_inv_n_s1 <= 1'b0;
            for (r = 0; r < 16; r = r + 1)
                for (k = 0; k < 16; k = k + 1)
                    stage1[r][k] <= {`COEFF_WIDTH{1'b0}};
        end else if (!stall) begin
            stage1_valid <= in_valid;
            fwd_inv_n_s1 <= fwd_inv_n;

            if (in_valid) begin
                if (fwd_inv_n) begin
                    //----------------------------------------------------------
                    // FORWARD row pass — partialButterfly16()
                    //----------------------------------------------------------
                    for (r = 0; r < 16; r = r + 1) begin : fwd_row16
                        reg signed [IW-1:0] E [0:7];
                        reg signed [IW-1:0] O [0:7];
                        reg signed [IW-1:0] EE[0:3];
                        reg signed [IW-1:0] EO[0:3];
                        reg signed [IW-1:0] EEE[0:1];
                        reg signed [IW-1:0] EEO[0:1];

                        // Even/odd decomposition
                    E[0] = in_data_arr[r][0]  + in_data_arr[r][15];
                    E[1] = in_data_arr[r][1]  + in_data_arr[r][14];
                    E[2] = in_data_arr[r][2]  + in_data_arr[r][13];
                    E[3] = in_data_arr[r][3]  + in_data_arr[r][12];
                    E[4] = in_data_arr[r][4]  + in_data_arr[r][11];
                    E[5] = in_data_arr[r][5]  + in_data_arr[r][10];
                    E[6] = in_data_arr[r][6]  + in_data_arr[r][9];
                    E[7] = in_data_arr[r][7]  + in_data_arr[r][8];
                    O[0] = in_data_arr[r][0]  - in_data_arr[r][15];
                    O[1] = in_data_arr[r][1]  - in_data_arr[r][14];
                    O[2] = in_data_arr[r][2]  - in_data_arr[r][13];
                    O[3] = in_data_arr[r][3]  - in_data_arr[r][12];
                    O[4] = in_data_arr[r][4]  - in_data_arr[r][11];
                    O[5] = in_data_arr[r][5]  - in_data_arr[r][10];
                    O[6] = in_data_arr[r][6]  - in_data_arr[r][9];
                    O[7] = in_data_arr[r][7]  - in_data_arr[r][8];

                        // Even-even / even-odd (DCT-8 layer on E)
                        EE[0] = E[0] + E[7]; EE[1] = E[1] + E[6];
                        EE[2] = E[2] + E[5]; EE[3] = E[3] + E[4];
                        EO[0] = E[0] - E[7]; EO[1] = E[1] - E[6];
                        EO[2] = E[2] - E[5]; EO[3] = E[3] - E[4];

                        // Even-even-even / even-even-odd (DCT-4 layer on EE)
                        EEE[0] = EE[0] + EE[3]; EEE[1] = EE[1] + EE[2];
                        EEO[0] = EE[0] - EE[3]; EEO[1] = EE[1] - EE[2];

                        // 4 DC-like outputs (rows 0,4,8,12)
                        stage1[r][0]  <= `CLIP16((T64*EEE[0] + T64*EEE[1] + FWD_RND_1) >>> FWD_SHIFT_1);
                        stage1[r][8]  <= `CLIP16((T64*EEE[0] - T64*EEE[1] + FWD_RND_1) >>> FWD_SHIFT_1);
                        stage1[r][4]  <= `CLIP16((T83*EEO[0] + T36*EEO[1] + FWD_RND_1) >>> FWD_SHIFT_1);
                        stage1[r][12] <= `CLIP16((T36*EEO[0] - T83*EEO[1] + FWD_RND_1) >>> FWD_SHIFT_1);

                        // 4 even-odd outputs (rows 2,6,10,14)
                        stage1[r][2]  <= `CLIP16((T89*EO[0] + T75*EO[1] + T50*EO[2] + T18*EO[3] + FWD_RND_1) >>> FWD_SHIFT_1);
                        stage1[r][6]  <= `CLIP16((T75*EO[0] - T18*EO[1] - T89*EO[2] - T50*EO[3] + FWD_RND_1) >>> FWD_SHIFT_1);
                        stage1[r][10] <= `CLIP16((T50*EO[0] - T89*EO[1] + T18*EO[2] + T75*EO[3] + FWD_RND_1) >>> FWD_SHIFT_1);
                        stage1[r][14] <= `CLIP16((T18*EO[0] - T50*EO[1] + T75*EO[2] - T89*EO[3] + FWD_RND_1) >>> FWD_SHIFT_1);

                        // 8 odd outputs (rows 1,3,5,7,9,11,13,15)
                        stage1[r][1]  <= `CLIP16((T90*O[0]+T87*O[1]+T80*O[2]+T70*O[3]+T57*O[4]+T43*O[5]+T25*O[6]+T09*O[7]+FWD_RND_1) >>> FWD_SHIFT_1);
                        stage1[r][3]  <= `CLIP16((T87*O[0]+T57*O[1]+T09*O[2]-T43*O[3]-T80*O[4]-T90*O[5]-T70*O[6]-T25*O[7]+FWD_RND_1) >>> FWD_SHIFT_1);
                        stage1[r][5]  <= `CLIP16((T80*O[0]+T09*O[1]-T70*O[2]-T87*O[3]-T25*O[4]+T57*O[5]+T90*O[6]+T43*O[7]+FWD_RND_1) >>> FWD_SHIFT_1);
                        stage1[r][7]  <= `CLIP16((T70*O[0]-T43*O[1]-T87*O[2]+T09*O[3]+T90*O[4]+T25*O[5]-T80*O[6]-T57*O[7]+FWD_RND_1) >>> FWD_SHIFT_1);
                        stage1[r][9]  <= `CLIP16((T57*O[0]-T80*O[1]-T25*O[2]+T90*O[3]-T09*O[4]-T87*O[5]+T43*O[6]+T70*O[7]+FWD_RND_1) >>> FWD_SHIFT_1);
                        stage1[r][11] <= `CLIP16((T43*O[0]-T90*O[1]+T57*O[2]+T25*O[3]-T87*O[4]+T70*O[5]+T09*O[6]-T80*O[7]+FWD_RND_1) >>> FWD_SHIFT_1);
                        stage1[r][13] <= `CLIP16((T25*O[0]-T70*O[1]+T90*O[2]-T80*O[3]+T43*O[4]+T09*O[5]-T57*O[6]+T87*O[7]+FWD_RND_1) >>> FWD_SHIFT_1);
                        stage1[r][15] <= `CLIP16((T09*O[0]-T25*O[1]+T43*O[2]-T57*O[3]+T70*O[4]-T80*O[5]+T87*O[6]-T90*O[7]+FWD_RND_1) >>> FWD_SHIFT_1);
                    end

                end else begin
                    //----------------------------------------------------------
                    // INVERSE col pass — partialButterflyInverse16()
                    //----------------------------------------------------------
                    for (r = 0; r < 16; r = r + 1) begin : inv_col16
                        reg signed [IW-1:0] x [0:15];
                        reg signed [IW-1:0] O [0:7];
                        reg signed [IW-1:0] EO[0:3];
                        reg signed [IW-1:0] EEO[0:1];
                        reg signed [IW-1:0] EEE[0:1];
                        reg signed [IW-1:0] EE[0:3];
                        reg signed [IW-1:0] E [0:7];

                        // Read column r
                    x[0]=in_data_arr[0][r];  x[1]=in_data_arr[1][r];
                    x[2]=in_data_arr[2][r];  x[3]=in_data_arr[3][r];
                    x[4]=in_data_arr[4][r];  x[5]=in_data_arr[5][r];
                    x[6]=in_data_arr[6][r];  x[7]=in_data_arr[7][r];
                    x[8]=in_data_arr[8][r];  x[9]=in_data_arr[9][r];
                    x[10]=in_data_arr[10][r];x[11]=in_data_arr[11][r];
                    x[12]=in_data_arr[12][r];x[13]=in_data_arr[13][r];
                    x[14]=in_data_arr[14][r];x[15]=in_data_arr[15][r];

                        // 8 odd outputs from odd-indexed rows
                        O[0] = T90*x[1]+T87*x[3]+T80*x[5]+T70*x[7]+T57*x[9]+T43*x[11]+T25*x[13]+T09*x[15];
                        O[1] = T87*x[1]+T57*x[3]+T09*x[5]-T43*x[7]-T80*x[9]-T90*x[11]-T70*x[13]-T25*x[15];
                        O[2] = T80*x[1]+T09*x[3]-T70*x[5]-T87*x[7]-T25*x[9]+T57*x[11]+T90*x[13]+T43*x[15];
                        O[3] = T70*x[1]-T43*x[3]-T87*x[5]+T09*x[7]+T90*x[9]+T25*x[11]-T80*x[13]-T57*x[15];
                        O[4] = T57*x[1]-T80*x[3]-T25*x[5]+T90*x[7]-T09*x[9]-T87*x[11]+T43*x[13]+T70*x[15];
                        O[5] = T43*x[1]-T90*x[3]+T57*x[5]+T25*x[7]-T87*x[9]+T70*x[11]+T09*x[13]-T80*x[15];
                        O[6] = T25*x[1]-T70*x[3]+T90*x[5]-T80*x[7]+T43*x[9]+T09*x[11]-T57*x[13]+T87*x[15];
                        O[7] = T09*x[1]-T25*x[3]+T43*x[5]-T57*x[7]+T70*x[9]-T80*x[11]+T87*x[13]-T90*x[15];

                        // Even-odd from rows 2,6,10,14
                        EO[0] = T89*x[2]+T75*x[6]+T50*x[10]+T18*x[14];
                        EO[1] = T75*x[2]-T18*x[6]-T89*x[10]-T50*x[14];
                        EO[2] = T50*x[2]-T89*x[6]+T18*x[10]+T75*x[14];
                        EO[3] = T18*x[2]-T50*x[6]+T75*x[10]-T89*x[14];

                        // Even-even-odd from rows 4,12
                        EEO[0] = T83*x[4]+T36*x[12];
                        EEO[1] = T36*x[4]-T83*x[12];

                        // Even-even-even from rows 0,8
                        EEE[0] = T64*x[0]+T64*x[8];
                        EEE[1] = T64*x[0]-T64*x[8];

                        // Reconstruct EE
                        EE[0] = EEE[0]+EEO[0]; EE[1] = EEE[1]+EEO[1];
                        EE[2] = EEE[1]-EEO[1]; EE[3] = EEE[0]-EEO[0];

                        // Reconstruct E
                        E[0]=EE[0]+EO[0]; E[1]=EE[1]+EO[1];
                        E[2]=EE[2]+EO[2]; E[3]=EE[3]+EO[3];
                        E[4]=EE[3]-EO[3]; E[5]=EE[2]-EO[2];
                        E[6]=EE[1]-EO[1]; E[7]=EE[0]-EO[0];

                        // Combine E+O with shift+clip
                        stage1[r][0]  <= `CLIP16((E[0] +O[0]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][1]  <= `CLIP16((E[1] +O[1]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][2]  <= `CLIP16((E[2] +O[2]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][3]  <= `CLIP16((E[3] +O[3]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][4]  <= `CLIP16((E[4] +O[4]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][5]  <= `CLIP16((E[5] +O[5]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][6]  <= `CLIP16((E[6] +O[6]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][7]  <= `CLIP16((E[7] +O[7]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][8]  <= `CLIP16((E[7] -O[7]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][9]  <= `CLIP16((E[6] -O[6]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][10] <= `CLIP16((E[5] -O[5]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][11] <= `CLIP16((E[4] -O[4]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][12] <= `CLIP16((E[3] -O[3]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][13] <= `CLIP16((E[2] -O[2]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][14] <= `CLIP16((E[1] -O[1]+INV_RND_1)>>>INV_SHIFT_1);
                        stage1[r][15] <= `CLIP16((E[0] -O[0]+INV_RND_1)>>>INV_SHIFT_1);
                    end
                end
            end
        end
    end

    //=========================================================================
    // STAGE 2 — Col pass (fwd) / Row pass (inv)
    //=========================================================================
    integer c;

    always @(posedge clk) begin : stage2_proc
        integer k;
        if (!rst_n) begin
            out_valid <= 1'b0;
            for (c = 0; c < 16; c = c + 1)
                for (k = 0; k < 16; k = k + 1)
                    out_data_arr[c][k] <= {`COEFF_WIDTH{1'b0}};
        end else if (!out_ready) begin
            out_valid <= out_valid;
        end else begin
            out_valid <= stage1_valid;

            if (stage1_valid) begin
                if (fwd_inv_n_s1) begin
                    //----------------------------------------------------------
                    // FORWARD col pass
                    //----------------------------------------------------------
                    for (c = 0; c < 16; c = c + 1) begin : fwd_col16
                        reg signed [IW-1:0] E [0:7];
                        reg signed [IW-1:0] O [0:7];
                        reg signed [IW-1:0] EE[0:3];
                        reg signed [IW-1:0] EO[0:3];
                        reg signed [IW-1:0] EEE[0:1];
                        reg signed [IW-1:0] EEO[0:1];

                        E[0]=stage1[0][c]+stage1[15][c]; E[1]=stage1[1][c]+stage1[14][c];
                        E[2]=stage1[2][c]+stage1[13][c]; E[3]=stage1[3][c]+stage1[12][c];
                        E[4]=stage1[4][c]+stage1[11][c]; E[5]=stage1[5][c]+stage1[10][c];
                        E[6]=stage1[6][c]+stage1[9][c];  E[7]=stage1[7][c]+stage1[8][c];
                        O[0]=stage1[0][c]-stage1[15][c]; O[1]=stage1[1][c]-stage1[14][c];
                        O[2]=stage1[2][c]-stage1[13][c]; O[3]=stage1[3][c]-stage1[12][c];
                        O[4]=stage1[4][c]-stage1[11][c]; O[5]=stage1[5][c]-stage1[10][c];
                        O[6]=stage1[6][c]-stage1[9][c];  O[7]=stage1[7][c]-stage1[8][c];

                        EE[0]=E[0]+E[7]; EE[1]=E[1]+E[6]; EE[2]=E[2]+E[5]; EE[3]=E[3]+E[4];
                        EO[0]=E[0]-E[7]; EO[1]=E[1]-E[6]; EO[2]=E[2]-E[5]; EO[3]=E[3]-E[4];
                        EEE[0]=EE[0]+EE[3]; EEE[1]=EE[1]+EE[2];
                        EEO[0]=EE[0]-EE[3]; EEO[1]=EE[1]-EE[2];

                    out_data_arr[0][c]  <= `CLIP16((T64*EEE[0]+T64*EEE[1]+FWD_RND_2)>>>FWD_SHIFT_2);
                    out_data_arr[8][c]  <= `CLIP16((T64*EEE[0]-T64*EEE[1]+FWD_RND_2)>>>FWD_SHIFT_2);
                    out_data_arr[4][c]  <= `CLIP16((T83*EEO[0]+T36*EEO[1]+FWD_RND_2)>>>FWD_SHIFT_2);
                    out_data_arr[12][c] <= `CLIP16((T36*EEO[0]-T83*EEO[1]+FWD_RND_2)>>>FWD_SHIFT_2);
                    out_data_arr[2][c]  <= `CLIP16((T89*EO[0]+T75*EO[1]+T50*EO[2]+T18*EO[3]+FWD_RND_2)>>>FWD_SHIFT_2);
                    out_data_arr[6][c]  <= `CLIP16((T75*EO[0]-T18*EO[1]-T89*EO[2]-T50*EO[3]+FWD_RND_2)>>>FWD_SHIFT_2);
                    out_data_arr[10][c] <= `CLIP16((T50*EO[0]-T89*EO[1]+T18*EO[2]+T75*EO[3]+FWD_RND_2)>>>FWD_SHIFT_2);
                    out_data_arr[14][c] <= `CLIP16((T18*EO[0]-T50*EO[1]+T75*EO[2]-T89*EO[3]+FWD_RND_2)>>>FWD_SHIFT_2);
                    out_data_arr[1][c]  <= `CLIP16((T90*O[0]+T87*O[1]+T80*O[2]+T70*O[3]+T57*O[4]+T43*O[5]+T25*O[6]+T09*O[7]+FWD_RND_2)>>>FWD_SHIFT_2);
                    out_data_arr[3][c]  <= `CLIP16((T87*O[0]+T57*O[1]+T09*O[2]-T43*O[3]-T80*O[4]-T90*O[5]-T70*O[6]-T25*O[7]+FWD_RND_2)>>>FWD_SHIFT_2);
                    out_data_arr[5][c]  <= `CLIP16((T80*O[0]+T09*O[1]-T70*O[2]-T87*O[3]-T25*O[4]+T57*O[5]+T90*O[6]+T43*O[7]+FWD_RND_2)>>>FWD_SHIFT_2);
                    out_data_arr[7][c]  <= `CLIP16((T70*O[0]-T43*O[1]-T87*O[2]+T09*O[3]+T90*O[4]+T25*O[5]-T80*O[6]-T57*O[7]+FWD_RND_2)>>>FWD_SHIFT_2);
                    out_data_arr[9][c]  <= `CLIP16((T57*O[0]-T80*O[1]-T25*O[2]+T90*O[3]-T09*O[4]-T87*O[5]+T43*O[6]+T70*O[7]+FWD_RND_2)>>>FWD_SHIFT_2);
                    out_data_arr[11][c] <= `CLIP16((T43*O[0]-T90*O[1]+T57*O[2]+T25*O[3]-T87*O[4]+T70*O[5]+T09*O[6]-T80*O[7]+FWD_RND_2)>>>FWD_SHIFT_2);
                    out_data_arr[13][c] <= `CLIP16((T25*O[0]-T70*O[1]+T90*O[2]-T80*O[3]+T43*O[4]+T09*O[5]-T57*O[6]+T87*O[7]+FWD_RND_2)>>>FWD_SHIFT_2);
                    out_data_arr[15][c] <= `CLIP16((T09*O[0]-T25*O[1]+T43*O[2]-T57*O[3]+T70*O[4]-T80*O[5]+T87*O[6]-T90*O[7]+FWD_RND_2)>>>FWD_SHIFT_2);
                    end

                end else begin
                    //----------------------------------------------------------
                    // INVERSE row pass
                    //----------------------------------------------------------
                    for (r = 0; r < 16; r = r + 1) begin : inv_row16
                        reg signed [IW-1:0] x [0:15];
                        reg signed [IW-1:0] O [0:7];
                        reg signed [IW-1:0] EO[0:3];
                        reg signed [IW-1:0] EEO[0:1];
                        reg signed [IW-1:0] EEE[0:1];
                        reg signed [IW-1:0] EE[0:3];
                        reg signed [IW-1:0] E [0:7];

                        x[0]=stage1[0][r];  x[1]=stage1[1][r];
                        x[2]=stage1[2][r];  x[3]=stage1[3][r];
                        x[4]=stage1[4][r];  x[5]=stage1[5][r];
                        x[6]=stage1[6][r];  x[7]=stage1[7][r];
                        x[8]=stage1[8][r];  x[9]=stage1[9][r];
                        x[10]=stage1[10][r];x[11]=stage1[11][r];
                        x[12]=stage1[12][r];x[13]=stage1[13][r];
                        x[14]=stage1[14][r];x[15]=stage1[15][r];

                        O[0]=T90*x[1]+T87*x[3]+T80*x[5]+T70*x[7]+T57*x[9]+T43*x[11]+T25*x[13]+T09*x[15];
                        O[1]=T87*x[1]+T57*x[3]+T09*x[5]-T43*x[7]-T80*x[9]-T90*x[11]-T70*x[13]-T25*x[15];
                        O[2]=T80*x[1]+T09*x[3]-T70*x[5]-T87*x[7]-T25*x[9]+T57*x[11]+T90*x[13]+T43*x[15];
                        O[3]=T70*x[1]-T43*x[3]-T87*x[5]+T09*x[7]+T90*x[9]+T25*x[11]-T80*x[13]-T57*x[15];
                        O[4]=T57*x[1]-T80*x[3]-T25*x[5]+T90*x[7]-T09*x[9]-T87*x[11]+T43*x[13]+T70*x[15];
                        O[5]=T43*x[1]-T90*x[3]+T57*x[5]+T25*x[7]-T87*x[9]+T70*x[11]+T09*x[13]-T80*x[15];
                        O[6]=T25*x[1]-T70*x[3]+T90*x[5]-T80*x[7]+T43*x[9]+T09*x[11]-T57*x[13]+T87*x[15];
                        O[7]=T09*x[1]-T25*x[3]+T43*x[5]-T57*x[7]+T70*x[9]-T80*x[11]+T87*x[13]-T90*x[15];

                        EO[0]=T89*x[2]+T75*x[6]+T50*x[10]+T18*x[14];
                        EO[1]=T75*x[2]-T18*x[6]-T89*x[10]-T50*x[14];
                        EO[2]=T50*x[2]-T89*x[6]+T18*x[10]+T75*x[14];
                        EO[3]=T18*x[2]-T50*x[6]+T75*x[10]-T89*x[14];

                        EEO[0]=T83*x[4]+T36*x[12];
                        EEO[1]=T36*x[4]-T83*x[12];
                        EEE[0]=T64*x[0]+T64*x[8];
                        EEE[1]=T64*x[0]-T64*x[8];

                        EE[0]=EEE[0]+EEO[0]; EE[1]=EEE[1]+EEO[1];
                        EE[2]=EEE[1]-EEO[1]; EE[3]=EEE[0]-EEO[0];

                        E[0]=EE[0]+EO[0]; E[1]=EE[1]+EO[1];
                        E[2]=EE[2]+EO[2]; E[3]=EE[3]+EO[3];
                        E[4]=EE[3]-EO[3]; E[5]=EE[2]-EO[2];
                        E[6]=EE[1]-EO[1]; E[7]=EE[0]-EO[0];

                        out_data_arr[r][0]  <= `CLIP16((E[0]+O[0]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][1]  <= `CLIP16((E[1]+O[1]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][2]  <= `CLIP16((E[2]+O[2]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][3]  <= `CLIP16((E[3]+O[3]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][4]  <= `CLIP16((E[4]+O[4]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][5]  <= `CLIP16((E[5]+O[5]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][6]  <= `CLIP16((E[6]+O[6]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][7]  <= `CLIP16((E[7]+O[7]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][8]  <= `CLIP16((E[7]-O[7]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][9]  <= `CLIP16((E[6]-O[6]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][10] <= `CLIP16((E[5]-O[5]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][11] <= `CLIP16((E[4]-O[4]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][12] <= `CLIP16((E[3]-O[3]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][13] <= `CLIP16((E[2]-O[2]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][14] <= `CLIP16((E[1]-O[1]+INV_RND_2)>>>INV_SHIFT_2);
                        out_data_arr[r][15] <= `CLIP16((E[0]-O[0]+INV_RND_2)>>>INV_SHIFT_2);
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
            $display("INFO  [dct16] input stalled at time=%0t", $time);
    end
    integer check16_done;
    initial check16_done = 0;
    always @(posedge clk) begin
        if (rst_n && out_valid && fwd_inv_n_s1 && !check16_done) begin
            $display("INFO  [dct16] first fwd output [0][0]=%0d [1][0]=%0d",
                     out_data_arr[0][0], out_data_arr[1][0]);
            check16_done = 1;
        end
    end
    // synthesis translate_on

    `undef CLIP16

endmodule