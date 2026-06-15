//=============================================================================
// ctx_model_store.v
// HEVC CABAC Context Model Store — 154 contexts, 7-bit state each
//
// Mapped from HM source:
//   TLibCommon/ContextModel.h       :: ContextModel class, m_ucState
//   TLibCommon/ContextModel.cpp     :: init(), update()
//                                      m_aucNextStateMPS[64], m_aucNextStateLPS[64]
//   TLibCommon/ContextTables.h      :: INIT_* tables (154 × 3 slice-type initValues)
//   TLibCommon/ContextModel3DBuffer :: initBuffer() slice-init sequencer
//
// HEVC CABAC state encoding (HM m_ucState convention):
//   state[6:1] = pStateIdx  (0..62)  probability state index
//   state[0]   = valMPS     (0 or 1) Most Probable Symbol value
//   Combined:  state = (pStateIdx << 1) | valMPS
//
// State transition (HM ContextModel::update(), bin value b):
//   pStateIdx = state[6:1];   valMPS = state[0]
//   if (b == valMPS):                            // MPS path
//     new_state = (transIdxMPS[pStateIdx]<<1) | valMPS
//   else:                                        // LPS path
//     new_valMPS = (pStateIdx==0) ? ~valMPS : valMPS
//     new_state  = (transIdxLPS[pStateIdx]<<1) | new_valMPS
//
// Initialization (HM ContextModel::init(qp, initValue)):
//   slope      = (initValue >> 4) * 5 - 45
//   offset     = ((initValue & 15) << 3) - 16
//   initState  = clamp((slope * qp >> 4) + offset, 1, 126)
//   state      = (initState >= 64) ? ((initState-64)<<1)|1
//                                  : ((63-initState)<<1)
//
// Context variable map — HEVC Main profile (154 total):
//   [  0..  2] SPLIT_CODING_UNIT_FLAG          (3)
//   [  3..  3] CU_TRANSQUANT_BYPASS_FLAG        (1)
//   [  4..  6] CU_SKIP_FLAG                     (3)
//   [  7..  7] MERGE_FLAG                       (1)
//   [  8..  8] MERGE_IDX                        (1)
//   [  9..  9] PRED_MODE_FLAG                   (1)
//   [ 10.. 13] PART_SIZE                        (4)
//   [ 14.. 15] PREV_INTRA_LUMA_PRED_FLAG        (2)
//   [ 16.. 17] INTRA_CHROMA_PRED_MODE           (2)
//   [ 18.. 22] INTER_PRED_IDC                   (5)
//   [ 23.. 24] REF_IDX_LX                       (2)
//   [ 25.. 25] MVP_LX_FLAG                      (1)
//   [ 26.. 28] DELTA_QP / NO_RESIDUAL_DATA_FLAG (3)
//   [ 29.. 37] LAST_SIG_COEFF_X_PREFIX luma     (9)
//   [ 38.. 46] LAST_SIG_COEFF_Y_PREFIX luma     (9)
//   [ 47.. 51] LAST_SIG_COEFF_X_PREFIX chroma   (5)
//   [ 52.. 56] LAST_SIG_COEFF_Y_PREFIX chroma   (5)
//   [ 57.. 66] CODED_SUB_BLOCK_FLAG             (10)
//   [ 67..102] SIG_COEFF_FLAG luma + chroma     (36)
//   [103..122] COEFF_ABS_LEVEL_GREATER1 luma    (16, 4 ctx × 4 coeff sets)
//   [119..122] COEFF_ABS_LEVEL_GREATER2 luma    (4,  1 ctx × 4 coeff sets)
//   [123..140] COEFF_ABS GREATER1/2 chroma      (18)
//   [141..153] SAO, transform_skip, misc        (13)
//   Total: 154
//
// Architecture:
//   - 154 × 7-bit state registers (~135 FFs or single LUTRAM block)
//   - Init sequencer: 154-cycle reset on slice_init pulse
//   - Init formula computed in RTL (supports any QP via qp_in port)
//   - Read port:  combinational, zero latency (bin_encoder critical path)
//   - Update port: single-cycle write-back (from bin_encoder each bin)
//   - Transition tables: 2 × 64-entry ROMs (exact from HM ContextModel.cpp)
//   - init_busy blocks updates while initialization is in progress
//=============================================================================

`include "parameter_pkg.vh"

module ctx_model_store #(
    parameter N_CTX    = 165,   // HEVC Main profile context count
    parameter CTX_W    = 7,     // state bits: [6:1]=pStateIdx, [0]=valMPS
    parameter CTX_ID_W = 8      // ceil(log2(N_CTX))
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // ── Slice initialization ──────────────────────────────────────────────
    input  wire                  slice_init,   // pulse: begin context reset
    input  wire [1:0]            slice_type,   // 0=I, 1=P, 2=B
    input  wire [6:0]            qp_in,        // QP 0..51; tie to 7'd32 for fixed-QP

    // ── Combinational read port ──────────────────────────────────────────
    // Zero-latency: bin_encoder reads rd_state in same cycle as rd_ctx_id
    input  wire [CTX_ID_W-1:0]  rd_ctx_id,
    output wire [CTX_W-1:0]     rd_state,     // {pStateIdx[5:0], valMPS}

    // ── Write-back update port ───────────────────────────────────────────
    // bin_encoder drives after each bin is arithmetically coded
    input  wire                  upd_valid,
    input  wire [CTX_ID_W-1:0]  upd_ctx_id,
    input  wire                  upd_bin,      // the bin value just coded

    // ── Status ───────────────────────────────────────────────────────────
    output reg                   init_busy     // high during 154-cycle init sequence
);

    // =========================================================================
    // Transition tables — exact values from HM ContextModel.cpp
    // =========================================================================

    // transIdxMPS: min(pStateIdx + 1, 62)
    function automatic [5:0] trans_mps;
        input [5:0] idx;
        trans_mps = (idx >= 6'd62) ? 6'd62 : idx + 6'd1;
    endfunction

    // transIdxLPS: from HM m_aucNextStateLPS[64] (exact copy)
    function automatic [5:0] trans_lps;
        input [5:0] idx;
        reg [5:0] lut [0:63];
        begin
            lut[ 0]=6'd0;  lut[ 1]=6'd0;  lut[ 2]=6'd1;  lut[ 3]=6'd2;
            lut[ 4]=6'd2;  lut[ 5]=6'd4;  lut[ 6]=6'd4;  lut[ 7]=6'd5;
            lut[ 8]=6'd6;  lut[ 9]=6'd7;  lut[10]=6'd8;  lut[11]=6'd9;
            lut[12]=6'd9;  lut[13]=6'd11; lut[14]=6'd11; lut[15]=6'd12;
            lut[16]=6'd13; lut[17]=6'd13; lut[18]=6'd15; lut[19]=6'd15;
            lut[20]=6'd16; lut[21]=6'd16; lut[22]=6'd18; lut[23]=6'd18;
            lut[24]=6'd19; lut[25]=6'd19; lut[26]=6'd21; lut[27]=6'd21;
            lut[28]=6'd22; lut[29]=6'd22; lut[30]=6'd23; lut[31]=6'd24;
            lut[32]=6'd24; lut[33]=6'd25; lut[34]=6'd26; lut[35]=6'd26;
            lut[36]=6'd27; lut[37]=6'd27; lut[38]=6'd28; lut[39]=6'd29;
            lut[40]=6'd29; lut[41]=6'd30; lut[42]=6'd30; lut[43]=6'd30;
            lut[44]=6'd31; lut[45]=6'd32; lut[46]=6'd32; lut[47]=6'd33;
            lut[48]=6'd33; lut[49]=6'd33; lut[50]=6'd34; lut[51]=6'd34;
            lut[52]=6'd35; lut[53]=6'd35; lut[54]=6'd35; lut[55]=6'd36;
            lut[56]=6'd36; lut[57]=6'd36; lut[58]=6'd37; lut[59]=6'd37;
            lut[60]=6'd37; lut[61]=6'd38; lut[62]=6'd38; lut[63]=6'd38;
            trans_lps = lut[idx];
        end
    endfunction

    // =========================================================================
    // Init value ROM — 154 × 3 slice-types × 8-bit
    // Source: HM ContextTables.h INIT_* arrays (I/P/B slice init values)
    // Byte format: [7:4]=slope_idx, [3:0]=offset_idx (used in init formula)
    // =========================================================================
    function automatic [7:0] get_init_val;
        input [1:0]          stype;
        input [CTX_ID_W-1:0] ctx;
        // Declare separate arrays for each slice type
        reg [7:0] iv_I [0:164];
        reg [7:0] iv_P [0:164];
        reg [7:0] iv_B [0:164];
        integer   k;
        begin
            // -- I-slice initValues --
            iv_I[0]=8'd139;
            iv_I[1]=8'd141;
            iv_I[2]=8'd157;
            iv_I[3]=8'd154;
            iv_I[4]=8'd154;
            iv_I[5]=8'd154;
            iv_I[6]=8'd154;
            iv_I[7]=8'd154;
            iv_I[8]=8'd154;
            iv_I[9]=8'd154;
            iv_I[10]=8'd184;
            iv_I[11]=8'd154;
            iv_I[12]=8'd154;
            iv_I[13]=8'd154;
            iv_I[14]=8'd184;
            iv_I[15]=8'd154;
            iv_I[16]=8'd63;
            iv_I[17]=8'd139;
            iv_I[18]=8'd154;
            iv_I[19]=8'd154;
            iv_I[20]=8'd154;
            iv_I[21]=8'd154;
            iv_I[22]=8'd154;
            iv_I[23]=8'd154;
            iv_I[24]=8'd154;
            iv_I[25]=8'd154;
            iv_I[26]=8'd154;
            iv_I[27]=8'd154;
            iv_I[28]=8'd154;
            iv_I[29]=8'd110;
            iv_I[30]=8'd110;
            iv_I[31]=8'd124;
            iv_I[32]=8'd125;
            iv_I[33]=8'd140;
            iv_I[34]=8'd153;
            iv_I[35]=8'd125;
            iv_I[36]=8'd127;
            iv_I[37]=8'd140;
            iv_I[38]=8'd110;
            iv_I[39]=8'd110;
            iv_I[40]=8'd124;
            iv_I[41]=8'd125;
            iv_I[42]=8'd140;
            iv_I[43]=8'd153;
            iv_I[44]=8'd125;
            iv_I[45]=8'd127;
            iv_I[46]=8'd140;
            iv_I[47]=8'd108;
            iv_I[48]=8'd123;
            iv_I[49]=8'd63;
            iv_I[50]=8'd154;
            iv_I[51]=8'd154;
            iv_I[52]=8'd108;
            iv_I[53]=8'd123;
            iv_I[54]=8'd63;
            iv_I[55]=8'd154;
            iv_I[56]=8'd154;
            iv_I[57]=8'd91;
            iv_I[58]=8'd171;
            iv_I[59]=8'd134;
            iv_I[60]=8'd141;
            iv_I[61]=8'd91;
            iv_I[62]=8'd171;
            iv_I[63]=8'd134;
            iv_I[64]=8'd141;
            iv_I[65]=8'd154;
            iv_I[66]=8'd154;
            iv_I[67]=8'd111;
            iv_I[68]=8'd111;
            iv_I[69]=8'd125;
            iv_I[70]=8'd110;
            iv_I[71]=8'd110;
            iv_I[72]=8'd94;
            iv_I[73]=8'd124;
            iv_I[74]=8'd108;
            iv_I[75]=8'd124;
            iv_I[76]=8'd107;
            iv_I[77]=8'd125;
            iv_I[78]=8'd141;
            iv_I[79]=8'd179;
            iv_I[80]=8'd153;
            iv_I[81]=8'd125;
            iv_I[82]=8'd107;
            iv_I[83]=8'd125;
            iv_I[84]=8'd141;
            iv_I[85]=8'd179;
            iv_I[86]=8'd153;
            iv_I[87]=8'd125;
            iv_I[88]=8'd107;
            iv_I[89]=8'd125;
            iv_I[90]=8'd141;
            iv_I[91]=8'd179;
            iv_I[92]=8'd153;
            iv_I[93]=8'd125;
            iv_I[94]=8'd140;
            iv_I[95]=8'd139;
            iv_I[96]=8'd182;
            iv_I[97]=8'd182;
            iv_I[98]=8'd152;
            iv_I[99]=8'd136;
            iv_I[100]=8'd152;
            iv_I[101]=8'd136;
            iv_I[102]=8'd153;
            iv_I[103]=8'd140;
            iv_I[104]=8'd92;
            iv_I[105]=8'd137;
            iv_I[106]=8'd138;
            iv_I[107]=8'd140;
            iv_I[108]=8'd152;
            iv_I[109]=8'd138;
            iv_I[110]=8'd139;
            iv_I[111]=8'd153;
            iv_I[112]=8'd74;
            iv_I[113]=8'd149;
            iv_I[114]=8'd92;
            iv_I[115]=8'd139;
            iv_I[116]=8'd107;
            iv_I[117]=8'd122;
            iv_I[118]=8'd152;
            iv_I[119]=8'd138;
            iv_I[120]=8'd153;
            iv_I[121]=8'd136;
            iv_I[122]=8'd167;
            iv_I[123]=8'd140;
            iv_I[124]=8'd179;
            iv_I[125]=8'd166;
            iv_I[126]=8'd182;
            iv_I[127]=8'd140;
            iv_I[128]=8'd227;
            iv_I[129]=8'd122;
            iv_I[130]=8'd197;
            iv_I[131]=8'd154;
            iv_I[132]=8'd154;
            iv_I[133]=8'd154;
            iv_I[134]=8'd154;
            iv_I[135]=8'd154;
            iv_I[136]=8'd154;
            iv_I[137]=8'd152;
            iv_I[138]=8'd152;
            iv_I[139]=8'd154;
            iv_I[140]=8'd154;
            iv_I[141]=8'd154;
            iv_I[142]=8'd154;
            iv_I[143]=8'd154;
            iv_I[144]=8'd154;
            iv_I[145]=8'd154;
            iv_I[146]=8'd154;
            iv_I[147]=8'd154;
            iv_I[148]=8'd154;
            iv_I[149]=8'd154;
            iv_I[150]=8'd154;
            iv_I[151]=8'd154;
            iv_I[152]=8'd154;
            iv_I[153]=8'd154;
            iv_I[154]=8'd153;
            iv_I[155]=8'd138;
            iv_I[156]=8'd138;
            iv_I[157]=8'd154;
            iv_I[158]=8'd111;
            iv_I[159]=8'd141;
            iv_I[160]=8'd94;
            iv_I[161]=8'd138;
            iv_I[162]=8'd182;
            iv_I[163]=8'd154;
            iv_I[164]=8'd154;

            // -- P-slice initValues --
            iv_P[0]=8'd107;
            iv_P[1]=8'd139;
            iv_P[2]=8'd126;
            iv_P[3]=8'd154;
            iv_P[4]=8'd197;
            iv_P[5]=8'd185;
            iv_P[6]=8'd201;
            iv_P[7]=8'd110;
            iv_P[8]=8'd122;
            iv_P[9]=8'd149;
            iv_P[10]=8'd154;
            iv_P[11]=8'd139;
            iv_P[12]=8'd154;
            iv_P[13]=8'd154;
            iv_P[14]=8'd154;
            iv_P[15]=8'd154;
            iv_P[16]=8'd152;
            iv_P[17]=8'd139;
            iv_P[18]=8'd95;
            iv_P[19]=8'd79;
            iv_P[20]=8'd63;
            iv_P[21]=8'd31;
            iv_P[22]=8'd31;
            iv_P[23]=8'd153;
            iv_P[24]=8'd153;
            iv_P[25]=8'd168;
            iv_P[26]=8'd154;
            iv_P[27]=8'd154;
            iv_P[28]=8'd154;
            iv_P[29]=8'd125;
            iv_P[30]=8'd110;
            iv_P[31]=8'd94;
            iv_P[32]=8'd110;
            iv_P[33]=8'd95;
            iv_P[34]=8'd79;
            iv_P[35]=8'd125;
            iv_P[36]=8'd111;
            iv_P[37]=8'd110;
            iv_P[38]=8'd125;
            iv_P[39]=8'd110;
            iv_P[40]=8'd94;
            iv_P[41]=8'd110;
            iv_P[42]=8'd95;
            iv_P[43]=8'd79;
            iv_P[44]=8'd125;
            iv_P[45]=8'd111;
            iv_P[46]=8'd110;
            iv_P[47]=8'd108;
            iv_P[48]=8'd123;
            iv_P[49]=8'd108;
            iv_P[50]=8'd154;
            iv_P[51]=8'd154;
            iv_P[52]=8'd108;
            iv_P[53]=8'd123;
            iv_P[54]=8'd108;
            iv_P[55]=8'd154;
            iv_P[56]=8'd154;
            iv_P[57]=8'd121;
            iv_P[58]=8'd140;
            iv_P[59]=8'd61;
            iv_P[60]=8'd154;
            iv_P[61]=8'd121;
            iv_P[62]=8'd140;
            iv_P[63]=8'd61;
            iv_P[64]=8'd154;
            iv_P[65]=8'd154;
            iv_P[66]=8'd154;
            iv_P[67]=8'd155;
            iv_P[68]=8'd154;
            iv_P[69]=8'd139;
            iv_P[70]=8'd153;
            iv_P[71]=8'd139;
            iv_P[72]=8'd123;
            iv_P[73]=8'd123;
            iv_P[74]=8'd63;
            iv_P[75]=8'd153;
            iv_P[76]=8'd166;
            iv_P[77]=8'd183;
            iv_P[78]=8'd140;
            iv_P[79]=8'd136;
            iv_P[80]=8'd153;
            iv_P[81]=8'd154;
            iv_P[82]=8'd166;
            iv_P[83]=8'd183;
            iv_P[84]=8'd140;
            iv_P[85]=8'd136;
            iv_P[86]=8'd153;
            iv_P[87]=8'd154;
            iv_P[88]=8'd166;
            iv_P[89]=8'd183;
            iv_P[90]=8'd140;
            iv_P[91]=8'd136;
            iv_P[92]=8'd153;
            iv_P[93]=8'd154;
            iv_P[94]=8'd170;
            iv_P[95]=8'd153;
            iv_P[96]=8'd123;
            iv_P[97]=8'd123;
            iv_P[98]=8'd107;
            iv_P[99]=8'd121;
            iv_P[100]=8'd107;
            iv_P[101]=8'd121;
            iv_P[102]=8'd167;
            iv_P[103]=8'd154;
            iv_P[104]=8'd196;
            iv_P[105]=8'd196;
            iv_P[106]=8'd167;
            iv_P[107]=8'd154;
            iv_P[108]=8'd152;
            iv_P[109]=8'd167;
            iv_P[110]=8'd182;
            iv_P[111]=8'd182;
            iv_P[112]=8'd134;
            iv_P[113]=8'd149;
            iv_P[114]=8'd136;
            iv_P[115]=8'd153;
            iv_P[116]=8'd121;
            iv_P[117]=8'd136;
            iv_P[118]=8'd137;
            iv_P[119]=8'd107;
            iv_P[120]=8'd167;
            iv_P[121]=8'd91;
            iv_P[122]=8'd122;
            iv_P[123]=8'd169;
            iv_P[124]=8'd194;
            iv_P[125]=8'd166;
            iv_P[126]=8'd167;
            iv_P[127]=8'd154;
            iv_P[128]=8'd167;
            iv_P[129]=8'd137;
            iv_P[130]=8'd182;
            iv_P[131]=8'd154;
            iv_P[132]=8'd154;
            iv_P[133]=8'd154;
            iv_P[134]=8'd154;
            iv_P[135]=8'd154;
            iv_P[136]=8'd154;
            iv_P[137]=8'd107;
            iv_P[138]=8'd167;
            iv_P[139]=8'd154;
            iv_P[140]=8'd154;
            iv_P[141]=8'd154;
            iv_P[142]=8'd154;
            iv_P[143]=8'd154;
            iv_P[144]=8'd154;
            iv_P[145]=8'd154;
            iv_P[146]=8'd154;
            iv_P[147]=8'd154;
            iv_P[148]=8'd154;
            iv_P[149]=8'd154;
            iv_P[150]=8'd154;
            iv_P[151]=8'd154;
            iv_P[152]=8'd154;
            iv_P[153]=8'd154;
            iv_P[154]=8'd124;
            iv_P[155]=8'd138;
            iv_P[156]=8'd94;
            iv_P[157]=8'd79;
            iv_P[158]=8'd153;
            iv_P[159]=8'd111;
            iv_P[160]=8'd149;
            iv_P[161]=8'd107;
            iv_P[162]=8'd167;
            iv_P[163]=8'd154;
            iv_P[164]=8'd154;

            // -- B-slice initValues --
            iv_B[0]=8'd107;
            iv_B[1]=8'd139;
            iv_B[2]=8'd126;
            iv_B[3]=8'd154;
            iv_B[4]=8'd197;
            iv_B[5]=8'd185;
            iv_B[6]=8'd201;
            iv_B[7]=8'd154;
            iv_B[8]=8'd137;
            iv_B[9]=8'd134;
            iv_B[10]=8'd154;
            iv_B[11]=8'd139;
            iv_B[12]=8'd154;
            iv_B[13]=8'd154;
            iv_B[14]=8'd183;
            iv_B[15]=8'd154;
            iv_B[16]=8'd152;
            iv_B[17]=8'd139;
            iv_B[18]=8'd95;
            iv_B[19]=8'd79;
            iv_B[20]=8'd63;
            iv_B[21]=8'd31;
            iv_B[22]=8'd31;
            iv_B[23]=8'd153;
            iv_B[24]=8'd153;
            iv_B[25]=8'd168;
            iv_B[26]=8'd154;
            iv_B[27]=8'd154;
            iv_B[28]=8'd154;
            iv_B[29]=8'd125;
            iv_B[30]=8'd110;
            iv_B[31]=8'd124;
            iv_B[32]=8'd110;
            iv_B[33]=8'd95;
            iv_B[34]=8'd94;
            iv_B[35]=8'd125;
            iv_B[36]=8'd111;
            iv_B[37]=8'd111;
            iv_B[38]=8'd125;
            iv_B[39]=8'd110;
            iv_B[40]=8'd124;
            iv_B[41]=8'd110;
            iv_B[42]=8'd95;
            iv_B[43]=8'd94;
            iv_B[44]=8'd125;
            iv_B[45]=8'd111;
            iv_B[46]=8'd111;
            iv_B[47]=8'd108;
            iv_B[48]=8'd123;
            iv_B[49]=8'd93;
            iv_B[50]=8'd154;
            iv_B[51]=8'd154;
            iv_B[52]=8'd108;
            iv_B[53]=8'd123;
            iv_B[54]=8'd93;
            iv_B[55]=8'd154;
            iv_B[56]=8'd154;
            iv_B[57]=8'd121;
            iv_B[58]=8'd140;
            iv_B[59]=8'd61;
            iv_B[60]=8'd154;
            iv_B[61]=8'd121;
            iv_B[62]=8'd140;
            iv_B[63]=8'd61;
            iv_B[64]=8'd154;
            iv_B[65]=8'd154;
            iv_B[66]=8'd154;
            iv_B[67]=8'd170;
            iv_B[68]=8'd154;
            iv_B[69]=8'd139;
            iv_B[70]=8'd153;
            iv_B[71]=8'd139;
            iv_B[72]=8'd123;
            iv_B[73]=8'd123;
            iv_B[74]=8'd63;
            iv_B[75]=8'd124;
            iv_B[76]=8'd166;
            iv_B[77]=8'd183;
            iv_B[78]=8'd140;
            iv_B[79]=8'd136;
            iv_B[80]=8'd153;
            iv_B[81]=8'd154;
            iv_B[82]=8'd166;
            iv_B[83]=8'd183;
            iv_B[84]=8'd140;
            iv_B[85]=8'd136;
            iv_B[86]=8'd153;
            iv_B[87]=8'd154;
            iv_B[88]=8'd166;
            iv_B[89]=8'd183;
            iv_B[90]=8'd140;
            iv_B[91]=8'd136;
            iv_B[92]=8'd153;
            iv_B[93]=8'd154;
            iv_B[94]=8'd170;
            iv_B[95]=8'd153;
            iv_B[96]=8'd138;
            iv_B[97]=8'd138;
            iv_B[98]=8'd122;
            iv_B[99]=8'd121;
            iv_B[100]=8'd122;
            iv_B[101]=8'd121;
            iv_B[102]=8'd167;
            iv_B[103]=8'd154;
            iv_B[104]=8'd196;
            iv_B[105]=8'd167;
            iv_B[106]=8'd167;
            iv_B[107]=8'd154;
            iv_B[108]=8'd152;
            iv_B[109]=8'd167;
            iv_B[110]=8'd182;
            iv_B[111]=8'd182;
            iv_B[112]=8'd134;
            iv_B[113]=8'd149;
            iv_B[114]=8'd136;
            iv_B[115]=8'd153;
            iv_B[116]=8'd121;
            iv_B[117]=8'd136;
            iv_B[118]=8'd122;
            iv_B[119]=8'd107;
            iv_B[120]=8'd167;
            iv_B[121]=8'd91;
            iv_B[122]=8'd107;
            iv_B[123]=8'd169;
            iv_B[124]=8'd208;
            iv_B[125]=8'd166;
            iv_B[126]=8'd167;
            iv_B[127]=8'd154;
            iv_B[128]=8'd152;
            iv_B[129]=8'd167;
            iv_B[130]=8'd182;
            iv_B[131]=8'd154;
            iv_B[132]=8'd154;
            iv_B[133]=8'd154;
            iv_B[134]=8'd154;
            iv_B[135]=8'd154;
            iv_B[136]=8'd154;
            iv_B[137]=8'd107;
            iv_B[138]=8'd167;
            iv_B[139]=8'd154;
            iv_B[140]=8'd154;
            iv_B[141]=8'd154;
            iv_B[142]=8'd154;
            iv_B[143]=8'd154;
            iv_B[144]=8'd154;
            iv_B[145]=8'd154;
            iv_B[146]=8'd154;
            iv_B[147]=8'd154;
            iv_B[148]=8'd154;
            iv_B[149]=8'd154;
            iv_B[150]=8'd154;
            iv_B[151]=8'd154;
            iv_B[152]=8'd154;
            iv_B[153]=8'd154;
            iv_B[154]=8'd224;
            iv_B[155]=8'd167;
            iv_B[156]=8'd122;
            iv_B[157]=8'd79;
            iv_B[158]=8'd153;
            iv_B[159]=8'd111;
            iv_B[160]=8'd149;
            iv_B[161]=8'd92;
            iv_B[162]=8'd167;
            iv_B[163]=8'd154;
            iv_B[164]=8'd154;

            case (stype)
                2'd0: get_init_val = iv_B[ctx];
                2'd1: get_init_val = iv_P[ctx];
                default: get_init_val = iv_I[ctx];
            endcase
        end
    endfunction

    // =========================================================================
    // Init formula — HM ContextModel::init(qp, initValue)
    // Converts (initValue byte, QP) → 7-bit state register value
    // =========================================================================
    function automatic [CTX_W-1:0] compute_state;
        input [7:0] iv;
        input [6:0] qp;
        reg signed [8:0]  slope;
        reg signed [8:0]  offs;
        reg signed [15:0] tmp;
        reg [6:0]          is;
        begin
            slope = $signed({5'b0, iv[7:4]}) * 9'sd5 - 9'sd45;
            offs  = $signed({2'b0, iv[3:0], 3'b0}) - 9'sd16;
            tmp   = (slope * $signed({1'b0, qp})) >>> 4;
            tmp   = tmp + offs; // Automatically sign-extends offs to 16 bits
            if      (tmp < 16'sd1)   is = 7'd1;
            else if (tmp > 16'sd126) is = 7'd126;
            else                     is = tmp[6:0];
            if (is >= 7'd64)
                compute_state = {is[5:0], 1'b1};
            else
                compute_state = {(6'd63 - is[5:0]), 1'b0};
        end
    endfunction

    // =========================================================================
    // Context model state SRAM — 154 × 7-bit
    // (~135 FFs; small enough to be registers, infers LUTRAM in FPGA targets)
    // =========================================================================
    reg [CTX_W-1:0] ctx_mem [0:N_CTX-1];

    // =========================================================================
    // Init sequencer — writes computed initial state for one context per cycle
    // Runs for exactly N_CTX=154 cycles after slice_init pulse
    // init_busy blocks all updates during this window
    // =========================================================================
    reg [CTX_ID_W-1:0] init_cnt;
    reg [1:0]           init_stype_r;
    reg [6:0]           init_qp_r;

    always @(posedge clk or negedge rst_n) begin : seq_init
        integer i;
        reg [5:0] ps;
        reg       mps;
        reg [5:0] new_ps;
        reg       new_mps;
        if (!rst_n) begin
            init_busy    <= 1'b0;
            init_cnt     <= {CTX_ID_W{1'b0}};
            // Cold-reset: force all contexts to mid-probability (state=0)
            for (i = 0; i < N_CTX; i = i + 1)
                ctx_mem[i] <= {CTX_W{1'b0}};
        end else begin
            if (slice_init && !init_busy) begin
                // synthesis translate_off
                $display("Time=%0t: [CTX_MODEL_STORE] slice_init received, starting init! slice_type=%0d, qp=%0d", $time, slice_type, qp_in);
                // synthesis translate_on
                init_stype_r <= slice_type;
                init_qp_r    <= qp_in;
                init_cnt     <= {CTX_ID_W{1'b0}};
                init_busy    <= 1'b1;
            end else if (init_busy) begin
                // synthesis translate_off
                $display("Time=%0t: [CTX_MODEL_STORE] Init ctx=%0d, init_val=%0d, state=%b", $time, init_cnt, get_init_val(init_stype_r, init_cnt), compute_state(get_init_val(init_stype_r, init_cnt), init_qp_r));
                // synthesis translate_on
                ctx_mem[init_cnt] <= compute_state(
                                         get_init_val(init_stype_r, init_cnt),
                                         init_qp_r);
                if (init_cnt == (N_CTX - 1)) begin
                    init_busy <= 1'b0;
                    // synthesis translate_off
                    $display("Time=%0t: [CTX_MODEL_STORE] Initialization complete!", $time);
                    // synthesis translate_on
                end else begin
                    init_cnt  <= init_cnt + {{(CTX_ID_W-1){1'b0}}, 1'b1};
                end
            end else if (upd_valid) begin
                ps  = ctx_mem[upd_ctx_id][CTX_W-1:1];  // pStateIdx
                mps = ctx_mem[upd_ctx_id][0];          // valMPS
                if (upd_bin == mps) begin
                    new_ps  = trans_mps(ps);
                    new_mps = mps;
                end else begin
                    new_ps  = trans_lps(ps);
                    new_mps = (ps == 6'd0) ? ~mps : mps;
                end
                ctx_mem[upd_ctx_id] <= {new_ps, new_mps};
            end
        end
    end


    // =========================================================================
    // Combinational read — zero-latency for bin_encoder critical path
    // =========================================================================
    assign rd_state = ctx_mem[rd_ctx_id];

    // =========================================================================
    // Simulation checks
    // =========================================================================
    // synthesis translate_off
    always @(posedge clk) begin
        if (upd_valid && !init_busy && upd_ctx_id >= N_CTX)
            $display("ERROR [ctx_model_store] upd_ctx_id=%0d >= N_CTX=%0d",
                     upd_ctx_id, N_CTX);
        if (slice_init && init_busy)
            $display("WARN  [ctx_model_store] slice_init ignored — init_busy");
    end
    initial begin
        $display("INFO  [ctx_model_store] N_CTX=%0d CTX_W=%0d init_cycles=%0d",
                 N_CTX, CTX_W, N_CTX);
    end
    // synthesis translate_on

endmodule