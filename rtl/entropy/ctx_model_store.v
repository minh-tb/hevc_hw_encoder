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
    parameter N_CTX    = 186,   // HEVC Main profile context count
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
            lut[44]=6'd31;
            lut[45]=6'd32; lut[46]=6'd32; lut[47]=6'd33;
            lut[48]=6'd33; lut[49]=6'd33; lut[50]=6'd34; lut[51]=6'd34;
            lut[52]=6'd35; lut[53]=6'd35; lut[54]=6'd35; lut[55]=6'd36;
            lut[56]=6'd36; lut[57]=6'd36; lut[58]=6'd37; lut[59]=6'd37;
            lut[60]=6'd37; lut[61]=6'd38; lut[62]=6'd38; lut[63]=6'd38;
            trans_lps = lut[idx];
        end
    endfunction

    function automatic [7:0] get_init_val;
        input [1:0]          stype;
        input [CTX_ID_W-1:0] ctx;
        reg [7:0] iv_I;
        reg [7:0] iv_P;
        reg [7:0] iv_B;
        begin
            iv_I = 8'd154;
            iv_P = 8'd154;
            iv_B = 8'd154;
            case (ctx)
`include "init_tables.vh"
                default: begin iv_I = 8'd154; iv_P = 8'd154; iv_B = 8'd154; end
            endcase
            case (stype)
                2'd0:    get_init_val = iv_B;
                2'd1:    get_init_val = iv_P;
                default: get_init_val = iv_I;
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
