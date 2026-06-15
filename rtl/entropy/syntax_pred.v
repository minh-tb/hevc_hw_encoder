//=============================================================================
// syntax_pred.v
// Prediction Syntax Element CABAC Encoder
//
// Mapped from HM source:
//   TLibEncoder/TEncSbac.cpp ::
//     codeInterDir()      → inter_pred_idc   (B-slice only)
//     codeRefFrmIdxLX()   → ref_idx_lX       (L0 always; L1 for B-slice)
//     codeMVPIdx()        → mvp_lX_flag      (bypass EP)
//     codeMvd()           → mvd_coding       (abs_gt0/gt1 ctx + EP Exp-Golomb)
//     xWriteMvdComponent()
//     xWriteEpExGolomb()
//
// Bin encoding order for an inter CU (non-skip, non-merge):
//
//   1. inter_pred_idc   [B-slice only, ctx 18-22, depth-dependent]
//   2. ref_idx_l0       [unary: first bin ctx=23, second ctx=24, rest EP]
//   3. mvp_l0_flag      [EP bypass, 1 bin]
//   4. mvd_l0_x:
//        abs_mvd_greater0_flag  [ctx=MVD_GT0]
//        abs_mvd_greater1_flag  [ctx=MVD_GT1, if mvd_x != 0]
//        abs_mvd_minus2         [EP Exp-Golomb order 1, if |mvd_x| > 1]
//        mvd_sign_flag          [EP bypass, if mvd_x != 0]
//   5. mvd_l0_y:        [same structure as mvd_l0_x]
//   6. (B-slice): repeat 2-5 for L1 if inter_pred_idc includes L1
//
// MVD Exp-Golomb (HM xWriteEpExGolomb, order k=1):
//   symbol = |mvd| - 2   (abs_mvd_minus2)
//   while (symbol >= count):  encodeBinEP(1); symbol-=count; count<<=1
//   encodeBinEP(0)            (terminator)
//   write floor(log2(count)) suffix bits as EP
//
// Context assignments (matching ctx_model_store.v block map):
//   CTX_INTER_DIR_base = 18   (5 contexts: depth 0-3 + one extra)
//   CTX_REF_IDX_0      = 23
//   CTX_REF_IDX_1      = 24
//   CTX_MVP_FLAG       = 25
//   CTX_MVD_GT0        = 27   (abs_mvd_greater0_flag, same ctx for x and y)
//   CTX_MVD_GT1        = 28   (abs_mvd_greater1_flag)
//
// Architecture — flat FSM with Exp-Golomb sub-counter:
//   One bin output per clock when bin_rdy=1.
//   S_EG_PREFIX / S_EG_SUFFIX states iterate for variable-length MVD EG codes.
//   Maximum MVD = ±2048 qpel → abs_mvd_minus2 ≤ 2046 → EG length ≤ 24 bins.
//
// Parameters:
//   MVD_W   : MVD bit width including sign (signed, e.g. 12-bit covers ±2048 qpel)
//   MAX_REF : max reference frames per list (determines ref_idx unary length)
//=============================================================================

`include "parameter_pkg.vh"

module syntax_pred #(
    parameter CTX_ID_W = 8,
    parameter MVD_W    = 12,    // signed MVD width (1/4-pel units), ±2048 max
    parameter MAX_REF  = 4      // max reference frames per list (for unary code)
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // ── Prediction encoding request ───────────────────────────────────────
    input  wire                  pred_valid,   // start encoding this CU's pred syntax
    output reg                   pred_done,    // all prediction bins sent

    // ── CU prediction parameters ─────────────────────────────────────────
    input  wire                  slice_is_b,   // 1=B-slice (encode inter_dir + L1)
    input  wire [1:0]            cu_depth,     // for inter_dir ctx selection
    input  wire [1:0]            inter_dir,    // 0=L0, 1=L1, 2=Bi (B-slice)

    // Intra prediction (when cu_pred_intra == 1)
    input  wire                  cu_pred_intra,
    input  wire                  prev_intra_luma_pred_flag,
    input  wire [1:0]            mpm_idx,
    input  wire [4:0]            rem_intra_luma_pred_mode,
    input  wire [2:0]            intra_chroma_pred_mode,

    // L0 prediction
    input  wire [2:0]            ref_idx_l0,   // reference frame index (0..MAX_REF-1)
    input  wire                  mvp_flag_l0,  // AMVP candidate index (0 or 1)
    input  wire signed [MVD_W-1:0] mvd_l0_x,  // motion vector difference X
    input  wire signed [MVD_W-1:0] mvd_l0_y,  // motion vector difference Y

    // L1 prediction (B-slice only)
    input  wire [2:0]            ref_idx_l1,
    input  wire                  mvp_flag_l1,
    input  wire signed [MVD_W-1:0] mvd_l1_x,
    input  wire signed [MVD_W-1:0] mvd_l1_y,

    // ── Bin output → bin_encoder ──────────────────────────────────────────
    output reg                   bin_valid,
    output reg                   bin_value,
    output reg [CTX_ID_W-1:0]    bin_ctx_id,
    output reg                   bin_is_ep,
    input  wire                  bin_rdy
);

    // =========================================================================
    // Context constants (matching ctx_model_store.v assignment)
    // =========================================================================
    localparam CTX_INTER_DIR_BASE = 8'd18;  // +depth for the 5 inter_dir contexts
    localparam CTX_REF_IDX_0      = 8'd23;
    localparam CTX_REF_IDX_1      = 8'd24;
    localparam CTX_MVP_FLAG        = 8'd25;
    localparam CTX_MVD_GT0         = 8'd27;  // abs_mvd_greater0_flag
    localparam CTX_MVD_GT1         = 8'd28;  // abs_mvd_greater1_flag

    // =========================================================================
    // FSM state encoding
    // =========================================================================
    localparam [4:0]
        S_IDLE         = 5'd0,
        // Inter direction (B-slice)
        S_INTER_DIR    = 5'd1,    // First bin for Bi-dir vs Univariate
        S_INTER_DIR_B1 = 5'd2,    // Second bin for L0 vs L1 (if Univariate)
        // L0 ref index unary code
        S_REF0_BIN0    = 5'd3,    // ref_idx_l0 != 0 ?
        S_REF0_BIN1    = 5'd4,    // ref_idx_l0 > 1  ? (ctx=24)
        S_REF0_EP      = 5'd5,    // ref_idx_l0 > 2..MAX_REF-2 (EP)
        // L0 MVD x component
        S_MVD0_X_GT0   = 5'd6,
        S_MVD0_X_GT1   = 5'd7,
        S_MVD0_X_EG    = 5'd8,    // Exp-Golomb prefix+suffix (iterates)
        S_MVD0_X_SIGN  = 5'd9,
        // L0 MVD y component
        S_MVD0_Y_GT0   = 5'd10,
        S_MVD0_Y_GT1   = 5'd11,
        S_MVD0_Y_EG    = 5'd12,
        S_MVD0_Y_SIGN  = 5'd13,
        // L0 MVP flag (Now after MVD)
        S_MVP0         = 5'd14,
        // L1 (B-slice)
        S_REF1_BIN0    = 5'd15,
        S_REF1_BIN1    = 5'd16,
        S_REF1_EP      = 5'd17,
        // L1 MVD x component
        S_MVD1_X_GT0   = 5'd18,
        S_MVD1_X_GT1   = 5'd19,
        S_MVD1_X_EG    = 5'd20,
        S_MVD1_X_SIGN  = 5'd21,
        // L1 MVD y component
        S_MVD1_Y_GT0   = 5'd22,
        S_MVD1_Y_GT1   = 5'd23,
        S_MVD1_Y_EG    = 5'd24,
        S_MVD1_Y_SIGN  = 5'd25,
        // L1 MVP flag (Now after MVD)
        S_MVP1         = 5'd26,
        
        // Intra Prediction
        S_INTRA_PREV   = 5'd27,
        S_INTRA_MPM    = 5'd28,
        S_INTRA_REM    = 5'd29,
        S_INTRA_CHROMA = 5'd30,
        
        S_DONE         = 5'd31;


    reg [4:0] state;

    // =========================================================================
    // MVD absolute values and sign (computed once at pred_valid)
    // =========================================================================
    reg [MVD_W-1:0] abs_mvd_l0_x, abs_mvd_l0_y;
    reg [MVD_W-1:0] abs_mvd_l1_x, abs_mvd_l1_y;
    reg             sign_mvd_l0_x, sign_mvd_l0_y;
    reg             sign_mvd_l1_x, sign_mvd_l1_y;

    // =========================================================================
    // Exp-Golomb sub-counter (HM xWriteEpExGolomb, order=1)
    // =========================================================================
    reg [11:0] eg_symbol;    // abs_mvd_minus2 = |mvd|-2
    reg [11:0] eg_count;     // current golomb divisor (starts at 1, doubles)
    reg [4:0]  eg_suffix_bits; // number of suffix bits to emit
    reg [11:0] eg_suffix_val;  // suffix value
    reg [4:0]  eg_suffix_cnt;  // suffix bits remaining
    reg        eg_in_suffix;   // 0=prefix, 1=suffix

    // Ref idx EP counter (for ref_idx > 2)
    reg [2:0] ref_ep_cnt;    // which EP bin we're on (starts at 2)
    reg [2:0] ref_ep_refidx; // latched ref_idx for EP iterations
    reg       ref_ep_is_l1;  // which list

    // =========================================================================
    // Latch inputs at pred_valid
    // =========================================================================
    reg [1:0]  inter_dir_r;
    reg [2:0]  ref_l0_r, ref_l1_r;
    reg        mvp_l0_r, mvp_l1_r;
    reg        is_b_r;
    reg [1:0]  depth_r;
    reg        pred_intra_r;
    reg        prev_intra_r;
    reg [1:0]  mpm_idx_r;
    reg [4:0]  rem_intra_r;
    reg [2:0]  chroma_mode_r;

    // =========================================================================
    // Helper: compute inter_dir context
    // HM: getCtxInterDir() = min(depth, 3)
    // =========================================================================
    wire [CTX_ID_W-1:0] inter_dir_ctx = CTX_INTER_DIR_BASE + {6'd0, depth_r};

    // =========================================================================
    // Combinational Bin Output Logic
    // =========================================================================
    always @* begin
        // Default values
        bin_valid  = 1'b0;
        bin_value  = 1'b0;
        bin_ctx_id = 8'd0;
        bin_is_ep  = 1'b0;

        case (state)
            S_INTER_DIR: begin
                bin_valid  = 1'b1;
                bin_value  = (inter_dir_r == 2'd2);
                bin_ctx_id = inter_dir_ctx;
            end
            S_INTER_DIR_B1: begin
                bin_valid  = 1'b1;
                bin_value  = (inter_dir_r == 2'd1);
                bin_ctx_id = CTX_INTER_DIR_BASE + 8'd4;
            end
            S_REF0_BIN0: begin
                bin_valid  = 1'b1;
                bin_value  = (ref_l0_r != 3'd0);
                bin_ctx_id = CTX_REF_IDX_0;
            end
            S_REF0_BIN1: begin
                bin_valid  = 1'b1;
                bin_value  = (ref_l0_r > 3'd1);
                bin_ctx_id = CTX_REF_IDX_1;
            end
            S_REF0_EP: begin
                bin_valid = 1'b1;
                bin_value = (ref_ep_cnt < ref_ep_refidx);
                bin_is_ep = 1'b1;
            end
            S_MVD0_X_GT0: begin
                bin_valid  = 1'b1;
                bin_value  = (abs_mvd_l0_x != 0);
                bin_ctx_id = CTX_MVD_GT0;
            end
            S_MVD0_X_GT1: begin
                bin_valid  = 1'b1;
                bin_value  = (abs_mvd_l0_x > 1);
                bin_ctx_id = CTX_MVD_GT1;
            end
            S_MVD0_X_EG: begin
                if (!eg_in_suffix) begin
                    bin_valid = 1'b1;
                    bin_value = (eg_symbol >= eg_count);
                    bin_is_ep = 1'b1;
                end else if (eg_suffix_cnt > 0) begin
                    bin_valid = 1'b1;
                    bin_value = eg_suffix_val[eg_suffix_cnt - 1];
                    bin_is_ep = 1'b1;
                end
            end
            S_MVD0_X_SIGN: begin
                bin_valid = 1'b1;
                bin_value = sign_mvd_l0_x;
                bin_is_ep = 1'b1;
            end
            S_MVD0_Y_GT0: begin
                bin_valid  = 1'b1;
                bin_value  = (abs_mvd_l0_y != 0);
                bin_ctx_id = CTX_MVD_GT0;
            end
            S_MVD0_Y_GT1: begin
                bin_valid  = 1'b1;
                bin_value  = (abs_mvd_l0_y > 1);
                bin_ctx_id = CTX_MVD_GT1;
            end
            S_INTRA_PREV: begin // prev_intra_luma_pred_flag
                bin_valid  = 1'b1;
                bin_value  = 1'b1; // say 1
                bin_ctx_id = 8'd14; // prev_intra_luma_pred_flag ctx
            end
            S_INTRA_MPM: begin
                bin_valid = 1'b1;
                bin_value = (eg_symbol == 0) ? 1'b0 : (eg_symbol == 1) ? 1'b1 : mpm_idx_r[0]; // Wait, eg_symbol used as step!
                bin_is_ep = 1'b1;
            end
            S_INTRA_REM: begin
                bin_valid = 1'b1;
                bin_value = rem_intra_r[4 - eg_symbol]; // eg_symbol used as bit index
                bin_is_ep = 1'b1;
            end
            S_INTRA_CHROMA: begin
                bin_valid = 1'b1;
                if (eg_symbol == 0) begin
                    bin_value = (chroma_mode_r != 4);
                    bin_ctx_id = 8'd16; // intra_chroma_pred_mode ctx
                end else begin
                    bin_value = chroma_mode_r[2 - eg_symbol];
                    bin_is_ep = 1'b1;
                end
            end

            S_MVD0_Y_EG: begin
                if (!eg_in_suffix) begin
                    bin_valid = 1'b1;
                    bin_value = (eg_symbol >= eg_count);
                    bin_is_ep = 1'b1;
                end else if (eg_suffix_cnt > 0) begin
                    bin_valid = 1'b1;
                    bin_value = eg_suffix_val[eg_suffix_cnt - 1];
                    bin_is_ep = 1'b1;
                end
            end
            S_MVD0_Y_SIGN: begin
                bin_valid = 1'b1;
                bin_value = sign_mvd_l0_y;
                bin_is_ep = 1'b1;
            end
            S_MVP0: begin
                bin_valid = 1'b1;
                bin_value = mvp_l0_r;
                bin_is_ep = 1'b1;
            end
            S_REF1_BIN0: begin
                bin_valid  = 1'b1;
                bin_value  = (ref_l1_r != 3'd0);
                bin_ctx_id = CTX_REF_IDX_0;
            end
            S_REF1_BIN1: begin
                bin_valid  = 1'b1;
                bin_value  = (ref_l1_r > 3'd1);
                bin_ctx_id = CTX_REF_IDX_1;
            end
            S_REF1_EP: begin
                bin_valid = 1'b1;
                bin_value = (ref_ep_cnt < ref_ep_refidx);
                bin_is_ep = 1'b1;
            end
            S_MVD1_X_GT0: begin
                bin_valid  = 1'b1;
                bin_value  = (abs_mvd_l1_x != 0);
                bin_ctx_id = CTX_MVD_GT0;
            end
            S_MVD1_X_GT1: begin
                bin_valid  = 1'b1;
                bin_value  = (abs_mvd_l1_x > 1);
                bin_ctx_id = CTX_MVD_GT1;
            end
            S_MVD1_X_EG: begin
                if (!eg_in_suffix) begin
                    bin_valid = 1'b1;
                    bin_value = (eg_symbol >= eg_count);
                    bin_is_ep = 1'b1;
                end else if (eg_suffix_cnt > 0) begin
                    bin_valid = 1'b1;
                    bin_value = eg_suffix_val[eg_suffix_cnt - 1];
                    bin_is_ep = 1'b1;
                end
            end
            S_MVD1_X_SIGN: begin
                bin_valid = 1'b1;
                bin_value = sign_mvd_l1_x;
                bin_is_ep = 1'b1;
            end
            S_MVD1_Y_GT0: begin
                bin_valid  = 1'b1;
                bin_value  = (abs_mvd_l1_y != 0);
                bin_ctx_id = CTX_MVD_GT0;
            end
            S_MVD1_Y_GT1: begin
                bin_valid  = 1'b1;
                bin_value  = (abs_mvd_l1_y > 1);
                bin_ctx_id = CTX_MVD_GT1;
            end
            S_MVD1_Y_EG: begin
                if (!eg_in_suffix) begin
                    bin_valid = 1'b1;
                    bin_value = (eg_symbol >= eg_count);
                    bin_is_ep = 1'b1;
                end else if (eg_suffix_cnt > 0) begin
                    bin_valid = 1'b1;
                    bin_value = eg_suffix_val[eg_suffix_cnt - 1];
                    bin_is_ep = 1'b1;
                end
            end
            S_MVD1_Y_SIGN: begin
                bin_valid = 1'b1;
                bin_value = sign_mvd_l1_y;
                bin_is_ep = 1'b1;
            end
            S_MVP1: begin
                bin_valid = 1'b1;
                bin_value = mvp_l1_r;
                bin_is_ep = 1'b1;
            end
            default: begin
                bin_valid = 1'b0;
            end
        endcase
    end

    // =========================================================================
    // Combinational Log2 of eg_count for Exp-Golomb suffix
    // =========================================================================
    reg [4:0] eg_count_log2;
    always @* begin
        if (eg_count[11]) eg_count_log2 = 5'd11;
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            pred_done <= 1'b0;
            abs_mvd_l0_x <= 0;
            abs_mvd_l0_y <= 0;
            abs_mvd_l1_x <= 0;
            abs_mvd_l1_y <= 0;
            sign_mvd_l0_x <= 0;
            sign_mvd_l0_y <= 0;
            sign_mvd_l1_x <= 0;
            sign_mvd_l1_y <= 0;
            eg_symbol <= 0;
            eg_count <= 0;
            eg_suffix_bits <= 0;
            eg_suffix_val <= 0;
            eg_suffix_cnt <= 0;
            eg_in_suffix <= 0;
            ref_ep_cnt <= 0;
            ref_ep_refidx <= 0;
            ref_ep_is_l1 <= 0;
            inter_dir_r <= 0;
            ref_l0_r <= 0;
            ref_l1_r <= 0;
            mvp_l0_r <= 0;
            mvp_l1_r <= 0;
            is_b_r <= 0;
            depth_r <= 0;
        end else begin
            pred_done <= 1'b0;
            case (state)

            // ── IDLE ────────────────────────────────────────────────────────
            S_IDLE: begin
                if (pred_valid) begin
                    pred_intra_r <= cu_pred_intra;
                    if (cu_pred_intra) begin
                        prev_intra_r  <= prev_intra_luma_pred_flag;
                        mpm_idx_r     <= mpm_idx;
                        rem_intra_r   <= rem_intra_luma_pred_mode;
                        chroma_mode_r <= intra_chroma_pred_mode;
                        state         <= S_INTRA_PREV;
                    end else begin
                        inter_dir_r <= inter_dir;
                        ref_l0_r    <= ref_idx_l0;
                        ref_l1_r    <= ref_idx_l1;
                        mvp_l0_r    <= mvp_flag_l0;
                        mvp_l1_r    <= mvp_flag_l1;
                        is_b_r      <= slice_is_b;
                        depth_r     <= cu_depth;
                        // Compute absolute values and signs
                        abs_mvd_l0_x <= mvd_l0_x[MVD_W-1] ? -mvd_l0_x : mvd_l0_x;
                        abs_mvd_l0_y <= mvd_l0_y[MVD_W-1] ? -mvd_l0_y : mvd_l0_y;
                        abs_mvd_l1_x <= mvd_l1_x[MVD_W-1] ? -mvd_l1_x : mvd_l1_x;
                        abs_mvd_l1_y <= mvd_l1_y[MVD_W-1] ? -mvd_l1_y : mvd_l1_y;
                        sign_mvd_l0_x <= mvd_l0_x[MVD_W-1];
                        sign_mvd_l0_y <= mvd_l0_y[MVD_W-1];
                        sign_mvd_l1_x <= mvd_l1_x[MVD_W-1];
                        sign_mvd_l1_y <= mvd_l1_y[MVD_W-1];
                        state <= slice_is_b ? S_INTER_DIR : S_REF0_BIN0;
                    end
                end
            end

            S_INTER_DIR: begin
                if (bin_rdy) state <= (inter_dir_r == 2'd2) ? S_REF0_BIN0 : S_INTER_DIR_B1;
            end

            S_INTER_DIR_B1: begin
                if (bin_rdy) state <= (inter_dir_r == 2'd1) ? S_REF1_BIN0 : S_REF0_BIN0;
            end
            S_REF0_BIN0: begin
                if (bin_rdy) state <= (ref_l0_r == 3'd0) ? S_MVD0_X_GT0 : S_REF0_BIN1;
            end

            S_REF0_BIN1: begin
                if (bin_rdy) begin
                    if (ref_l0_r <= 3'd1) state <= S_MVD0_X_GT0;
                    else begin
                        ref_ep_cnt    <= 3'd2;
                        ref_ep_refidx <= ref_l0_r;
                        state         <= S_REF0_EP;
                    end
                end
            end

            S_REF0_EP: begin
                if (bin_rdy) begin
                    if (ref_ep_cnt >= ref_ep_refidx) state <= S_MVD0_X_GT0;
                    else ref_ep_cnt <= ref_ep_cnt + 3'd1;
                end
            end
            S_MVD0_X_GT0: begin
                if (bin_rdy) state <= (abs_mvd_l0_x == 0) ? S_MVD0_Y_GT0 : S_MVD0_X_GT1;
            end
            S_MVD0_X_GT1: begin
                if (bin_rdy) begin
                    if (abs_mvd_l0_x > 1) begin
                        eg_symbol  <= abs_mvd_l0_x - 12'd2;
                        eg_count   <= 12'd2;
                        eg_in_suffix <= 1'b0;
                        state      <= S_MVD0_X_EG;
                    end else state <= S_MVD0_X_SIGN;
                end
            end
            S_MVD0_X_EG: begin
                if (bin_rdy) begin
                    if (!eg_in_suffix) begin
                        if (eg_symbol >= eg_count) begin
                            eg_symbol <= eg_symbol - eg_count;
                            eg_count  <= eg_count << 1;
                        end else begin
                            eg_suffix_bits <= eg_count_log2;
                            eg_suffix_cnt  <= eg_count_log2;
                            eg_suffix_val  <= eg_symbol;
                            eg_in_suffix <= 1'b1;
                        end
                    end else begin
                        if (eg_suffix_cnt > 5'd0) begin
                            eg_suffix_cnt<= eg_suffix_cnt - 5'd1;
                        end 
                        if (eg_suffix_cnt == 5'd1 || eg_suffix_cnt == 5'd0) begin
                            state <= S_MVD0_X_SIGN;
                        end
                    end
                end
            end

            S_MVD0_X_SIGN: begin
                if (bin_rdy) state <= S_MVD0_Y_GT0;
            end

            // ── MVD L0 Y (same structure as X) ──────────────────────────────
            S_MVD0_Y_GT0: begin
                if (bin_rdy) state <= (abs_mvd_l0_y == 0) ? S_MVP0 : S_MVD0_Y_GT1;
            end

            S_MVD0_Y_GT1: begin
                if (bin_rdy) begin
                    if (abs_mvd_l0_y > 1) begin
                        eg_symbol    <= abs_mvd_l0_y - 12'd2;
                        eg_count     <= 12'd2;
                        eg_in_suffix <= 1'b0;
                        state        <= S_MVD0_Y_EG;
                    end else state <= S_MVD0_Y_SIGN;
                end
            end

            S_MVD0_Y_EG: begin
                if (bin_rdy) begin
                    if (!eg_in_suffix) begin
                        if (eg_symbol >= eg_count) begin
                            eg_symbol <= eg_symbol - eg_count;
                            eg_count  <= eg_count << 1;
                        end else begin
                            eg_suffix_bits <= eg_count_log2;
                            eg_suffix_cnt  <= eg_count_log2;
                            eg_suffix_val  <= eg_symbol;
                            eg_in_suffix <= 1'b1;
                        end
                    end else begin
                        if (eg_suffix_cnt > 5'd0) begin
                            eg_suffix_cnt<= eg_suffix_cnt - 5'd1;
                        end
                        if (eg_suffix_cnt == 5'd1 || eg_suffix_cnt == 5'd0) begin
                            state <= S_MVD0_Y_SIGN;
                        end
                    end
                end
            end

            S_IDLE: begin
                if (pred_valid) begin
                    $display("Time=%0t: [syntax_pred] S_IDLE -> starting. is_b=%b, intra=%b", $time, slice_is_b, pred_intra_r);
                    pred_done <= 1'b0;
                    if (pred_intra_r) begin
                        state <= S_INTRA_PREV;
                    end else if (slice_is_b) begin
                        state <= S_INTER_DIR;
                    end else begin
                        state <= S_REF0_BIN0;
                    end
                end
            end

            S_MVD0_Y_SIGN: begin
                if (bin_rdy) state <= S_MVP0;
            end

            S_MVP0: begin
                if (bin_rdy) state <= slice_is_b ? S_REF1_BIN0 : S_DONE;
            end
            S_REF1_BIN0: begin
                if (bin_rdy) state <= (ref_l1_r == 3'd0) ? S_MVD1_X_GT0 : S_REF1_BIN1;
            end

            S_REF1_BIN1: begin
                if (bin_rdy) begin
                    if (ref_l1_r <= 3'd1) state <= S_MVD1_X_GT0;
                    else begin
                        ref_ep_cnt    <= 3'd2;
                        ref_ep_refidx <= ref_l1_r;
                        state         <= S_REF1_EP;
                    end
                end
            end

            S_REF1_EP: begin
                if (bin_rdy) begin
                    if (ref_ep_cnt >= ref_ep_refidx) state <= S_MVD1_X_GT0;
                    else ref_ep_cnt <= ref_ep_cnt + 3'd1;
                end
            end

            S_MVD1_X_GT0: begin
                if (bin_rdy) state <= (abs_mvd_l1_x == 0) ? S_MVD1_Y_GT0 : S_MVD1_X_GT1;
            end

            S_MVD1_X_GT1: begin
                if (bin_rdy) begin
                    if (abs_mvd_l1_x > 1) begin
                        eg_symbol <= abs_mvd_l1_x - 12'd2;
                        eg_count <= 12'd2; eg_in_suffix <= 1'b0;
                        state <= S_MVD1_X_EG;
                    end else state <= S_MVD1_X_SIGN;
                end
            end

            S_MVD1_X_EG: begin
                if (bin_rdy) begin
                    if (!eg_in_suffix) begin
                        if (eg_symbol >= eg_count) begin
                            eg_symbol<=eg_symbol-eg_count; eg_count<=eg_count<<1;
                        end else begin
                            eg_suffix_bits <= eg_count_log2;
                            eg_suffix_cnt  <= eg_count_log2;
                            eg_suffix_val  <= eg_symbol;
                            eg_in_suffix   <= 1'b1;
                        end
                    end else begin
                        if (eg_suffix_cnt > 5'd0) begin
                            eg_suffix_cnt <= eg_suffix_cnt - 5'd1;
                        end 
                        if (eg_suffix_cnt == 5'd1 || eg_suffix_cnt == 5'd0) begin
                            state<=S_MVD1_X_SIGN;
                        end 
                    end
                end
            end

            S_MVD1_X_SIGN: begin
                if (bin_rdy) state <= S_MVD1_Y_GT0;
            end

            S_MVD1_Y_GT0: begin
                if (bin_rdy) state <= (abs_mvd_l1_y == 0) ? S_MVP1 : S_MVD1_Y_GT1;
            end

            S_MVD1_Y_GT1: begin
                if (bin_rdy) begin
                    if (abs_mvd_l1_y>1) begin
                        eg_symbol<=abs_mvd_l1_y-12'd2;
                        eg_count<=12'd2; eg_in_suffix<=1'b0;
                        state<=S_MVD1_Y_EG;
                    end else state<=S_MVD1_Y_SIGN;
                end
            end

            S_MVD1_Y_EG: begin
                if (bin_rdy) begin
                    if (!eg_in_suffix) begin
                        if (eg_symbol>=eg_count) begin
                            eg_symbol<=eg_symbol-eg_count; eg_count<=eg_count<<1;
                        end else begin
                            eg_suffix_bits <= eg_count_log2;
                            eg_suffix_cnt  <= eg_count_log2;
                            eg_suffix_val  <= eg_symbol;
                            eg_in_suffix   <= 1'b1;
                        end
                    end else begin
                        if (eg_suffix_cnt > 5'd0) begin
                            eg_suffix_cnt <= eg_suffix_cnt - 5'd1;
                        end 
                        if (eg_suffix_cnt == 5'd1 || eg_suffix_cnt == 5'd0) begin
                            state<=S_MVD1_Y_SIGN;
                        end
                    end
                end
            end

            S_MVD1_Y_SIGN: begin
                if (bin_rdy) state <= S_MVP1;
            end

            S_MVP1: begin
                if (bin_rdy) state <= S_DONE;
            end

            S_INTRA_PREV: begin
                if (bin_rdy) begin
                    if (prev_intra_r) begin
                        eg_symbol <= 0; // use eg_symbol as step counter
                        state <= S_INTRA_MPM;
                    end else begin
                        eg_symbol <= 0;
                        state <= S_INTRA_REM;
                    end
                end
            end
            
            S_INTRA_MPM: begin
                if (bin_rdy) begin
                    if (eg_symbol == 0 && mpm_idx_r == 0) begin
                        eg_symbol <= 0;
                        state <= S_INTRA_CHROMA;
                    end else if (eg_symbol == 0) begin
                        eg_symbol <= 1; // move to second bin
                    end else begin
                        eg_symbol <= 0;
                        state <= S_INTRA_CHROMA;
                    end
                end
            end
            
            S_INTRA_REM: begin
                if (bin_rdy) begin
                    if (eg_symbol == 4) begin
                        eg_symbol <= 0;
                        state <= S_INTRA_CHROMA;
                    end else begin
                        eg_symbol <= eg_symbol + 1;
                    end
                end
            end
            
            S_INTRA_CHROMA: begin
                if (bin_rdy) begin
                    if (eg_symbol == 0 && chroma_mode_r == 4) begin
                        $display("Time=%0t: [syntax_pred] S_INTRA_CHROMA -> S_DONE (chroma=4)", $time);
                        state <= S_DONE;
                    end else if (eg_symbol == 0) begin
                        eg_symbol <= 1;
                    end else if (eg_symbol == 2) begin
                        $display("Time=%0t: [syntax_pred] S_INTRA_CHROMA -> S_DONE", $time);
                        state <= S_DONE;
                    end else begin
                        eg_symbol <= eg_symbol + 1;
                    end
                end
            end

            // ── DONE ─────────────────────────────────────────────────────────
            S_DONE: begin
                $display("Time=%0t: [syntax_pred] S_DONE reached!", $time);
                pred_done <= 1'b1;
                state     <= S_IDLE;
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
        if (pred_valid && state != S_IDLE)
            $display("WARN  [syntax_pred] pred_valid while busy (state=%0d)", state);
        if (pred_done)
            $display("INFO  [syntax_pred] pred done: B=%0d dir=%0d ref0=%0d mvp0=%0d",
                     is_b_r, inter_dir_r, ref_l0_r, mvp_l0_r);
    end
    // synthesis translate_on

endmodule