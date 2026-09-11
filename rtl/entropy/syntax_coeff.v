//=============================================================================
// syntax_coeff.v
// Transform Coefficient CABAC Syntax Encoder (4x4, 8x8, 16x16, 32x32)
// Full HEVC RQT Multi-Sub-Block Scanning Engine
//
// Compliant with HM TDecSbac / TEncSbac:
//   1. Last Significant XY (Prefix/Suffix for X and Y)
//   2. Multi-Sub-Block Loop (CG scan from last_cg down to 0)
//   3. coded_sub_block_flag (sig_coeff_group_flag)
//   4. sig_coeff_flag (reverse diagonal scan within CG)
//   5. coeff_abs_level_greater1_flag (up to 8 per CG)
//   6. coeff_abs_level_greater2_flag (at most 1 per CG)
//   7. coeff_sign_flag (EP bypass for each non-zero coeff)
//   8. coeff_abs_level_remaining (EP bypass Exp-Golomb / Rice)
//=============================================================================

`include "parameter_pkg.vh"

module syntax_coeff #(
    parameter CTX_ID_W = 8,
    parameter COEFF_W  = 16,
    parameter MAX_RICE = 4
)(
    input  wire                          clk,
    input  wire                          rst_n,

    // ── Encoding request ────────────────────────────────────────────────────
    input  wire                          coeff_valid,  // start encoding this TU
    input  wire                          cu_valid,     // start of CU (resets tu_idx)
    input  wire [1:0]                    cu_depth,     // CU depth (0=64x64, 1=32x32, 2=16x16, 3=8x8)
    output reg                           coeff_done,   // all bins sent

    // ── TU parameters ───────────────────────────────────────────────────────
    input  wire [1:0]                    comp_id,      // 0=luma, 1=Cb, 2=Cr
    input  wire                          is_intra,     // intra: affects ctx selection
    input  wire                          is_merge,     // 1=merge mode (no rqt_root_cbf coded)
    input  wire [2:0]                    tu_size_log2, // 2=4x4, 3=8x8, 4=16x16, 5=32x32
    input  wire                          tu_cbf,       // 1 if TU contains non-zero coeffs
    input  wire [9:0]                    last_sig_pos, // scan index of last non-zero coeff

    // ── SRAM Read Port to coeff_buffer ──────────────────────────────────────
    output reg                           coeff_rd_en,
    output reg  [11:0]                   coeff_rd_addr,
    input  wire signed [COEFF_W-1:0]     coeff_rd_data,

    // ── Bin output → bin_encoder ─────────────────────────────────────────────
    output reg                           bin_valid,
    output reg                           bin_value,
    output reg  [CTX_ID_W-1:0]          bin_ctx_id,
    output reg                           bin_is_ep,
    input  wire                          bin_rdy
);

    // =========================================================================
    // Diagonal scan LUTs
    // =========================================================================
    function automatic [1:0] diag_4_row;
        input [3:0] pos;
        reg [1:0] lut [0:15];
        begin
            lut[ 0]=2'd0; lut[ 1]=2'd1; lut[ 2]=2'd0; lut[ 3]=2'd2;
            lut[ 4]=2'd1; lut[ 5]=2'd0; lut[ 6]=2'd3; lut[ 7]=2'd2;
            lut[ 8]=2'd1; lut[ 9]=2'd0; lut[10]=2'd3; lut[11]=2'd2;
            lut[12]=2'd1; lut[13]=2'd3; lut[14]=2'd2; lut[15]=2'd3;
            diag_4_row = lut[pos];
        end
    endfunction

    function automatic [1:0] diag_4_col;
        input [3:0] pos;
        reg [1:0] lut [0:15];
        begin
            lut[ 0]=2'd0; lut[ 1]=2'd0; lut[ 2]=2'd1; lut[ 3]=2'd0;
            lut[ 4]=2'd1; lut[ 5]=2'd2; lut[ 6]=2'd0; lut[ 7]=2'd1;
            lut[ 8]=2'd2; lut[ 9]=2'd3; lut[10]=2'd1; lut[11]=2'd2;
            lut[12]=2'd3; lut[13]=2'd2; lut[14]=2'd3; lut[15]=2'd3;
            diag_4_col = lut[pos];
        end
    endfunction

    function automatic [3:0] diag_8_row;
        input [5:0] pos;
        reg [3:0] lut [0:63];
        begin
            lut[ 0]=4'd0; lut[ 1]=4'd1; lut[ 2]=4'd0; lut[ 3]=4'd2;
            lut[ 4]=4'd1; lut[ 5]=4'd0; lut[ 6]=4'd3; lut[ 7]=4'd2;
            lut[ 8]=4'd1; lut[ 9]=4'd0; lut[10]=4'd4; lut[11]=4'd3;
            lut[12]=4'd2; lut[13]=4'd1; lut[14]=4'd0; lut[15]=4'd5;
            lut[16]=4'd4; lut[17]=4'd3; lut[18]=4'd2; lut[19]=4'd1;
            lut[20]=4'd0; lut[21]=4'd6; lut[22]=4'd5; lut[23]=4'd4;
            lut[24]=4'd3; lut[25]=4'd2; lut[26]=4'd1; lut[27]=4'd0;
            lut[28]=4'd7; lut[29]=4'd6; lut[30]=4'd5; lut[31]=4'd4;
            lut[32]=4'd3; lut[33]=4'd2; lut[34]=4'd1; lut[35]=4'd0;
            lut[36]=4'd7; lut[37]=4'd6; lut[38]=4'd5; lut[39]=4'd4;
            lut[40]=4'd3; lut[41]=4'd2; lut[42]=4'd1; lut[43]=4'd7;
            lut[44]=4'd6; lut[45]=4'd5; lut[46]=4'd4; lut[47]=4'd3;
            lut[48]=4'd2; lut[49]=4'd7; lut[50]=4'd6; lut[51]=4'd5;
            lut[52]=4'd4; lut[53]=4'd3; lut[54]=4'd7; lut[55]=4'd6;
            lut[56]=4'd5; lut[57]=4'd4; lut[58]=4'd7; lut[59]=4'd6;
            lut[60]=4'd5; lut[61]=4'd7; lut[62]=4'd6; lut[63]=4'd7;
            diag_8_row = lut[pos];
        end
    endfunction

    function automatic [3:0] diag_8_col;
        input [5:0] pos;
        reg [3:0] lut [0:63];
        begin
            lut[ 0]=4'd0; lut[ 1]=4'd0; lut[ 2]=4'd1; lut[ 3]=4'd0;
            lut[ 4]=4'd1; lut[ 5]=4'd2; lut[ 6]=4'd0; lut[ 7]=4'd1;
            lut[ 8]=4'd2; lut[ 9]=4'd3; lut[10]=4'd0; lut[11]=4'd1;
            lut[12]=4'd2; lut[13]=4'd3; lut[14]=4'd4; lut[15]=4'd0;
            lut[16]=4'd1; lut[17]=4'd2; lut[18]=4'd3; lut[19]=4'd4;
            lut[20]=4'd5; lut[21]=4'd0; lut[22]=4'd1; lut[23]=4'd2;
            lut[24]=4'd3; lut[25]=4'd4; lut[26]=4'd5; lut[27]=4'd6;
            lut[28]=4'd0; lut[29]=4'd1; lut[30]=4'd2; lut[31]=4'd3;
            lut[32]=4'd4; lut[33]=4'd5; lut[34]=4'd6; lut[35]=4'd7;
            lut[36]=4'd1; lut[37]=4'd2; lut[38]=4'd3; lut[39]=4'd4;
            lut[40]=4'd5; lut[41]=4'd6; lut[42]=4'd7; lut[43]=4'd2;
            lut[44]=4'd3; lut[45]=4'd4; lut[46]=4'd5; lut[47]=4'd6;
            lut[48]=4'd7; lut[49]=4'd3; lut[50]=4'd4; lut[51]=4'd5;
            lut[52]=4'd6; lut[53]=4'd7; lut[54]=4'd4; lut[55]=4'd5;
            lut[56]=4'd6; lut[57]=4'd7; lut[58]=4'd5; lut[59]=4'd6;
            lut[60]=4'd7; lut[61]=4'd6; lut[62]=4'd7; lut[63]=4'd7;
            diag_8_col = lut[pos];
        end
    endfunction

    function automatic [4:0] get_x_from_scan;
        input [9:0] scan;
        input [2:0] log2_size;
        reg [2:0] cx;
        reg [1:0] sx;
        begin
            sx = diag_4_col(scan[3:0]);
            case (log2_size)
                3'd2: get_x_from_scan = {3'd0, sx};
                3'd3: begin
                    cx = diag_4_col(scan[5:4]);
                    get_x_from_scan = {4'd0, cx[0], sx};
                end
                3'd4: begin
                    cx = diag_4_col(scan[7:4]);
                    get_x_from_scan = {3'd0, cx[1:0], sx};
                end
                default: begin // 32x32
                    cx = diag_8_col(scan[9:4]);
                    get_x_from_scan = {2'd0, cx[2:0], sx};
                end
            endcase
        end
    endfunction

    function automatic [4:0] get_y_from_scan;
        input [9:0] scan;
        input [2:0] log2_size;
        reg [2:0] cy;
        reg [1:0] sy;
        begin
            sy = diag_4_row(scan[3:0]);
            case (log2_size)
                3'd2: get_y_from_scan = {3'd0, sy};
                3'd3: begin
                    cy = diag_4_row(scan[5:4]);
                    get_y_from_scan = {4'd0, cy[0], sy};
                end
                3'd4: begin
                    cy = diag_4_row(scan[7:4]);
                    get_y_from_scan = {3'd0, cy[1:0], sy};
                end
                default: begin // 32x32
                    cy = diag_8_row(scan[9:4]);
                    get_y_from_scan = {2'd0, cy[2:0], sy};
                end
            endcase
        end
    endfunction

    function automatic [3:0] get_prefix;
        input [4:0] pos;
        begin
            case (pos)
                5'd0: get_prefix = 4'd0;
                5'd1: get_prefix = 4'd1;
                5'd2: get_prefix = 4'd2;
                5'd3: get_prefix = 4'd3;
                5'd4, 5'd5: get_prefix = 4'd4;
                5'd6, 5'd7: get_prefix = 4'd5;
                5'd8, 5'd9, 5'd10, 5'd11: get_prefix = 4'd6;
                5'd12, 5'd13, 5'd14, 5'd15: get_prefix = 4'd7;
                5'd16, 5'd17, 5'd18, 5'd19, 5'd20, 5'd21, 5'd22, 5'd23: get_prefix = 4'd8;
                default: get_prefix = 4'd9;
            endcase
        end
    endfunction

    function automatic [4:0] get_min_in_group;
        input [3:0] pfx;
        begin
            case (pfx)
                4'd4: get_min_in_group = 5'd4;
                4'd5: get_min_in_group = 5'd6;
                4'd6: get_min_in_group = 5'd8;
                4'd7: get_min_in_group = 5'd12;
                4'd8: get_min_in_group = 5'd16;
                4'd9: get_min_in_group = 5'd24;
                default: get_min_in_group = 5'd0;
            endcase
        end
    endfunction

    function automatic [COEFF_W-2:0] abs_coeff;
        input signed [COEFF_W-1:0] c;
        begin
            abs_coeff = c[COEFF_W-1] ? (~c[COEFF_W-2:0] + 1) : c[COEFF_W-2:0];
        end
    endfunction

    // =========================================================================
    // FSM States
    // =========================================================================
    localparam [4:0]
        S_IDLE        = 5'd0,
        S_STUB_SPLIT  = 5'd12,  // stub split_transform_flag
        S_STUB_CBFCB0 = 5'd13,  // stub cbf_cb at depth 0
        S_STUB_CBFCR0 = 5'd14,  // stub cbf_cr at depth 0
        S_STUB_CBFLUMA= 5'd15,  // stub cbf_luma
        S_STUB_ROOT   = 5'd16,  // stub rq_root_cbf
        S_STUB_CBFCB1 = 5'd18,  // stub cbf_cb at depth 1
        S_STUB_CBFCR1 = 5'd19,  // stub cbf_cr at depth 1

        S_LAST_X_PRE  = 5'd1,   // last_sig_x prefix bits (ctx)
        S_LAST_X_SUF  = 5'd2,   // last_sig_x suffix bits (EP)
        S_LAST_Y_PRE  = 5'd3,   // last_sig_y prefix bits (ctx)
        S_LAST_Y_SUF  = 5'd4,   // last_sig_y suffix bits (EP)

        S_LOAD_CG_REQ = 5'd20,  // Request coefficient words from SRAM
        S_LOAD_CG_WAIT= 5'd21,  // Latch coefficient words
        S_CG_FLAG     = 5'd22,  // coded_sub_block_flag
        S_SIG_SCAN    = 5'd5,   // sig_coeff_flag
        S_GT1_SCAN    = 5'd6,   // greater1 flags
        S_GT2         = 5'd7,   // greater2 flag
        S_SIGN_SCAN   = 5'd8,   // sign flags (EP)
        S_REM_SCAN    = 5'd9,   // remaining levels
        S_REM_EG      = 5'd10,  // Exp-Golomb / Rice bins
        S_TU_DONE     = 5'd11;

    reg [4:0]  state;

    // Registers latched at coeff_valid
    reg [1:0]  comp_r;
    reg        is_intra_r;
    reg [2:0]  tu_size_log2_r;
    reg        cbf_r;
    reg [9:0]  last_sig_pos_r;
    reg [4:0]  last_sig_x_r;
    reg [4:0]  last_sig_y_r;
    reg [3:0]  last_pfx_x;
    reg [3:0]  last_pfx_y;
    reg [3:0]  pfx_cnt;
    reg [3:0]  max_pfx_len;
    reg [2:0]  suf_cnt;
    reg [2:0]  suf_len;
    reg [4:0]  suf_val;

    // TU counter (for 64x64 CU containing four 32x32 TUs)
    reg [1:0]  tu_idx;
    reg        cu_root_cbf_latched;
    reg [1:0]  cu_depth_r;

    // Multi-Sub-Block CG Tracking
    reg [5:0]  last_cg_idx;
    reg [5:0]  cur_cg;
    reg [63:0] cg_flags;
    reg [3:0]  load_cnt;

    // 16-word buffer for the currently active 4x4 CG
    reg signed [COEFF_W-1:0] cg_coeffs [0:15];
    reg [15:0] cg_sig_map;
    reg [4:0]  cg_num_sig;

    // Active coefficients within CG (up to 16 non-zero coeffs)
    reg [3:0]  sig_pos_list [0:15];
    reg signed [COEFF_W-1:0] sig_val_list [0:15];
    reg [3:0]  sig_idx_cnt;

    // Scan pointers
    reg [4:0]  scan_ptr;
    reg [3:0]  gt1_ptr;
    reg [3:0]  sign_ptr;
    reg [3:0]  rem_ptr;
    reg [1:0]  c1_state;
    reg        first_gt1_found;
    reg [3:0]  first_gt1_idx;
    reg        escape_data_present;
    reg [1:0]  ctx_set;
    reg        prev_cg_had_gt1;
    reg [2:0]  rice_param;

    // Exp-Golomb / Rice remaining level encoding registers
    reg [31:0] rem_val;
    reg [5:0]  rem_len;
    reg [5:0]  rem_cnt;

    // Exact Context IDs matching HM
    function automatic [CTX_ID_W-1:0] get_last_x_ctx;
        input [1:0] comp;
        input [2:0] log2_size;
        input [3:0] p_idx;
        reg [3:0] offset;
        reg [1:0] shift;
        begin
            if (comp == 2'd0) begin
                offset = (log2_size == 3'd2) ? 4'd0 : (log2_size == 3'd3) ? 4'd3 : (log2_size == 3'd4) ? 4'd6 : 4'd10;
                shift  = (log2_size == 3'd2) ? 2'd0 : 2'd1;
                get_last_x_ctx = 8'd90 + {4'd0, offset} + {7'd0, (p_idx >> shift)};
            end else begin
                shift = log2_size[1:0] - 2'd2;
                get_last_x_ctx = 8'd105 + {4'd0, (p_idx >> shift)};
            end
        end
    endfunction

    function automatic [CTX_ID_W-1:0] get_last_y_ctx;
        input [1:0] comp;
        input [2:0] log2_size;
        input [3:0] p_idx;
        reg [3:0] offset;
        reg [1:0] shift;
        begin
            if (comp == 2'd0) begin
                offset = (log2_size == 3'd2) ? 4'd0 : (log2_size == 3'd3) ? 4'd3 : (log2_size == 3'd4) ? 4'd6 : 4'd10;
                shift  = (log2_size == 3'd2) ? 2'd0 : 2'd1;
                get_last_y_ctx = 8'd120 + {4'd0, offset} + {7'd0, (p_idx >> shift)};
            end else begin
                shift = log2_size[1:0] - 2'd2;
                get_last_y_ctx = 8'd135 + {4'd0, (p_idx >> shift)};
            end
        end
    endfunction

    function automatic [5:0] get_cg_raster;
        input [2:0] log2_size;
        input [2:0] x;
        input [2:0] y;
        begin
            case (log2_size)
                3'd3: get_cg_raster = {4'd0, y[0], x[0]};                     // 2x2
                3'd4: get_cg_raster = {2'd0, y[1:0], x[1:0]};                 // 4x4
                3'd5: get_cg_raster = {y[2:0], x[2:0]};                       // 8x8
                default: get_cg_raster = 6'd0;
            endcase
        end
    endfunction

    function automatic [CTX_ID_W-1:0] get_cg_ctx;
        input [1:0] comp;
        input [2:0] log2_size;
        input [5:0] cg;
        input [63:0] flags;
        reg [2:0] cg_x, cg_y, max_cg;
        reg r_flag, b_flag;
        reg ctx_inc;
        begin
            max_cg = (log2_size == 3'd3) ? 3'd1 : (log2_size == 3'd4) ? 3'd3 : 3'd7;
            if (log2_size == 3'd3 || log2_size == 3'd4) begin
                cg_x = diag_4_col(cg[3:0]);
                cg_y = diag_4_row(cg[3:0]);
            end else begin
                cg_x = diag_8_col(cg[5:0]);
                cg_y = diag_8_row(cg[5:0]);
            end
            r_flag = (cg_x < max_cg) ? flags[get_cg_raster(log2_size, cg_x + 3'd1, cg_y)] : 1'b0;
            b_flag = (cg_y < max_cg) ? flags[get_cg_raster(log2_size, cg_x, cg_y + 3'd1)] : 1'b0;
            ctx_inc = (r_flag | b_flag);
            get_cg_ctx = (comp == 2'd0) ? (8'd42 + {7'd0, ctx_inc}) : (8'd44 + {7'd0, ctx_inc});
        end
    endfunction

    function automatic [CTX_ID_W-1:0] get_sig_ctx;
        input [1:0]  comp;
        input [2:0]  log2_size;
        input [5:0]  cg;
        input [3:0]  sub_pos;
        input [63:0] flags;
        reg [1:0] r, c;
        reg [2:0] cg_x, cg_y, max_cg;
        reg [5:0] pos_x, pos_y;
        reg [1:0] cnt;
        reg [2:0] pos_total;
        reg [1:0] pattern;
        reg       r_flag, b_flag;
        reg       not_first;
        reg [3:0] lut4x4 [0:15];
        begin
            lut4x4[ 0]=4'd0; lut4x4[ 1]=4'd1; lut4x4[ 2]=4'd4; lut4x4[ 3]=4'd5;
            lut4x4[ 4]=4'd2; lut4x4[ 5]=4'd3; lut4x4[ 6]=4'd4; lut4x4[ 7]=4'd5;
            lut4x4[ 8]=4'd6; lut4x4[ 9]=4'd6; lut4x4[10]=4'd8; lut4x4[11]=4'd8;
            lut4x4[12]=4'd7; lut4x4[13]=4'd7; lut4x4[14]=4'd8; lut4x4[15]=4'd8;

            r = diag_4_row(sub_pos);
            c = diag_4_col(sub_pos);

            max_cg = (log2_size == 3'd3) ? 3'd1 : (log2_size == 3'd4) ? 3'd3 : 3'd7;
            if (log2_size == 3'd2) begin
                cg_x = 3'd0; cg_y = 3'd0;
            end else if (log2_size == 3'd3 || log2_size == 3'd4) begin
                cg_x = diag_4_col(cg[3:0]);
                cg_y = diag_4_row(cg[3:0]);
            end else begin
                cg_x = diag_8_col(cg[5:0]);
                cg_y = diag_8_row(cg[5:0]);
            end

            pos_x = {3'd0, cg_x, 2'd0} + {4'd0, c};
            pos_y = {3'd0, cg_y, 2'd0} + {4'd0, r};

            if (pos_x == 6'd0 && pos_y == 6'd0) begin
                get_sig_ctx = (comp == 2'd0) ? 8'd46 : 8'd74;
            end else if (log2_size == 3'd2) begin
                get_sig_ctx = (comp == 2'd0) ? (8'd46 + {4'd0, lut4x4[{r, c}]}) : (8'd74 + {4'd0, lut4x4[{r, c}]});
            end else begin
                r_flag = (cg_x < max_cg) ? flags[get_cg_raster(log2_size, cg_x + 3'd1, cg_y)] : 1'b0;
                b_flag = (cg_y < max_cg) ? flags[get_cg_raster(log2_size, cg_x, cg_y + 3'd1)] : 1'b0;
                pattern = {b_flag, r_flag};

                case (pattern)
                    2'd0: begin
                        pos_total = {1'b0, c} + {1'b0, r};
                        cnt = (pos_total >= 3'd3) ? 2'd0 : ((pos_total >= 3'd1) ? 2'd1 : 2'd2);
                    end
                    2'd1: cnt = (r >= 2'd2) ? 2'd0 : ((r >= 2'd1) ? 2'd1 : 2'd2);
                    2'd2: cnt = (c >= 2'd2) ? 2'd0 : ((c >= 2'd1) ? 2'd1 : 2'd2);
                    default: cnt = 2'd2;
                endcase

                not_first = (cg_x + cg_y > 0);

                if (comp == 2'd0) begin
                    if (log2_size == 3'd3)
                        get_sig_ctx = 8'd46 + 8'd9  + (not_first ? 8'd3 : 8'd0) + {6'd0, cnt};
                    else
                        get_sig_ctx = 8'd46 + 8'd21 + (not_first ? 8'd3 : 8'd0) + {6'd0, cnt};
                end else begin
                    if (log2_size == 3'd3)
                        get_sig_ctx = 8'd74 + 8'd9  + {6'd0, cnt};
                    else
                        get_sig_ctx = 8'd74 + 8'd12 + {6'd0, cnt};
                end
            end
        end
    endfunction

    // =========================================================================
    // Combinational Output Multiplexer
    // =========================================================================
    always @* begin
        bin_valid   = 1'b0;
        bin_value   = 1'b0;
        bin_ctx_id  = 8'd0;
        bin_is_ep   = 1'b0;
        coeff_rd_en = 1'b0;
        coeff_rd_addr = 12'd0;

        case (state)
            S_STUB_CBFCB0: begin
                bin_valid  = 1'b1;
                bin_value  = 1'b1;
                bin_ctx_id = 8'd33;
            end
            S_STUB_CBFCR0: begin
                bin_valid  = 1'b1;
                bin_value  = 1'b1;
                bin_ctx_id = 8'd33;
            end
            S_STUB_SPLIT: begin
                bin_valid  = 1'b1;
                bin_value  = 1'b0; // do not split TU
                bin_ctx_id = (tu_size_log2_r >= 3'd5) ? 8'd38 : (8'd38 + {5'd0, (3'd5 - tu_size_log2_r)});
            end
            S_STUB_CBFCB1: begin
                bin_valid  = 1'b1;
                bin_value  = 1'b1;
                bin_ctx_id = 8'd34;
            end
            S_STUB_CBFCR1: begin
                bin_valid  = 1'b1;
                bin_value  = 1'b1;
                bin_ctx_id = 8'd34;
            end
            S_STUB_CBFLUMA: begin
                bin_valid  = 1'b1;
                bin_value  = cbf_r;
                bin_ctx_id = (cu_depth_r == 2'd0) ? 8'd28 : 8'd29;
            end
            S_STUB_ROOT: begin
                bin_valid  = 1'b1;
                bin_value  = cbf_r;
                bin_ctx_id = 8'd41;
            end

            S_LAST_X_PRE: begin
                bin_valid  = 1'b1;
                bin_value  = (pfx_cnt < last_pfx_x);
                bin_ctx_id = get_last_x_ctx(comp_r, tu_size_log2_r, pfx_cnt);
            end
            S_LAST_X_SUF: begin
                bin_valid = 1'b1;
                bin_value = suf_val[suf_cnt];
                bin_is_ep = 1'b1;
            end
            S_LAST_Y_PRE: begin
                bin_valid  = 1'b1;
                bin_value  = (pfx_cnt < last_pfx_y);
                bin_ctx_id = get_last_y_ctx(comp_r, tu_size_log2_r, pfx_cnt);
            end
            S_LAST_Y_SUF: begin
                bin_valid = 1'b1;
                bin_value = suf_val[suf_cnt];
                bin_is_ep = 1'b1;
            end

            S_LOAD_CG_REQ, S_LOAD_CG_WAIT: begin
                coeff_rd_en   = 1'b1;
                coeff_rd_addr = {6'd0, cur_cg, 4'd0} + {8'd0, load_cnt};
            end

            S_CG_FLAG: begin
                bin_valid  = 1'b1;
                bin_value  = (cg_num_sig != 5'd0);
                bin_ctx_id = get_cg_ctx(comp_r, tu_size_log2_r, cur_cg, cg_flags);
            end

            S_SIG_SCAN: begin
                if (cur_cg == last_cg_idx && scan_ptr == {1'b0, last_sig_pos_r[3:0]}) begin
                    bin_valid = 1'b0; // inferred 1 at last_sig_pos
                end else if (cur_cg > 6'd0 && scan_ptr == 5'd0 && cg_sig_map[15:1] == 15'd0) begin
                    bin_valid = 1'b0; // inferred 1 at pos 0 when all higher positions in non-zero CG are 0
                end else begin
                    bin_valid  = 1'b1;
                    bin_value  = cg_sig_map[scan_ptr[3:0]];
                    bin_ctx_id = get_sig_ctx(comp_r, tu_size_log2_r, cur_cg, scan_ptr[3:0], cg_flags);
                end
            end

            S_GT1_SCAN: begin
                bin_valid  = 1'b1;
                bin_value  = (abs_coeff(sig_val_list[gt1_ptr]) > 16'd1);
                bin_ctx_id = (comp_r == 2'd0) ? (8'd150 + {4'd0, ctx_set, 2'd0} + {6'd0, c1_state}) :
                                                (8'd166 + {4'd0, ctx_set, 2'd0} + {6'd0, c1_state});
            end

            S_GT2: begin
                bin_valid  = 1'b1;
                bin_value  = (abs_coeff(sig_val_list[first_gt1_idx]) > 16'd2);
                bin_ctx_id = (comp_r == 2'd0) ? (8'd174 + {6'd0, ctx_set}) : (8'd178 + {6'd0, ctx_set});
            end

            S_SIGN_SCAN: begin
                bin_valid = 1'b1;
                bin_value = sig_val_list[sign_ptr][COEFF_W-1]; // 1=negative, 0=positive
                bin_is_ep = 1'b1;
            end

            S_REM_SCAN: begin
                bin_valid = 1'b0;
            end

            S_REM_EG: begin
                bin_valid = 1'b1;
                bin_value = rem_val[rem_cnt];
                bin_is_ep = 1'b1;
            end

            default: ;
        endcase
    end

    // =========================================================================
    // Combinational helper for Rice / Exp-Golomb encoding
    // =========================================================================
    function automatic [37:0] calc_rice_eg;
        input [15:0] symbol;
        input [2:0]  rParam;
        reg [15:0] codeNumber;
        reg [5:0]  length;
        reg [5:0]  prefix_len;
        reg [5:0]  suffix_len;
        reg [5:0]  total_len;
        reg [31:0] out_bits;
        reg [15:0] prefix_val;
        reg [15:0] suffix_val;
        integer i;
        begin
            codeNumber = symbol;
            if (codeNumber < (16'd3 << rParam)) begin
                length = codeNumber >> rParam;
                prefix_len = length + 6'd1;
                suffix_len = {3'd0, rParam};
                total_len = prefix_len + suffix_len;
                prefix_val = (16'd1 << prefix_len) - 16'd2;
                suffix_val = codeNumber & ((16'd1 << rParam) - 16'd1);
                out_bits = ({{16{1'b0}}, prefix_val} << suffix_len) | {{16{1'b0}}, suffix_val};
            end else begin
                length = {3'd0, rParam};
                codeNumber = codeNumber - (16'd3 << rParam);
                for (i = 0; i < 16; i = i + 1) begin
                    if (codeNumber >= (16'd1 << length) && length < 6'd16) begin
                        codeNumber = codeNumber - (16'd1 << length);
                        length = length + 6'd1;
                    end
                end
                prefix_len = 6'd3 + length + 6'd1 - {3'd0, rParam};
                suffix_len = length;
                total_len  = prefix_len + suffix_len;
                prefix_val = (16'd1 << prefix_len) - 16'd2;
                suffix_val = codeNumber;
                out_bits   = ({{16{1'b0}}, prefix_val} << suffix_len) | {{16{1'b0}}, suffix_val};
            end
            calc_rice_eg = {total_len, out_bits};
        end
    endfunction

    // =========================================================================
    // Main Sequential FSM
    // =========================================================================
    integer c_i;
    reg [COEFF_W-1:0] cur_abs_val;
    reg [COEFF_W-1:0] base_level_val;
    reg [37:0] eg_result;
    reg [15:0] v_sig_map;
    reg [4:0]  v_num_sig;
    reg [3:0]  v_pos_list [0:15];
    reg signed [COEFF_W-1:0] v_val_list [0:15];
    reg signed [COEFF_W-1:0] c_val;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= S_IDLE;
            coeff_done          <= 1'b0;
            tu_idx              <= 2'd0;
            cu_depth_r          <= 2'd0;
            comp_r              <= 2'd0;
            is_intra_r          <= 1'b0;
            tu_size_log2_r      <= 3'd2;
            cbf_r               <= 1'b0;
            last_sig_pos_r      <= 10'd0;
            last_sig_x_r        <= 5'd0;
            last_sig_y_r        <= 5'd0;
            last_pfx_x          <= 4'd0;
            last_pfx_y          <= 4'd0;
            pfx_cnt             <= 4'd0;
            max_pfx_len         <= 4'd0;
            suf_cnt             <= 3'd0;
            suf_len             <= 3'd0;
            suf_val             <= 5'd0;
            last_cg_idx         <= 6'd0;
            cur_cg              <= 6'd0;
            cg_flags            <= 64'd0;
            load_cnt            <= 4'd0;
            cg_sig_map          <= 16'd0;
            cg_num_sig          <= 5'd0;
            sig_idx_cnt         <= 4'd0;
            scan_ptr            <= 5'd0;
            gt1_ptr             <= 4'd0;
            sign_ptr            <= 4'd0;
            rem_ptr             <= 4'd0;
            c1_state            <= 2'd1;
            first_gt1_found     <= 1'b0;
            first_gt1_idx       <= 4'd0;
            escape_data_present <= 1'b0;
            ctx_set             <= 2'd0;
            prev_cg_had_gt1     <= 1'b0;
            rice_param          <= 3'd0;
            rem_val             <= 32'd0;
            rem_len             <= 6'd0;
            rem_cnt             <= 6'd0;
            for (c_i = 0; c_i < 16; c_i = c_i + 1) begin
                cg_coeffs[c_i]    <= {COEFF_W{1'b0}};
                sig_pos_list[c_i] <= 4'd0;
                sig_val_list[c_i] <= {COEFF_W{1'b0}};
            end
        end else begin
            coeff_done <= 1'b0;
            if (cu_valid) begin
                tu_idx              <= 2'd0;
                cu_root_cbf_latched <= 1'b0;
                cu_depth_r          <= cu_depth;
            end

            case (state)
                S_IDLE: begin
                    if (coeff_valid) begin
                        $display("Time=%0t: [syntax_coeff] S_IDLE -> coeff_valid! comp=%0d, tu_idx=%0d, size=%0d, cbf=%0d, last_sig=%0d",
                                 $time, comp_id, tu_idx, tu_size_log2, tu_cbf, last_sig_pos);
                        comp_r          <= comp_id;
                        is_intra_r      <= is_intra;
                        tu_size_log2_r  <= tu_size_log2;
                        cbf_r           <= tu_cbf;
                        last_sig_pos_r  <= last_sig_pos;
                        last_sig_x_r    <= get_x_from_scan(last_sig_pos, tu_size_log2);
                        last_sig_y_r    <= get_y_from_scan(last_sig_pos, tu_size_log2);
                        last_pfx_x      <= get_prefix(get_x_from_scan(last_sig_pos, tu_size_log2));
                        last_pfx_y      <= get_prefix(get_y_from_scan(last_sig_pos, tu_size_log2));
                        last_cg_idx     <= last_sig_pos >> 4;
                        cur_cg          <= last_sig_pos >> 4;
                        cg_flags        <= 64'd0;
                        max_pfx_len     <= {tu_size_log2, 1'b0};
                        pfx_cnt         <= 4'd0;
                        prev_cg_had_gt1 <= 1'b0;
                        ctx_set         <= 2'd0;

                        if (comp_id == 2'd0) begin
                            if (!is_intra && !is_merge && tu_idx == 2'd0) state <= S_STUB_ROOT;
                            else if (tu_idx == 2'd0) begin
                                cu_root_cbf_latched <= 1'b1;
                                if (cu_depth_r == 2'd0) state <= S_STUB_CBFCB0;
                                else state <= S_STUB_SPLIT;
                            end else state <= S_STUB_SPLIT;
                        end else begin
                            if (is_intra_r || cu_root_cbf_latched) begin
                                state <= S_LAST_X_PRE;
                            end else begin
                                if (comp_id == 2'd2) tu_idx <= tu_idx + 2'd1;
                                coeff_done <= 1'b1;
                                state <= S_IDLE;
                            end
                        end
                    end
                end

                // --- Slice/CU TU Header States ---
                S_STUB_CBFCB0: if (bin_rdy) state <= S_STUB_CBFCR0;
                S_STUB_CBFCR0: if (bin_rdy) begin
                    if (cu_depth_r == 2'd0) state <= S_STUB_SPLIT;
                    else state <= S_STUB_CBFLUMA;
                end
                S_STUB_SPLIT:  if (bin_rdy) begin
                    if (cu_depth_r == 2'd0) state <= S_STUB_CBFCB1;
                    else state <= S_STUB_CBFCB0;
                end
                S_STUB_CBFCB1: if (bin_rdy) state <= S_STUB_CBFCR1;
                S_STUB_CBFCR1: if (bin_rdy) state <= S_STUB_CBFLUMA;
                S_STUB_CBFLUMA: begin
                    if (bin_rdy) begin
                        if (cbf_r) begin
                            state <= S_LAST_X_PRE;
                        end else begin
                            coeff_done <= 1'b1;
                            state      <= S_IDLE;
                        end
                    end
                end
                S_STUB_ROOT: begin
                    if (bin_rdy) begin
                        if (cbf_r) begin
                            cu_root_cbf_latched <= 1'b1;
                            if (cu_depth_r == 2'd0) state <= S_STUB_CBFCB0;
                            else state <= S_STUB_SPLIT;
                        end else begin
                            cu_root_cbf_latched <= 1'b0;
                            tu_idx     <= tu_idx + 2'd1;
                            coeff_done <= 1'b1;
                            state      <= S_IDLE;
                        end
                    end
                end

                // --- Phase 0: Last Significant Position ---
                S_LAST_X_PRE: begin
                    if (bin_rdy) begin
                        if ((pfx_cnt + 4'd1 < last_pfx_x) || (pfx_cnt < last_pfx_x && last_pfx_x < (max_pfx_len - 1))) begin
                            pfx_cnt <= pfx_cnt + 4'd1;
                        end else begin
                            pfx_cnt <= 4'd0;
                            state   <= S_LAST_Y_PRE;
                        end
                    end
                end

                S_LAST_Y_PRE: begin
                    if (bin_rdy) begin
                        if ((pfx_cnt + 4'd1 < last_pfx_y) || (pfx_cnt < last_pfx_y && last_pfx_y < (max_pfx_len - 1))) begin
                            pfx_cnt <= pfx_cnt + 4'd1;
                        end else begin
                            pfx_cnt <= 4'd0;
                            if (last_pfx_x > 4'd3) begin
                                suf_len <= (last_pfx_x - 4'd2) >> 1;
                                suf_cnt <= ((last_pfx_x - 4'd2) >> 1) - 3'd1;
                                suf_val <= last_sig_x_r - get_min_in_group(last_pfx_x);
                                state   <= S_LAST_X_SUF;
                            end else if (last_pfx_y > 4'd3) begin
                                suf_len <= (last_pfx_y - 4'd2) >> 1;
                                suf_cnt <= ((last_pfx_y - 4'd2) >> 1) - 3'd1;
                                suf_val <= last_sig_y_r - get_min_in_group(last_pfx_y);
                                state   <= S_LAST_Y_SUF;
                            end else begin
                                load_cnt <= 4'd0;
                                state    <= S_LOAD_CG_REQ;
                            end
                        end
                    end
                end

                S_LAST_X_SUF: begin
                    if (bin_rdy) begin
                        if (suf_cnt > 0) suf_cnt <= suf_cnt - 3'd1;
                        else begin
                            if (last_pfx_y > 4'd3) begin
                                suf_len <= (last_pfx_y - 4'd2) >> 1;
                                suf_cnt <= ((last_pfx_y - 4'd2) >> 1) - 3'd1;
                                suf_val <= last_sig_y_r - get_min_in_group(last_pfx_y);
                                state   <= S_LAST_Y_SUF;
                            end else begin
                                load_cnt <= 4'd0;
                                state    <= S_LOAD_CG_REQ;
                            end
                        end
                    end
                end

                S_LAST_Y_SUF: begin
                    if (bin_rdy) begin
                        if (suf_cnt > 0) suf_cnt <= suf_cnt - 3'd1;
                        else begin
                            load_cnt <= 4'd0;
                            state    <= S_LOAD_CG_REQ;
                        end
                    end
                end

                // --- Phase 1: Load 16 Coefficients for current CG ---
                S_LOAD_CG_REQ: begin
                    state <= S_LOAD_CG_WAIT;
                end

                S_LOAD_CG_WAIT: begin
                    cg_coeffs[load_cnt] <= coeff_rd_data;
                    if (load_cnt == 4'd15) begin
                        state <= (cur_cg == last_cg_idx || cur_cg == 6'd0) ? S_SIG_SCAN : S_CG_FLAG;
                        cg_flags[get_cg_raster(tu_size_log2_r,
                            (tu_size_log2_r == 3'd5) ? diag_8_col(cur_cg) : diag_4_col(cur_cg[3:0]),
                            (tu_size_log2_r == 3'd5) ? diag_8_row(cur_cg) : diag_4_row(cur_cg[3:0]))] <= 1'b1;
                        scan_ptr <= (cur_cg == last_cg_idx) ? {1'b0, last_sig_pos_r[3:0]} : 5'd15;

                        // Procedural accumulation with blocking assignments
                        v_sig_map = 16'd0;
                        v_num_sig = 5'd0;
                        for (c_i = 0; c_i < 16; c_i = c_i + 1) begin
                            v_pos_list[c_i] = 4'd0;
                            v_val_list[c_i] = {COEFF_W{1'b0}};
                        end
                        for (c_i = 15; c_i >= 0; c_i = c_i - 1) begin
                            c_val = (c_i == 15) ? coeff_rd_data : cg_coeffs[c_i];
                            if (c_val != 16'd0) begin
                                if (cur_cg != last_cg_idx || c_i <= last_sig_pos_r[3:0]) begin
                                    v_sig_map[c_i] = 1'b1;
                                    v_pos_list[v_num_sig[3:0]] = c_i[3:0];
                                    v_val_list[v_num_sig[3:0]] = c_val;
                                    v_num_sig = v_num_sig + 5'd1;
                                end
                            end
                        end
                        if (v_num_sig == 5'd0 && cur_cg == last_cg_idx) begin
                            v_sig_map[0] = 1'b1;
                            v_pos_list[0] = 4'd0;
                            v_val_list[0] = 16'd1;
                            v_num_sig = 5'd1;
                        end
                        cg_sig_map <= v_sig_map;
                        cg_num_sig <= v_num_sig;
                        ctx_set    <= (comp_r == 2'd0) ? ((cur_cg > 6'd0 ? 2'd2 : 2'd0) + {1'b0, prev_cg_had_gt1}) :
                                                         {1'b0, prev_cg_had_gt1};
                        for (c_i = 0; c_i < 16; c_i = c_i + 1) begin
                            sig_pos_list[c_i] <= v_pos_list[c_i];
                            sig_val_list[c_i] <= v_val_list[c_i];
                        end
                    end else begin
                        load_cnt <= load_cnt + 4'd1;
                        state    <= S_LOAD_CG_REQ;
                    end
                end

                S_CG_FLAG: begin
                    if (bin_rdy) begin
                        if (cg_num_sig != 5'd0) begin
                            cg_flags[get_cg_raster(tu_size_log2_r,
                                (tu_size_log2_r == 3'd5) ? diag_8_col(cur_cg) : diag_4_col(cur_cg[3:0]),
                                (tu_size_log2_r == 3'd5) ? diag_8_row(cur_cg) : diag_4_row(cur_cg[3:0]))] <= 1'b1;
                            scan_ptr <= 5'd15;
                            state <= S_SIG_SCAN;
                        end else begin
                            cg_flags[get_cg_raster(tu_size_log2_r,
                                (tu_size_log2_r == 3'd5) ? diag_8_col(cur_cg) : diag_4_col(cur_cg[3:0]),
                                (tu_size_log2_r == 3'd5) ? diag_8_row(cur_cg) : diag_4_row(cur_cg[3:0]))] <= 1'b0;
                            if (cur_cg > 6'd0) begin
                                cur_cg   <= cur_cg - 6'd1;
                                load_cnt <= 4'd0;
                                state    <= S_LOAD_CG_REQ;
                            end else begin
                                state <= S_TU_DONE;
                            end
                        end
                    end
                end

                // --- Phase 2: Significance Map (sig_coeff_flag) ---
                S_SIG_SCAN: begin
                    if (bin_rdy || (cur_cg == last_cg_idx && scan_ptr == {1'b0, last_sig_pos_r[3:0]}) || (cur_cg > 6'd0 && scan_ptr == 5'd0 && cg_sig_map[15:1] == 15'd0)) begin
                        if (scan_ptr > 5'd0) begin
                            scan_ptr <= scan_ptr - 5'd1;
                        end else begin
                            gt1_ptr             <= 4'd0;
                            c1_state            <= (comp_r == 2'd0) ? 2'd1 : 2'd1;
                            first_gt1_found     <= 1'b0;
                            first_gt1_idx       <= 4'd0;
                            escape_data_present <= 1'b0;
                            if (cg_num_sig > 5'd0) begin
                                state <= S_GT1_SCAN;
                            end else begin
                                if (cur_cg > 6'd0) begin
                                    cur_cg   <= cur_cg - 6'd1;
                                    load_cnt <= 4'd0;
                                    state    <= S_LOAD_CG_REQ;
                                end else begin
                                    state <= S_TU_DONE;
                                end
                            end
                        end
                    end
                end

                // --- Phase 3: Greater 1 Flags ---
                S_GT1_SCAN: begin
                    if (bin_rdy) begin
                        if (abs_coeff(sig_val_list[gt1_ptr]) > 16'd1) begin
                            c1_state <= 2'd0;
                            if (!first_gt1_found) begin
                                first_gt1_found <= 1'b1;
                                first_gt1_idx   <= gt1_ptr;
                            end else begin
                                escape_data_present <= 1'b1;
                            end
                        end else if (c1_state > 0 && c1_state < 2'd3) begin
                            c1_state <= c1_state + 2'd1;
                        end

                        if ({1'b0, gt1_ptr} + 5'd1 < cg_num_sig && gt1_ptr < 4'd7) begin
                            gt1_ptr <= gt1_ptr + 4'd1;
                        end else begin
                            if (cg_num_sig > 5'd8) escape_data_present <= 1'b1;
                            if (first_gt1_found || abs_coeff(sig_val_list[gt1_ptr]) > 16'd1) begin
                                prev_cg_had_gt1 <= 1'b1;
                                state <= S_GT2;
                            end else begin
                                prev_cg_had_gt1 <= 1'b0;
                                sign_ptr <= 4'd0;
                                state    <= S_SIGN_SCAN;
                            end
                        end
                    end
                end

                // --- Phase 4: Greater 2 Flag ---
                S_GT2: begin
                    if (bin_rdy) begin
                        if (abs_coeff(sig_val_list[first_gt1_idx]) > 16'd2) begin
                            escape_data_present <= 1'b1;
                        end
                        sign_ptr <= 4'd0;
                        state    <= S_SIGN_SCAN;
                    end
                end

                // --- Phase 5: Signs (EP Bypass) ---
                S_SIGN_SCAN: begin
                    if (bin_rdy) begin
                        if ({1'b0, sign_ptr} + 5'd1 < cg_num_sig) begin
                            sign_ptr <= sign_ptr + 4'd1;
                        end else begin
                            rem_ptr    <= 4'd0;
                            rice_param <= 3'd0;
                            if (escape_data_present) begin
                                cur_abs_val    = abs_coeff(sig_val_list[0]);
                                base_level_val = (first_gt1_found && 0 == first_gt1_idx) ? 5'd3 : (0 < 4'd8) ? 5'd2 : 5'd1;
                                if (cur_abs_val >= base_level_val) begin
                                    eg_result = calc_rice_eg(cur_abs_val - base_level_val, 3'd0);
                                    rem_val   <= eg_result[31:0];
                                    rem_len   <= eg_result[37:32];
                                    rem_cnt   <= eg_result[37:32] - 6'd1;
                                    if (cur_abs_val > (16'd3 << 3'd0)) rice_param <= 3'd1;
                                    else rice_param <= 3'd0;
                                    state     <= S_REM_EG;
                                end else begin
                                    state <= S_REM_SCAN;
                                end
                            end else begin
                                if (cur_cg > 6'd0) begin
                                    cur_cg   <= cur_cg - 6'd1;
                                    load_cnt <= 4'd0;
                                    state    <= S_LOAD_CG_REQ;
                                end else begin
                                    state <= S_TU_DONE;
                                end
                            end
                        end
                    end
                end

                // --- Phase 6: Remaining Level (Rice / Exp-Golomb) ---
                S_REM_SCAN: begin
                    if ({1'b0, rem_ptr} + 5'd1 < cg_num_sig) begin
                        rem_ptr <= rem_ptr + 4'd1;
                        cur_abs_val = abs_coeff(sig_val_list[rem_ptr + 4'd1]);
                        base_level_val = (first_gt1_found && (rem_ptr + 4'd1) == first_gt1_idx) ? 5'd3 : ((rem_ptr + 4'd1) < 4'd8) ? 5'd2 : 5'd1;
                        if (cur_abs_val >= base_level_val) begin
                            eg_result = calc_rice_eg(cur_abs_val - base_level_val, rice_param);
                            rem_val   <= eg_result[31:0];
                            rem_len   <= eg_result[37:32];
                            rem_cnt   <= eg_result[37:32] - 6'd1;
                            if (cur_abs_val > (16'd3 << rice_param) && rice_param < 3'd4) rice_param <= rice_param + 3'd1;
                            state     <= S_REM_EG;
                        end
                    end else begin
                        if (cur_cg > 6'd0) begin
                            cur_cg   <= cur_cg - 6'd1;
                            load_cnt <= 4'd0;
                            state    <= S_LOAD_CG_REQ;
                        end else begin
                            state <= S_TU_DONE;
                        end
                    end
                end

                S_REM_EG: begin
                    if (bin_rdy) begin
                        if (rem_cnt > 0) begin
                            rem_cnt <= rem_cnt - 6'd1;
                        end else begin
                            if ({1'b0, rem_ptr} + 5'd1 < cg_num_sig) begin
                                rem_ptr <= rem_ptr + 4'd1;
                                cur_abs_val = abs_coeff(sig_val_list[rem_ptr + 4'd1]);
                                base_level_val = (first_gt1_found && (rem_ptr + 4'd1) == first_gt1_idx) ? 5'd3 : ((rem_ptr + 4'd1) < 4'd8) ? 5'd2 : 5'd1;
                                if (cur_abs_val >= base_level_val) begin
                                    eg_result = calc_rice_eg(cur_abs_val - base_level_val, rice_param);
                                    rem_val   <= eg_result[31:0];
                                    rem_len   <= eg_result[37:32];
                                    rem_cnt   <= eg_result[37:32] - 6'd1;
                                    if (cur_abs_val > (16'd3 << rice_param) && rice_param < 3'd4) rice_param <= rice_param + 3'd1;
                                    state     <= S_REM_EG;
                                end else begin
                                    state <= S_REM_SCAN;
                                end
                            end else begin
                                if (cur_cg > 6'd0) begin
                                    cur_cg   <= cur_cg - 6'd1;
                                    load_cnt <= 4'd0;
                                    state    <= S_LOAD_CG_REQ;
                                end else begin
                                    state <= S_TU_DONE;
                                end
                            end
                        end
                    end
                end

                S_TU_DONE: begin
                    $display("Time=%0t: [syntax_coeff] TU done! comp=%0d, tu_idx=%0d", $time, comp_r, tu_idx);
                    if (comp_r == 2'd2) begin
                        tu_idx <= tu_idx + 2'd1;
                    end
                    coeff_done <= 1'b1;
                    state      <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule