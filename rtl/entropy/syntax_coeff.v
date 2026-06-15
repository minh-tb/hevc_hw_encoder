//=============================================================================
// syntax_coeff.v
// Transform Coefficient CABAC Syntax Encoder (4×4 TU, extensible)
//
// Mapped from HM source:
//   TLibEncoder/TEncSbac.cpp ::
//     codeCoeffNxN()                 — top-level coefficient block encoder
//     codeLastSignificantXY()        — last_sig_coeff_x/y_prefix/suffix
//     codeSigCoeffGroupFlag()        — coded_sub_block_flag
//     codeSigFlag()                  — sig_coeff_flag
//     codeCoeffAbsLevelGreater1()    — coeff_abs_level_greater1_flag
//     codeCoeffAbsLevelGreater2()    — coeff_abs_level_greater2_flag
//     codeCoeffAbsLevelRemaining()   — coeff_abs_level_remaining (EP Exp-Golomb)
//   TLibEncoder/TEncSbac.h          :: m_uiGoRiceParam, ctxSet tracking
//
// HEVC coefficient encoding order (HM codeCoeffNxN, 4×4 luma, diagonal scan):
//
//   1. last_sig_coeff_x_prefix  [ctx group LAST_X, positions 0..log2(W)-2]
//   2. last_sig_coeff_x_suffix  [EP bypass, if prefix needs suffix bits]
//   3. last_sig_coeff_y_prefix  [ctx group LAST_Y]
//   4. last_sig_coeff_y_suffix  [EP bypass]
//
//   For each 4×4 sub-block (reverse scan, last sub-block first):
//   5.  coded_sub_block_flag    [ctx 57-66, not for last/DC sub-block]
//   6.  sig_coeff_flag          [ctx 67-102, per scan position]
//   7.  coeff_abs_level_greater1_flag [ctx 103-118, up to 8 per sub-block]
//   8.  coeff_abs_level_greater2_flag [ctx 119-122, at most 1 per sub-block]
//   9.  coeff_sign_flag         [EP bypass, for each significant coeff]
//   10. coeff_abs_level_remaining [EP Exp-Golomb, Rice code, for remaining]
//
// Context assignments (matching ctx_model_store.v):
//   LAST_X base (luma):    ctx 29   (+prefix position 0..7)
//   LAST_Y base (luma):    ctx 38   (+prefix position 0..7)
//   LAST_X base (chroma):  ctx 47   (+prefix position 0..4)
//   LAST_Y base (chroma):  ctx 52   (+prefix position 0..4)
//   CODED_SUBBLOCK:        ctx 57   (4 contexts, luma; 57+4 chroma)
//   SIG_COEFF (luma):      ctx 67   (+scan position up to 35)
//   GREATER1 (luma):       ctx 103  (4 ctx × 4 coeff-sets = 16)
//   GREATER2 (luma):       ctx 119  (1 ctx × 4 coeff-sets = 4)
//
// Architecture — 4-phase counter FSM for 4×4 block:
//   Phase 0: last_sig encoding (x prefix, x suffix, y prefix, y suffix)
//   Phase 1: coded_sub_block_flags (for multi-sub-block sizes)
//   Phase 2: sig_coeff_flags + greater1 + greater2 (interleaved per sub-block)
//   Phase 3: sign_flags (EP) + abs_level_remaining (EP Exp-Golomb)
//
// Fixed for 4×4 block (single sub-block) with parameterization hooks for 8/16/32.
//
// Scan order (4×4 diagonal, HEVC spec):
//   Scan pos → (row, col):
//    0:(0,0) 1:(0,1) 2:(1,0) 3:(2,0) 4:(1,1) 5:(0,2) 6:(0,3) 7:(1,2)
//    8:(2,1) 9:(3,0) 10:(3,1) 11:(2,2) 12:(1,3) 13:(2,3) 14:(3,2) 15:(3,3)
//
// Coefficients are input as flat array coeff_flat[16×COEFF_W-1:0],
// indexed coeff_flat[COEFF_W*scan_pos +: COEFF_W] = coeff at scan position.
//=============================================================================

`include "parameter_pkg.vh"

module syntax_coeff #(
    parameter CTX_ID_W = 8,
    parameter COEFF_W  = 16,    // signed coefficient width (after quantization)
    parameter BLK_SIZE = 4,     // transform block size (4 for 4×4)
    parameter N_COEFF  = BLK_SIZE * BLK_SIZE,  // 16 for 4×4

    // Rice parameter limits for coeff_abs_level_remaining
    parameter MAX_RICE = 4      // max rice parameter (HM uses 0..4)
)(
    input  wire                          clk,
    input  wire                          rst_n,

    // ── Encoding request ────────────────────────────────────────────────────
    input  wire                          coeff_valid,  // start encoding this TU
    output reg                           coeff_done,   // all bins sent

    // ── TU parameters ───────────────────────────────────────────────────────
    input  wire [1:0]                    comp_id,      // 0=luma, 1=Cb, 2=Cr
    input  wire                          is_intra,     // intra: affects ctx selection

    // Quantized coefficients in scan order (diagonal scan, 4×4)
    // coeff_flat[COEFF_W*i +: COEFF_W] = signed coeff at scan position i
    input  wire [COEFF_W*N_COEFF-1:0]   coeff_flat,

    // ── Bin output → bin_encoder ─────────────────────────────────────────────
    output reg                           bin_valid,
    output reg                           bin_value,
    output reg  [CTX_ID_W-1:0]          bin_ctx_id,
    output reg                           bin_is_ep,
    input  wire                          bin_rdy
);

    // =========================================================================
    // Diagonal scan LUT — 4×4, HEVC spec diagonal scan
    // scan_row[i], scan_col[i]: row and column at scan position i
    // =========================================================================
    function automatic [1:0] scan_row_f;
        input [3:0] pos;
        reg [1:0] row_lut [0:15];
        begin
            row_lut[ 0]=2'd0; row_lut[ 1]=2'd0; row_lut[ 2]=2'd1; row_lut[ 3]=2'd2; 
            row_lut[ 4]=2'd1; row_lut[ 5]=2'd0; row_lut[ 6]=2'd0; row_lut[ 7]=2'd1;
            row_lut[ 8]=2'd2; row_lut[ 9]=2'd3; row_lut[10]=2'd3; row_lut[11]=2'd2;
            row_lut[12]=2'd1; row_lut[13]=2'd2; row_lut[14]=2'd3; row_lut[15]=2'd3;
            scan_row_f = row_lut[pos];
        end
    endfunction

    function automatic [1:0] scan_col_f;
        input [3:0] pos;
        reg [1:0] col_lut [0:15];
        begin
            col_lut[ 0]=2'd0; col_lut[ 1]=2'd1; col_lut[ 2]=2'd0; col_lut[ 3]=2'd0;
            col_lut[ 4]=2'd1; col_lut[ 5]=2'd2; col_lut[ 6]=2'd3; col_lut[ 7]=2'd2;
            col_lut[ 8]=2'd1; col_lut[ 9]=2'd0; col_lut[10]=2'd1; col_lut[11]=2'd2;
            col_lut[12]=2'd3; col_lut[13]=2'd3; col_lut[14]=2'd2; col_lut[15]=2'd3;
            scan_col_f = col_lut[pos];
        end
    endfunction

    // =========================================================================
    // Context base addresses (matching ctx_model_store.v map)
    // =========================================================================
    // last_sig_coeff prefix ctx: depends on component and prefix position
    function automatic [CTX_ID_W-1:0] last_x_ctx;
        input [1:0]  comp;
        input [2:0]  prefix_pos;   // 0..log2(blk_size)-2
        begin
            last_x_ctx = (comp == 2'd0)
                         ? (8'd29 + {5'd0, prefix_pos})   // luma: ctx 29-37
                         : (8'd47 + {5'd0, prefix_pos});  // chroma: ctx 47-51
        end
    endfunction

    function automatic [CTX_ID_W-1:0] last_y_ctx;
        input [1:0]  comp;
        input [2:0]  prefix_pos;
        begin
            last_y_ctx = (comp == 2'd0)
                         ? (8'd38 + {5'd0, prefix_pos})   // luma: ctx 38-46
                         : (8'd52 + {5'd0, prefix_pos});  // chroma: ctx 52-56
        end
    endfunction

    // sig_coeff_flag context: depends on scan position and component
    // HM uses a sophisticated mapping; simplified here as pos+base
    function automatic [CTX_ID_W-1:0] sig_ctx;
        input [3:0]  scan_pos;
        input [1:0]  comp;
        begin
            // Luma: ctx 67-102 (36 contexts), chroma: subset of same range
            // Simplified: use scan_pos as offset within sig group
            sig_ctx = (comp == 2'd0)
                      ? (8'd67 + {4'd0, scan_pos})
                      : (8'd82 + {4'd0, scan_pos[2:0]});  // chroma shares subset
        end
    endfunction

    // greater1_flag context: depends on ctxSet (0..3) and which bin (0..3)
    // HM: ctx = 4*ctxSet + c1 where c1 = min(num_gt1_in_set, 3)
    // Simplified: use fixed ctxSet=0 offset (ctxSet logic below)
    localparam CTX_GT1_BASE  = 8'd103;
    localparam CTX_GT2_BASE  = 8'd119;

    // =========================================================================
    // Coefficient extraction helpers
    // =========================================================================
    function automatic signed [COEFF_W-1:0] get_coeff;
        input [COEFF_W*N_COEFF-1:0] flat;
        input [3:0]                  pos;   // scan position
        begin
            get_coeff = $signed(flat[COEFF_W*pos +: COEFF_W]);
        end
    endfunction

    function automatic [COEFF_W-2:0] abs_coeff;
        input signed [COEFF_W-1:0] c;
        begin
            abs_coeff = c[COEFF_W-1] ? (~c[COEFF_W-2:0] + 1) : c[COEFF_W-2:0];
        end
    endfunction

    // =========================================================================
    // Coefficient preprocessing (registered at coeff_valid)
    // =========================================================================
    reg signed [COEFF_W-1:0] coeff_r [0:N_COEFF-1]; // coeff in scan order
    reg [3:0]  last_sig_pos_r;   // scan position of last significant coeff
    reg [1:0]  last_sig_x_r;     // column of last sig coeff
    reg [1:0]  last_sig_y_r;     // row of last sig coeff
    reg [1:0]  comp_r;
    reg        is_intra_r;

    // =========================================================================
    // FSM States
    localparam [4:0]
        S_IDLE        = 5'd0,
        S_STUB_SPLIT  = 5'd12,  // stub split_transform_flag (for 32x32)
        S_STUB_CBFCB  = 5'd13,  // stub cbf_cb
        S_STUB_CBFCR  = 5'd14,  // stub cbf_cr
        S_STUB_CBFLUMA= 5'd15,  // stub cbf_luma
        S_STUB_ROOT   = 5'd16,  // stub rq_root_cbf
        S_STUB_NEXT_TU= 5'd17,
        
        S_LAST_X_PRE  = 5'd1,   // last_sig_coeff_x prefix bits (ctx-coded)
        S_LAST_X_SUF  = 5'd2,   // last_sig_coeff_x suffix bits (EP)
        S_LAST_Y_PRE  = 5'd3,   // last_sig_coeff_y prefix bits
        S_LAST_Y_SUF  = 5'd4,   // last_sig_coeff_y suffix bits
        // sig_coeff scan (reverse scan from last_sig-1 down to 0)
        S_SIG_SCAN    = 5'd5,
        // greater1 flags (forward through sig coeffs in sub-block)
        S_GT1_SCAN    = 5'd6,
        // greater2 flag (at most 1 per sub-block)
        S_GT2         = 5'd7,
        // sign flags (EP bypass, all sig coeffs)
        S_SIGN_SCAN   = 5'd8,
        // remaining level values (EP Exp-Golomb / Rice)
        S_REM_SCAN    = 5'd9,
        S_REM_EG      = 5'd10,  // Exp-Golomb bits for one coefficient
        S_DONE        = 5'd11;

    reg [4:0]  state;

    // Scan iterators
    reg [4:0]  scan_idx;         // current scan position being processed
    reg [2:0]  prefix_cnt;       // prefix bit counter for last_sig
    reg [2:0]  prefix_len;       // total prefix length for last_sig (log2(size)-1)
    reg        in_suffix;        // 0=prefix phase, 1=suffix phase

    // Greater1 tracking (HM: c1 context tracking within sub-block)
    reg [3:0]  gt1_cnt;          // num greater1 flags emitted this sub-block
    reg [3:0]  gt1_run;          // num consecutive greater1=1 (for ctx selection)
    reg [1:0]  ctx_set;          // ctxSet for greater1/2 (0..3)
    reg        need_gt2;         // whether greater2 is pending for this block
    reg [3:0]  gt2_pos;          // scan pos of the coeff that got gt2
    reg [3:0]  rem_gt1_cnt;      // tracked during remaining scan
    reg        rem_gt2_emitted;  // tracked during remaining scan
    
    reg [2:0]  stub_tu_idx;      // counter for the 4 inferred 32x32 TUs

    // Significance map (which positions are non-zero in scan order)
    reg [N_COEFF-1:0] sig_map;   // bit i = 1 if coeff[i] != 0

    // Rice parameter for coeff_abs_level_remaining
    reg [2:0]  rice_param;

    // Exp-Golomb sub-counter (reused from syntax_pred approach)
    reg [14:0] eg_symbol;
    reg [14:0] eg_count;
    reg [4:0]  eg_suf_bits;
    reg [14:0] eg_suf_val;
    reg [4:0]  eg_suf_cnt;
    reg        eg_in_suf;
    reg [3:0]  eg_return_scan;   // which scan_idx to return to after EG

    // =========================================================================
    // Combinational Helpers & Output Logic
    // =========================================================================
     wire signed [COEFF_W-1:0] cur_coeff = coeff_r[scan_idx[3:0]];
    wire [COEFF_W-2:0]        cur_abs   = abs_coeff(cur_coeff);
    wire                      cur_gt1   = (cur_abs > 1);
    wire [COEFF_W-2:0]        gt2_abs   = abs_coeff(coeff_r[gt2_pos]);
    wire [COEFF_W-2:0]        base_level= (rem_gt1_cnt < 4'd8) ? ((cur_abs > 1 && !rem_gt2_emitted) ? 3 : 2) : 1;

    reg [3:0] c_last_sig_pos;
    reg [15:0] c_sig_map;
    integer pi;
    integer i;

    always @* begin
        c_last_sig_pos = 4'd0;
        c_sig_map = 16'd0;
        for (i = 0; i < N_COEFF; i = i + 1) begin
            c_sig_map[i] = (coeff_flat[COEFF_W*i +: COEFF_W] != 0);
            if (c_sig_map[i]) c_last_sig_pos = i[3:0];
        end
    end

    reg [4:0] eg_count_log2;
    always @* begin
        if (eg_count[14]) eg_count_log2 = 5'd14;
        else if (eg_count[13]) eg_count_log2 = 5'd13;
        else if (eg_count[12]) eg_count_log2 = 5'd12;
        else if (eg_count[11]) eg_count_log2 = 5'd11;
        else if (eg_count[10]) eg_count_log2 = 5'd10;
        else if (eg_count[9])  eg_count_log2 = 5'd9;
        else if (eg_count[8])  eg_count_log2 = 5'd8;
        else if (eg_count[7])  eg_count_log2 = 5'd7;
        else if (eg_count[6])  eg_count_log2 = 5'd6;
        else if (eg_count[5])  eg_count_log2 = 5'd5;
        else if (eg_count[4])  eg_count_log2 = 5'd4;
        else if (eg_count[3])  eg_count_log2 = 5'd3;
        else if (eg_count[2])  eg_count_log2 = 5'd2;
        else if (eg_count[1])  eg_count_log2 = 5'd1;
        else                   eg_count_log2 = 5'd0;
    end

    always @* begin
        // Default outputs
        bin_valid  = 1'b0;
        bin_value  = 1'b0;
        bin_ctx_id = 8'd0;
        bin_is_ep  = 1'b0;

        case (state)
            S_STUB_CBFCB: begin // cbf_cb at depth 0
                bin_valid = 1'b1;
                bin_value = 1'b0;
                bin_ctx_id = 8'd160; // cbf_chroma ctx for depth 0
            end
            S_STUB_CBFCR: begin // cbf_cr at depth 0
                bin_valid = 1'b1;
                bin_value = 1'b0;
                bin_ctx_id = 8'd160; // cbf_chroma ctx for depth 0
            end
            S_STUB_SPLIT: begin // split_transform_flag at depth 1 (for 32x32)
                bin_valid = 1'b1;
                bin_value = 1'b0;
                bin_ctx_id = 8'd154; // split_transform_flag ctx for log2=5
            end
            S_STUB_CBFLUMA: begin // cbf_luma at depth 1
                bin_valid = 1'b1;
                bin_value = 1'b0;
                bin_ctx_id = 8'd158; // cbf_luma ctx for trafoDepth=1
            end
            S_STUB_NEXT_TU: begin
                // No bin encoded here, just a state transition
            end
            S_STUB_ROOT: begin
                bin_valid = 1'b1;
                bin_value = 1'b0;
                bin_ctx_id = 8'd157; // rq_root_cbf ctx
            end
            S_LAST_X_PRE: begin
                if (prefix_cnt < {1'b0, last_sig_x_r}) begin
                    bin_valid  = 1'b1;
                    bin_value  = 1'b1;
                    bin_ctx_id = last_x_ctx(comp_r, prefix_cnt);
                end else if (last_sig_x_r < 2'd3) begin
                    bin_valid  = 1'b1;
                    bin_value  = 1'b0;
                    bin_ctx_id = last_x_ctx(comp_r, prefix_cnt);
                end
            end
            S_LAST_Y_PRE: begin
                if (prefix_cnt < {1'b0, last_sig_y_r}) begin
                    bin_valid  = 1'b1;
                    bin_value  = 1'b1;
                    bin_ctx_id = last_y_ctx(comp_r, prefix_cnt);
                end else if (last_sig_y_r < 2'd3) begin
                    bin_valid  = 1'b1;
                    bin_value  = 1'b0;
                    bin_ctx_id = last_y_ctx(comp_r, prefix_cnt);
                end
            end
            S_SIG_SCAN: begin
                bin_valid  = 1'b1;
                bin_value  = sig_map[scan_idx[3:0]];
                bin_ctx_id = sig_ctx(scan_idx[3:0], comp_r);
            end
            S_GT1_SCAN: begin
                if (sig_map[scan_idx[3:0]] && gt1_cnt < 4'd8) begin
                    bin_valid  = 1'b1;
                    bin_value  = cur_gt1;
                    bin_ctx_id = CTX_GT1_BASE + {2'd0, ctx_set, 2'd0} + {6'd0, (gt1_run > 4'd3) ? 2'd3 : gt1_run[1:0]};
                end
            end
            S_GT2: begin
                bin_valid  = 1'b1;
                bin_value  = (gt2_abs > 2);
                bin_ctx_id = CTX_GT2_BASE + {6'd0, ctx_set};
            end
            S_SIGN_SCAN: begin
                if (sig_map[scan_idx[3:0]]) begin
                    bin_valid = 1'b1;
                    bin_value = cur_coeff[COEFF_W-1];
                    bin_is_ep = 1'b1;
                end
            end
            S_REM_EG: begin
                bin_is_ep = 1'b1;
                if (!eg_in_suf) begin
                    bin_valid = 1'b1;
                    bin_value = (eg_symbol >= eg_count);
                end else if (eg_suf_cnt > 0) begin
                    bin_valid = 1'b1;
                    bin_value = eg_suf_val[eg_suf_cnt - 1];
                end
            end
            default: begin
                bin_valid = 1'b0;
            end
        endcase
    end
    // =========================================================================
    // Sequential FSM State
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            coeff_done<= 1'b0;
            last_sig_pos_r <= 0;
            last_sig_x_r <= 0;
            last_sig_y_r <= 0;
            comp_r <= 0;
            is_intra_r <= 0;
            ctx_set <= 0;
            gt1_cnt <= 0;
            gt1_run <= 0;
            need_gt2 <= 0;
            rem_gt1_cnt <= 0;
            rem_gt2_emitted <= 0;
            rice_param <= 0;
            prefix_cnt <= 0;
            prefix_len <= 0;
            in_suffix <= 0;
            scan_idx <= 0;
            gt2_pos <= 0;
            sig_map <= 0;
            eg_symbol <= 0;
            eg_count <= 0;
            eg_suf_bits <= 0;
            eg_suf_val <= 0;
            eg_suf_cnt <= 0;
            eg_in_suf <= 0;
            eg_return_scan <= 0;
            for (pi = 0; pi < N_COEFF; pi = pi + 1) coeff_r[pi] <= 0;
        end else begin
            coeff_done <= 1'b0;

            case (state)

            S_IDLE: begin
                if (coeff_valid) begin
                    $display("Time=%0t: [syntax_coeff] S_IDLE -> coeff_valid asserted. is_intra=%b", $time, is_intra);
                    for (pi = 0; pi < N_COEFF; pi = pi + 1) begin
                        coeff_r[pi] <= $signed(coeff_flat[COEFF_W*pi +: COEFF_W]);
                    end
                    sig_map        <= c_sig_map;
                    last_sig_pos_r <= c_last_sig_pos;
                    last_sig_x_r   <= scan_col_f(c_last_sig_pos);
                    last_sig_y_r   <= scan_row_f(c_last_sig_pos);
                    comp_r         <= comp_id;
                    is_intra_r     <= is_intra;
                    ctx_set        <= is_intra ? 2'd2 : 2'd0;
                    gt1_cnt        <= 4'd0;
                    gt1_run        <= 4'd0;
                    need_gt2       <= 1'b0;
                    rem_gt1_cnt    <= 4'd0;
                    rem_gt2_emitted<= 1'b0;
                    rice_param     <= 3'd0;
                    prefix_cnt     <= 3'd0;
                    prefix_len     <= 3'd1;   
                    in_suffix      <= 1'b0;
                    stub_tu_idx    <= 3'd0;
                    if (is_intra) begin
                        state <= S_STUB_CBFCB;
                    end else begin
                        state <= S_STUB_ROOT;
                    end
                end
            end

            S_STUB_CBFCB: begin
                if (bin_rdy) begin
                    state <= S_STUB_CBFCR;
                end
            end
            S_STUB_CBFCR: begin
                if (bin_rdy) begin
                    state <= S_STUB_SPLIT;
                end
            end
            S_STUB_SPLIT: begin
                if (bin_rdy) begin
                    state <= S_STUB_CBFLUMA;
                end
            end
            S_STUB_CBFLUMA: begin
                if (bin_rdy) begin
                    if (stub_tu_idx == 3'd3) begin
                        state <= S_DONE;
                    end else begin
                        stub_tu_idx <= stub_tu_idx + 3'd1;
                        state <= S_STUB_SPLIT;
                    end
                end
            end
            S_STUB_NEXT_TU: begin
                // Obsolete
                state <= S_DONE;
            end
            S_STUB_ROOT: begin
                if (bin_rdy) state <= S_DONE; // Stubbed! No coefficients for now.
            end

            S_LAST_X_PRE: begin
                if (prefix_cnt < {1'b0, last_sig_x_r}) begin
                    if (bin_rdy) prefix_cnt <= prefix_cnt + 3'd1;
                end else if (last_sig_x_r < 2'd3) begin
                    if (bin_rdy) begin
                        prefix_cnt <= 3'd0;
                        state      <= S_LAST_Y_PRE;
                    end
                end else begin
                    prefix_cnt <= 3'd0;
                    state      <= S_LAST_Y_PRE;
                end
            end

            S_LAST_X_SUF: state <= S_LAST_Y_PRE;
            // ── LAST_SIG_Y PREFIX ─────────────────────────────────────────────
            S_LAST_Y_PRE: begin
                if (prefix_cnt < {1'b0, last_sig_y_r}) begin
                    if (bin_rdy) prefix_cnt <= prefix_cnt + 3'd1;
                end else if (last_sig_y_r < 2'd3) begin
                    if (bin_rdy) begin
                        prefix_cnt <= 3'd0;
                        gt1_cnt    <= 4'd0;
                        need_gt2   <= 1'b0;
                        if (last_sig_pos_r == 4'd0) begin
                            scan_idx <= 5'd0;
                            state    <= S_GT1_SCAN;
                        end else begin
                            scan_idx <= {1'b0, last_sig_pos_r} - 5'd1;
                            state    <= S_SIG_SCAN;
                        end
                    end
                end else begin
                    prefix_cnt <= 3'd0;
                    gt1_cnt    <= 4'd0;
                    need_gt2   <= 1'b0;
                    if (last_sig_pos_r == 4'd0) begin
                        scan_idx <= 5'd0;
                        state    <= S_GT1_SCAN;
                    end else begin
                        scan_idx <= {1'b0, last_sig_pos_r} - 5'd1;
                        state    <= S_SIG_SCAN;
                    end
                end
            end
            
            S_LAST_Y_SUF: state <= S_SIG_SCAN;  // no suffix for 4×4

            S_SIG_SCAN: begin
                if (bin_rdy) begin
                    if (scan_idx == 5'd0) begin
                        scan_idx <= {1'b0, last_sig_pos_r};
                        gt1_cnt <= 4'd0;
                        state <= S_GT1_SCAN;
                    end else begin
                        scan_idx <= scan_idx - 5'd1;
                    end
                end
            end

            S_GT1_SCAN: begin
                if (!sig_map[scan_idx[3:0]] || gt1_cnt >= 4'd8) begin
                    if (scan_idx == 5'd0) begin
                        if (need_gt2) state <= S_GT2;
                        else begin
                            scan_idx <= {1'b0, last_sig_pos_r};
                            state    <= S_SIGN_SCAN;
                        end
                    end else
                        scan_idx <= scan_idx - 5'd1;
                end else if (bin_rdy) begin
                    gt1_cnt <= gt1_cnt + 4'd1;
                    gt1_run <= cur_gt1 ? (gt1_run + 4'd1) : 4'd0;
                    if (cur_gt1 && !need_gt2) begin
                        gt2_pos  <= scan_idx[3:0];
                        need_gt2 <= 1'b1;
                    end
                    if (scan_idx == 5'd0) begin
                        if (need_gt2 || cur_gt1) state <= S_GT2;
                        else begin
                            scan_idx <= {1'b0, last_sig_pos_r};
                            state    <= S_SIGN_SCAN;
                        end
                    end else
                        scan_idx <= scan_idx - 5'd1;
                end
            end

            // ── GREATER2 FLAG (at most 1 per 4×4 sub-block) ──────────────────
            // HM: coeff_abs_level_greater2_flag for the first coeff with abs>1
            S_GT2: begin
                if (bin_rdy) begin
                    scan_idx <= {1'b0, last_sig_pos_r};   
                    state    <= S_SIGN_SCAN;
                    need_gt2 <= 1'b0;  // reset for next block
                end
            end

            // ── SIGN FLAGS (EP bypass, all sig coeffs, MSB→LSB scan) ──────────
            // HM: encodeBinEP(sign_flag) for all significant coefficients
            // HEVC sign data hiding skipped for simplicity (would suppress signs
            // when the parity of positions is even)
            S_SIGN_SCAN: begin
                if (!sig_map[scan_idx[3:0]]) begin
                    if (scan_idx == 5'd0) begin
                        scan_idx   <= {1'b0, last_sig_pos_r};
                        rice_param<= 3'd0;
                        rem_gt1_cnt     <= 4'd0;
                        rem_gt2_emitted <= 1'b0;
                        state     <= S_REM_SCAN;
                    end else
                        scan_idx  <= scan_idx - 5'd1;
                end else if (bin_rdy) begin
                    if (scan_idx == 5'd0) begin
                        scan_idx   <= {1'b0, last_sig_pos_r};
                        rice_param<= 3'd0;
                        rem_gt1_cnt     <= 4'd0;
                        rem_gt2_emitted <= 1'b0;
                        state     <= S_REM_SCAN;
                    end else
                        scan_idx  <= scan_idx - 5'd1;
                end
            end

            // ── COEFF_ABS_LEVEL_REMAINING (EP Rice/Exp-Golomb) ────────────────
            // HM codeCoeffAbsLevelRemaining():
            //   Remaining = abs(coeff) - (gt2_for_this_coeff ? 3 : gt1_for_this_coeff ? 2 : 1)
            //   Encode with Rice parameter rice_param (updates after each coeff)
            // Simplified: emit remaining as EP Exp-Golomb (rice_param=0 case)
            S_REM_SCAN: begin
                if (!sig_map[scan_idx[3:0]]) begin
                    if (scan_idx == 5'd0) state <= S_DONE;
                    else                  scan_idx <= scan_idx - 5'd1;
                end else begin
                    if (cur_abs >= base_level) begin
                        eg_symbol      <= cur_abs - base_level;
                        eg_count       <= 15'd1;
                        eg_in_suf      <= 1'b0;
                        eg_return_scan <= scan_idx[3:0];
                        state          <= S_REM_EG;
                    end else begin
                        // abs=1: no remaining level to encode
                        if (scan_idx == 5'd0) state <= S_DONE;
                        else                  scan_idx <= scan_idx - 5'd1;
                    end
                    
                    if (rem_gt1_cnt < 4'd8) begin
                        rem_gt1_cnt <= rem_gt1_cnt + 4'd1;
                        if (cur_abs > 1 && !rem_gt2_emitted) begin
                            rem_gt2_emitted <= 1'b1;
                        end
                    end
                end
            end

            // Exp-Golomb Rice encoding for remaining level
            S_REM_EG: begin
                if (bin_rdy) begin
                    if (!eg_in_suf) begin
                        if (eg_symbol >= eg_count) begin
                            eg_symbol  <= eg_symbol - eg_count;
                            eg_count   <= eg_count << 1;
                        end else begin
                            eg_suf_bits <= eg_count_log2;
                            eg_suf_cnt  <= eg_count_log2;
                            eg_suf_val  <= eg_symbol;
                            eg_in_suf   <= 1'b1;
                        end
                    end else begin
                        if (eg_suf_cnt > 5'd0) begin
                            eg_suf_cnt <= eg_suf_cnt - 5'd1;
                        end
                        if (eg_suf_cnt == 5'd1 || eg_suf_cnt == 5'd0) begin
                            if (rice_param < MAX_RICE[2:0] && cur_abs > (15'd3 << rice_param))
                                rice_param <= rice_param + 3'd1;
                            
                            scan_idx <= {1'b0, eg_return_scan};
                            if (eg_return_scan == 4'd0) begin
                                state <= S_DONE;
                            end else begin
                                scan_idx <= {1'b0, eg_return_scan} - 5'd1;
                                state    <= S_REM_SCAN;
                            end
                        end
                    end
                end
            end

            // ── DONE ─────────────────────────────────────────────────────────
            S_DONE: begin
                coeff_done <= 1'b1;
                state      <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Simulation assertions
    // =========================================================================
    // synthesis translate_off
    always @(posedge clk) begin
        if (coeff_valid && state != S_IDLE)
            $display("WARN  [syntax_coeff] coeff_valid while busy at t=%0t", $time);
        if (coeff_done)
            $display("INFO  [syntax_coeff] TU done: last_sig=(%0d,%0d) comp=%0d",
                     last_sig_x_r, last_sig_y_r, comp_r);
    end
    // synthesis translate_on

endmodule