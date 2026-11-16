//=============================================================================
// mc_window_fetch.v
// Synthesizable True Dual-Port Phase-Aware Sliding-Column Window DPB Fetch Engine
//
// Normative References:
//   - ITU-T H.265 Clause 8.5.3.3.3 (Fractional sample interpolation)
//   - ITU-T H.265 Clause 8.5.3.3.3.1 (Derivation of reference sample matrices)
//   - HM 18.0 TComInterpolationFilter & TComPrediction
//
// Optimizations (Pillar 1):
//   - True Dual-Port (TDP) DPB reads: fetches 2 reference samples per cycle
//     (Port A + Port B) into both L0 and L1 windows.
//   - Phase-Aware Fetch (1A): skips unused taps for 0D integer (1 sample/pel),
//     1D horizontal (row 3/1 only, 1 sample/pel for x>0), and 1D vertical (col 3/1 only).
//   - Zero-Bubble Pipeline (1B): eliminates S_EMIT and inter-pixel drain bubbles via
//     write-through bypass of returning BRAM read data at emit time.
//   - Vertical Row-Start Reuse (1C): caches row-start window row0_win at x=0 and
//     shifts up by 1 row for (0, y+1), fetching only bottom row (4 TDP reads).
//   - Boundary padding via Clip3 clamping conforms to Clause 8.5.3.3.3.1.
//=============================================================================

`timescale 1ns / 1ps

module mc_window_fetch #(
    parameter PW = 10
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // Control interface
    input  wire                   start,               // 1-cycle pulse at inter TU accept
    input  wire [1:0]             comp,                // 0: Y, 1: Cb, 2: Cr
    input  wire [2:0]             tu_size_log2,        // 2: 4x4, 3: 8x8, 4: 16x16, 5: 32x32
    input  wire signed [12:0]     base_x,              // TU origin + integer MV in pixel units
    input  wire signed [12:0]     base_y,
    input  wire [2:0]             frac_x,              // Fractional phase X (0..3 luma, 0..7 chroma)
    input  wire [2:0]             frac_y,              // Fractional phase Y (0..3 luma, 0..7 chroma)
    input  wire                   rd_hold,             // Hold Stage-1 DPB read during Port-A write collision

    // Synchronous True Dual-Port DPB RAM read interface (Port A + Port B)
    output reg  [13:0]            rd_addr_a,           // {y, x} without slot bit, Clip3-clamped
    output reg  [13:0]            rd_addr_b,
    input  wire [PW-1:0]          rd_data_l0_a,        // 1-cycle sync BRAM return L0 Port A
    input  wire [PW-1:0]          rd_data_l0_b,        // 1-cycle sync BRAM return L0 Port B
    input  wire [PW-1:0]          rd_data_l1_a,        // 1-cycle sync BRAM return L1 Port A
    input  wire [PW-1:0]          rd_data_l1_b,        // 1-cycle sync BRAM return L1 Port B

    // Output window stream to subpel_interpolation_core
    output reg                    win_valid,           // 1 pulse per output sample (raster order)
    output reg  [PW*64-1:0]       win_l0_flat,         // 8x8 luma, low 16 entries for 4x4 chroma
    output reg  [PW*64-1:0]       win_l1_flat,
    output reg  [5:0]             win_x,               // Current sample coordinate within TU (0..N-1)
    output reg  [5:0]             win_y,
    output reg                    win_last,            // Asserted on last sample of TU
    output wire                   busy                 // High while processing TU
);

    //-------------------------------------------------------------------------
    // Clamping helpers (Clause 8.5.3.3.3.1)
    //-------------------------------------------------------------------------
    function automatic [6:0] clamp_128;
        input signed [12:0] val;
        begin
            if (val < 13'sd0) clamp_128 = 7'd0;
            else if (val > 13'sd127) clamp_128 = 7'd127;
            else clamp_128 = val[6:0];
        end
    endfunction

    function automatic [5:0] clamp_64;
        input signed [12:0] val;
        begin
            if (val < 13'sd0) clamp_64 = 6'd0;
            else if (val > 13'sd63) clamp_64 = 6'd63;
            else clamp_64 = val[5:0];
        end
    endfunction

    //-------------------------------------------------------------------------
    // FSM & Fetch Mode Encodings
    //-------------------------------------------------------------------------
    localparam [1:0]
        S_IDLE      = 2'd0,
        S_ACTIVE    = 2'd1,
        S_WAIT_LAST = 2'd2;

    localparam [1:0]
        M_0D  = 2'd0,
        M_1DH = 2'd1,
        M_1DV = 2'd2,
        M_2D  = 2'd3;

    localparam [1:0]
        PMODE_WRITE     = 2'd0,
        PMODE_1DH_SHIFT = 2'd1;

    reg [1:0] state;

    // Latched TU parameters
    reg [1:0]         reg_comp;
    reg [2:0]         reg_tu_size_log2;
    reg signed [12:0] reg_base_x;
    reg signed [12:0] reg_base_y;
    reg [1:0]         reg_mode;

    // Issue engine coordinates & beat step
    reg [5:0] issue_x;
    reg [5:0] issue_y;
    reg [4:0] issue_step;

    // Window storage (2D arrays + Row-start reuse buffer for 1C)
    reg [PW-1:0] win_mem_l0  [0:7][0:7];
    reg [PW-1:0] win_mem_l1  [0:7][0:7];
    reg [PW-1:0] row0_win_l0 [0:7][0:7];
    reg [PW-1:0] row0_win_l1 [0:7][0:7];

    // 2-stage pipeline tracking (addr @ T -> BRAM @ T+1 -> return/emit @ T+2)
    reg       pipe1_en, pipe2_en;
    reg       pipe1_b_en, pipe2_b_en;
    reg [1:0] pipe1_mode, pipe2_mode;
    reg [2:0] pipe1_wya, pipe2_wya;
    reg [2:0] pipe1_wxa, pipe2_wxa;
    reg [2:0] pipe1_wyb, pipe2_wyb;
    reg [2:0] pipe1_wxb, pipe2_wxb;
    reg       pipe1_emit, pipe2_emit;
    reg       pipe1_last, pipe2_last;
    reg       pipe1_save_row0, pipe2_save_row0;
    reg       pipe1_shift_h, pipe2_shift_h;
    reg       pipe1_shift_v, pipe2_shift_v;
    reg [5:0] pipe1_px, pipe2_px;
    reg [5:0] pipe1_py, pipe2_py;

    assign busy = (state != S_IDLE);

    // Safe 4-state fractional phase & hold checks: unconnected inputs default to 2D / un-stalled
`ifdef SYNTHESIS
    wire in_fx_zero  = (comp == 2'd0) ? (frac_x[1:0] == 2'd0) : (frac_x == 3'd0);
    wire in_fy_zero  = (comp == 2'd0) ? (frac_y[1:0] == 2'd0) : (frac_y == 3'd0);
    wire rd_hold_eff = rd_hold;
`else
    wire in_fx_zero  = (comp == 2'd0) ? (frac_x[1:0] === 2'd0) : (frac_x === 3'd0);
    wire in_fy_zero  = (comp == 2'd0) ? (frac_y[1:0] === 2'd0) : (frac_y === 3'd0);
    wire rd_hold_eff = (rd_hold === 1'b1);
`endif
    wire [1:0] in_mode = (in_fx_zero && in_fy_zero) ? M_0D  :
                         (!in_fx_zero && in_fy_zero) ? M_1DH :
                         (in_fx_zero && !in_fy_zero) ? M_1DV : M_2D;

    //-------------------------------------------------------------------------
    // Combinational Issue Control (drives beat 0 in S_IDLE on start, then S_ACTIVE)
    //-------------------------------------------------------------------------
    wire [1:0]         iss_comp    = (state == S_IDLE) ? comp : reg_comp;
    wire [2:0]         iss_log2    = (state == S_IDLE) ? tu_size_log2 : reg_tu_size_log2;
    wire signed [12:0] iss_base_x  = (state == S_IDLE) ? base_x : reg_base_x;
    wire signed [12:0] iss_base_y  = (state == S_IDLE) ? base_y : reg_base_y;
    wire [1:0]         iss_mode    = (state == S_IDLE) ? in_mode : reg_mode;
    wire [5:0]         iss_cur_x   = (state == S_IDLE) ? 6'd0 : issue_x;
    wire [5:0]         iss_cur_y   = (state == S_IDLE) ? 6'd0 : issue_y;
    wire [4:0]         iss_cur_stp = (state == S_IDLE) ? 5'd0 : issue_step;

    wire       iss_is_luma = (iss_comp == 2'd0);
    wire [5:0] iss_tu_n    = 6'd1 << iss_log2;
    wire       iss_last_x  = (iss_cur_x == (iss_tu_n - 6'd1));
    wire       iss_last_y  = (iss_cur_y == (iss_tu_n - 6'd1));

    reg [4:0]         step_max;
    reg               comb_b_en;
    reg [1:0]         comb_pmode;
    reg [2:0]         comb_wya, comb_wxa, comb_wyb, comb_wxb;
    reg signed [12:0] comb_txa, comb_tya, comb_txb, comb_tyb;
    reg               comb_emit, comb_last, comb_save_row0, comb_shift_h, comb_shift_v;

    always @(*) begin
        step_max       = 5'd0;
        comb_b_en      = 1'b0;
        comb_pmode     = PMODE_WRITE;
        comb_wya       = 3'd0;
        comb_wxa       = 3'd0;
        comb_wyb       = 3'd0;
        comb_wxb       = 3'd0;
        comb_txa       = iss_base_x + $signed({7'd0, iss_cur_x});
        comb_tya       = iss_base_y + $signed({7'd0, iss_cur_y});
        comb_txb       = iss_base_x + $signed({7'd0, iss_cur_x});
        comb_tyb       = iss_base_y + $signed({7'd0, iss_cur_y});
        comb_emit      = 1'b0;
        comb_last      = 1'b0;
        comb_save_row0 = 1'b0;
        comb_shift_h   = 1'b0;
        comb_shift_v   = 1'b0;

        case (iss_mode)
            M_0D: begin
                // 0D Integer-pel: 1 sample/cycle at center tap (3,3) luma / (1,1) chroma
                step_max  = 5'd0;
                comb_b_en = 1'b0;
                comb_wya  = iss_is_luma ? 3'd3 : 3'd1;
                comb_wxa  = iss_is_luma ? 3'd3 : 3'd1;
                comb_txa  = iss_base_x + $signed({7'd0, iss_cur_x});
                comb_tya  = iss_base_y + $signed({7'd0, iss_cur_y});
                comb_emit = 1'b1;
                comb_last = iss_last_x && iss_last_y;
            end

            M_1DH: begin
                // 1D Horizontal: row 3 (luma) or row 1 (chroma) only
                if (iss_cur_x == 6'd0) begin
                    step_max  = iss_is_luma ? 5'd3 : 5'd1;
                    comb_b_en = 1'b1;
                    comb_wya  = iss_is_luma ? 3'd3 : 3'd1;
                    comb_wyb  = iss_is_luma ? 3'd3 : 3'd1;
                    comb_wxa  = {iss_cur_stp[1:0], 1'b0};
                    comb_wxb  = {iss_cur_stp[1:0], 1'b1};
                    if (iss_is_luma) begin
                        comb_txa = iss_base_x + $signed({10'd0, comb_wxa}) - 13'sd3;
                        comb_txb = iss_base_x + $signed({10'd0, comb_wxb}) - 13'sd3;
                    end else begin
                        comb_txa = iss_base_x + $signed({10'd0, comb_wxa}) - 13'sd1;
                        comb_txb = iss_base_x + $signed({10'd0, comb_wxb}) - 13'sd1;
                    end
                    comb_tya  = iss_base_y + $signed({7'd0, iss_cur_y});
                    comb_tyb  = iss_base_y + $signed({7'd0, iss_cur_y});
                    comb_emit = (iss_cur_stp == step_max);
                end else begin
                    // Subsequent columns stream 1 sample/cycle via PMODE_1DH_SHIFT
                    step_max   = 5'd0;
                    comb_b_en  = 1'b0;
                    comb_pmode = PMODE_1DH_SHIFT;
                    comb_wya   = iss_is_luma ? 3'd3 : 3'd1;
                    comb_wxa   = iss_is_luma ? 3'd7 : 3'd3;
                    comb_txa   = iss_base_x + $signed({7'd0, iss_cur_x}) + (iss_is_luma ? 13'sd4 : 13'sd2);
                    comb_tya   = iss_base_y + $signed({7'd0, iss_cur_y});
                    comb_emit  = 1'b1;
                    comb_last  = iss_last_x && iss_last_y;
                end
            end

            M_1DV: begin
                // 1D Vertical: col 3 (luma) or col 1 (chroma), 2 vertical taps/cycle
                step_max  = iss_is_luma ? 5'd3 : 5'd1;
                comb_b_en = 1'b1;
                comb_wxa  = iss_is_luma ? 3'd3 : 3'd1;
                comb_wxb  = iss_is_luma ? 3'd3 : 3'd1;
                comb_wya  = {iss_cur_stp[1:0], 1'b0};
                comb_wyb  = {iss_cur_stp[1:0], 1'b1};
                comb_txa  = iss_base_x + $signed({7'd0, iss_cur_x});
                comb_txb  = iss_base_x + $signed({7'd0, iss_cur_x});
                if (iss_is_luma) begin
                    comb_tya = iss_base_y + $signed({7'd0, iss_cur_y}) + $signed({10'd0, comb_wya}) - 13'sd3;
                    comb_tyb = iss_base_y + $signed({7'd0, iss_cur_y}) + $signed({10'd0, comb_wyb}) - 13'sd3;
                end else begin
                    comb_tya = iss_base_y + $signed({7'd0, iss_cur_y}) + $signed({10'd0, comb_wya}) - 13'sd1;
                    comb_tyb = iss_base_y + $signed({7'd0, iss_cur_y}) + $signed({10'd0, comb_wyb}) - 13'sd1;
                end
                comb_emit = (iss_cur_stp == step_max);
                comb_last = comb_emit && iss_last_x && iss_last_y;
            end

            default: begin // M_2D
                comb_b_en = 1'b1;
                if (iss_cur_x == 6'd0 && iss_cur_y == 6'd0) begin
                    // First pixel of TU: full 8x8 (32 TDP beats) or 4x4 (8 TDP beats)
                    step_max = iss_is_luma ? 5'd31 : 5'd7;
                    if (iss_is_luma) begin
                        comb_wya = iss_cur_stp[4:2];
                        comb_wyb = iss_cur_stp[4:2];
                        comb_wxa = {iss_cur_stp[1:0], 1'b0};
                        comb_wxb = {iss_cur_stp[1:0], 1'b1};
                        comb_txa = iss_base_x + $signed({10'd0, comb_wxa}) - 13'sd3;
                        comb_txb = iss_base_x + $signed({10'd0, comb_wxb}) - 13'sd3;
                        comb_tya = iss_base_y + $signed({10'd0, comb_wya}) - 13'sd3;
                        comb_tyb = iss_base_y + $signed({10'd0, comb_wyb}) - 13'sd3;
                    end else begin
                        comb_wya = {1'b0, iss_cur_stp[2:1]};
                        comb_wyb = {1'b0, iss_cur_stp[2:1]};
                        comb_wxa = {1'b0, iss_cur_stp[0], 1'b0};
                        comb_wxb = {1'b0, iss_cur_stp[0], 1'b1};
                        comb_txa = iss_base_x + $signed({10'd0, comb_wxa}) - 13'sd1;
                        comb_txb = iss_base_x + $signed({10'd0, comb_wxb}) - 13'sd1;
                        comb_tya = iss_base_y + $signed({10'd0, comb_wya}) - 13'sd1;
                        comb_tyb = iss_base_y + $signed({10'd0, comb_wyb}) - 13'sd1;
                    end
                    comb_emit      = (iss_cur_stp == step_max);
                    comb_save_row0 = comb_emit;
                    comb_shift_h   = comb_emit;
                end else if (iss_cur_x == 6'd0) begin
                    // Vertical row-start reuse (1C): fetch ONLY bottom row (4 luma / 2 chroma TDP beats)
                    step_max = iss_is_luma ? 5'd3 : 5'd1;
                    comb_wya = iss_is_luma ? 3'd7 : 3'd3;
                    comb_wyb = iss_is_luma ? 3'd7 : 3'd3;
                    comb_wxa = {iss_cur_stp[1:0], 1'b0};
                    comb_wxb = {iss_cur_stp[1:0], 1'b1};
                    if (iss_is_luma) begin
                        comb_txa = iss_base_x + $signed({10'd0, comb_wxa}) - 13'sd3;
                        comb_txb = iss_base_x + $signed({10'd0, comb_wxb}) - 13'sd3;
                        comb_tya = iss_base_y + $signed({7'd0, iss_cur_y}) + 13'sd4;
                        comb_tyb = iss_base_y + $signed({7'd0, iss_cur_y}) + 13'sd4;
                    end else begin
                        comb_txa = iss_base_x + $signed({10'd0, comb_wxa}) - 13'sd1;
                        comb_txb = iss_base_x + $signed({10'd0, comb_wxb}) - 13'sd1;
                        comb_tya = iss_base_y + $signed({7'd0, iss_cur_y}) + 13'sd2;
                        comb_tyb = iss_base_y + $signed({7'd0, iss_cur_y}) + 13'sd2;
                    end
                    comb_emit      = (iss_cur_stp == step_max);
                    comb_save_row0 = comb_emit;
                    comb_shift_h   = comb_emit;
                end else begin
                    // Subsequent columns in row: fetch rightmost column (4 luma / 2 chroma TDP beats)
                    step_max = iss_is_luma ? 5'd3 : 5'd1;
                    comb_wxa = iss_is_luma ? 3'd7 : 3'd3;
                    comb_wxb = iss_is_luma ? 3'd7 : 3'd3;
                    comb_wya = {iss_cur_stp[1:0], 1'b0};
                    comb_wyb = {iss_cur_stp[1:0], 1'b1};
                    if (iss_is_luma) begin
                        comb_txa = iss_base_x + $signed({7'd0, iss_cur_x}) + 13'sd4;
                        comb_txb = iss_base_x + $signed({7'd0, iss_cur_x}) + 13'sd4;
                        comb_tya = iss_base_y + $signed({7'd0, iss_cur_y}) + $signed({10'd0, comb_wya}) - 13'sd3;
                        comb_tyb = iss_base_y + $signed({7'd0, iss_cur_y}) + $signed({10'd0, comb_wyb}) - 13'sd3;
                    end else begin
                        comb_txa = iss_base_x + $signed({7'd0, iss_cur_x}) + 13'sd2;
                        comb_txb = iss_base_x + $signed({7'd0, iss_cur_x}) + 13'sd2;
                        comb_tya = iss_base_y + $signed({7'd0, iss_cur_y}) + $signed({10'd0, comb_wya}) - 13'sd1;
                        comb_tyb = iss_base_y + $signed({7'd0, iss_cur_y}) + $signed({10'd0, comb_wyb}) - 13'sd1;
                    end
                    comb_emit    = (iss_cur_stp == step_max);
                    comb_shift_h = comb_emit && !iss_last_x;
                    comb_shift_v = comb_emit && iss_last_x && !iss_last_y;
                    comb_last    = comb_emit && iss_last_x && iss_last_y;
                end
            end
        endcase
    end

    wire [13:0] comb_rd_addr_a = iss_is_luma ? {clamp_128(comb_tya), clamp_128(comb_txa)}
                                             : {2'b00, clamp_64(comb_tya), clamp_64(comb_txa)};
    wire [13:0] comb_rd_addr_b = iss_is_luma ? {clamp_128(comb_tyb), clamp_128(comb_txb)}
                                             : {2'b00, clamp_64(comb_tyb), clamp_64(comb_txb)};

    //-------------------------------------------------------------------------
    // Write-Through Window Bypass & Flatten (eliminates drain->emit bubble)
    //-------------------------------------------------------------------------
    reg [PW-1:0]    next_win_l0 [0:7][0:7];
    reg [PW-1:0]    next_win_l1 [0:7][0:7];
    reg [PW*64-1:0] flat_l0_comb;
    reg [PW*64-1:0] flat_l1_comb;
    integer wy_i, wx_i;

    always @(*) begin
        for (wy_i = 0; wy_i < 8; wy_i = wy_i + 1) begin
            for (wx_i = 0; wx_i < 8; wx_i = wx_i + 1) begin
                next_win_l0[wy_i][wx_i] = win_mem_l0[wy_i][wx_i];
                next_win_l1[wy_i][wx_i] = win_mem_l1[wy_i][wx_i];
            end
        end

        if (pipe2_en) begin
            if (pipe2_mode == PMODE_1DH_SHIFT) begin
                if (reg_comp == 2'd0) begin
                    for (wx_i = 0; wx_i < 7; wx_i = wx_i + 1) begin
                        next_win_l0[3][wx_i] = win_mem_l0[3][wx_i + 1];
                        next_win_l1[3][wx_i] = win_mem_l1[3][wx_i + 1];
                    end
                    next_win_l0[3][7] = rd_data_l0_a;
                    next_win_l1[3][7] = rd_data_l1_a;
                end else begin
                    for (wx_i = 0; wx_i < 3; wx_i = wx_i + 1) begin
                        next_win_l0[1][wx_i] = win_mem_l0[1][wx_i + 1];
                        next_win_l1[1][wx_i] = win_mem_l1[1][wx_i + 1];
                    end
                    next_win_l0[1][3] = rd_data_l0_a;
                    next_win_l1[1][3] = rd_data_l1_a;
                end
            end else begin
                next_win_l0[pipe2_wya][pipe2_wxa] = rd_data_l0_a;
                next_win_l1[pipe2_wya][pipe2_wxa] = rd_data_l1_a;
                if (pipe2_b_en) begin
                    next_win_l0[pipe2_wyb][pipe2_wxb] = rd_data_l0_b;
                    next_win_l1[pipe2_wyb][pipe2_wxb] = rd_data_l1_b;
                end
            end
        end

        flat_l0_comb = {(PW*64){1'b0}};
        flat_l1_comb = {(PW*64){1'b0}};
        if (reg_comp == 2'd0) begin
            for (wy_i = 0; wy_i < 8; wy_i = wy_i + 1) begin
                for (wx_i = 0; wx_i < 8; wx_i = wx_i + 1) begin
                    flat_l0_comb[PW*(wy_i*8 + wx_i) +: PW] = next_win_l0[wy_i][wx_i];
                    flat_l1_comb[PW*(wy_i*8 + wx_i) +: PW] = next_win_l1[wy_i][wx_i];
                end
            end
        end else begin
            for (wy_i = 0; wy_i < 4; wy_i = wy_i + 1) begin
                for (wx_i = 0; wx_i < 4; wx_i = wx_i + 1) begin
                    flat_l0_comb[PW*(wy_i*4 + wx_i) +: PW] = next_win_l0[wy_i][wx_i];
                    flat_l1_comb[PW*(wy_i*4 + wx_i) +: PW] = next_win_l1[wy_i][wx_i];
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // Main Sequential Pipeline
    //-------------------------------------------------------------------------
    integer sh_r, sh_c;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            reg_comp         <= 2'd0;
            reg_tu_size_log2 <= 3'd2;
            reg_base_x       <= 13'sd0;
            reg_base_y       <= 13'sd0;
            reg_mode         <= M_2D;
            issue_x          <= 6'd0;
            issue_y          <= 6'd0;
            issue_step       <= 5'd0;
            rd_addr_a        <= 14'd0;
            rd_addr_b        <= 14'd0;
            pipe1_en         <= 1'b0;
            pipe1_b_en       <= 1'b0;
            pipe1_mode       <= PMODE_WRITE;
            pipe1_wya        <= 3'd0;
            pipe1_wxa        <= 3'd0;
            pipe1_wyb        <= 3'd0;
            pipe1_wxb        <= 3'd0;
            pipe1_emit       <= 1'b0;
            pipe1_last       <= 1'b0;
            pipe1_save_row0  <= 1'b0;
            pipe1_shift_h    <= 1'b0;
            pipe1_shift_v    <= 1'b0;
            pipe1_px         <= 6'd0;
            pipe1_py         <= 6'd0;
            pipe2_en         <= 1'b0;
            pipe2_b_en       <= 1'b0;
            pipe2_mode       <= PMODE_WRITE;
            pipe2_wya        <= 3'd0;
            pipe2_wxa        <= 3'd0;
            pipe2_wyb        <= 3'd0;
            pipe2_wxb        <= 3'd0;
            pipe2_emit       <= 1'b0;
            pipe2_last       <= 1'b0;
            pipe2_save_row0  <= 1'b0;
            pipe2_shift_h    <= 1'b0;
            pipe2_shift_v    <= 1'b0;
            pipe2_px         <= 6'd0;
            pipe2_py         <= 6'd0;
            win_valid        <= 1'b0;
            win_x            <= 6'd0;
            win_y            <= 6'd0;
            win_last         <= 1'b0;
            win_l0_flat      <= {(PW*64){1'b0}};
            win_l1_flat      <= {(PW*64){1'b0}};
            for (sh_r = 0; sh_r < 8; sh_r = sh_r + 1) begin
                for (sh_c = 0; sh_c < 8; sh_c = sh_c + 1) begin
                    win_mem_l0[sh_r][sh_c]  <= {PW{1'b0}};
                    win_mem_l1[sh_r][sh_c]  <= {PW{1'b0}};
                    row0_win_l0[sh_r][sh_c] <= {PW{1'b0}};
                    row0_win_l1[sh_r][sh_c] <= {PW{1'b0}};
                end
            end
        end else begin
            // Default 1-cycle output strobes
            win_valid <= 1'b0;
            win_last  <= 1'b0;

            // Advance Stage 1 -> Stage 2 tracking (stall on Port-A write collision)
            if (pipe1_en && rd_hold_eff) begin
                pipe2_en <= 1'b0;
            end else begin
                pipe2_en        <= pipe1_en;
                pipe2_b_en      <= pipe1_b_en;
                pipe2_mode      <= pipe1_mode;
                pipe2_wya       <= pipe1_wya;
                pipe2_wxa       <= pipe1_wxa;
                pipe2_wyb       <= pipe1_wyb;
                pipe2_wxb       <= pipe1_wxb;
                pipe2_emit      <= pipe1_emit;
                pipe2_last      <= pipe1_last;
                pipe2_save_row0 <= pipe1_save_row0;
                pipe2_shift_h   <= pipe1_shift_h;
                pipe2_shift_v   <= pipe1_shift_v;
                pipe2_px        <= pipe1_px;
                pipe2_py        <= pipe1_py;
            end

            // Stage 2: Write returning data into win_mem / row0_win & emit window
            if (pipe2_en) begin
                if (pipe2_emit) begin
                    win_valid   <= 1'b1;
                    win_x       <= pipe2_px;
                    win_y       <= pipe2_py;
                    win_last    <= pipe2_last;
                    win_l0_flat <= flat_l0_comb;
                    win_l1_flat <= flat_l1_comb;
                end

                if (pipe2_emit && pipe2_save_row0) begin
                    for (sh_r = 0; sh_r < 8; sh_r = sh_r + 1) begin
                        for (sh_c = 0; sh_c < 8; sh_c = sh_c + 1) begin
                            row0_win_l0[sh_r][sh_c] <= next_win_l0[sh_r][sh_c];
                            row0_win_l1[sh_r][sh_c] <= next_win_l1[sh_r][sh_c];
                        end
                    end
                end

                if (pipe2_emit && pipe2_shift_v) begin
                    // Load win_mem[0..6] from row0_win[1..7] for row (0, y+1)
                    for (sh_r = 0; sh_r < 7; sh_r = sh_r + 1) begin
                        for (sh_c = 0; sh_c < 8; sh_c = sh_c + 1) begin
                            win_mem_l0[sh_r][sh_c] <= row0_win_l0[sh_r + 1][sh_c];
                            win_mem_l1[sh_r][sh_c] <= row0_win_l1[sh_r + 1][sh_c];
                        end
                    end
                end else if (pipe2_emit && pipe2_shift_h) begin
                    // Slide next_win left by 1 column for (x+1, y)
                    if (reg_comp == 2'd0) begin
                        for (sh_r = 0; sh_r < 8; sh_r = sh_r + 1) begin
                            for (sh_c = 0; sh_c < 7; sh_c = sh_c + 1) begin
                                win_mem_l0[sh_r][sh_c] <= next_win_l0[sh_r][sh_c + 1];
                                win_mem_l1[sh_r][sh_c] <= next_win_l1[sh_r][sh_c + 1];
                            end
                        end
                    end else begin
                        for (sh_r = 0; sh_r < 4; sh_r = sh_r + 1) begin
                            for (sh_c = 0; sh_c < 3; sh_c = sh_c + 1) begin
                                win_mem_l0[sh_r][sh_c] <= next_win_l0[sh_r][sh_c + 1];
                                win_mem_l1[sh_r][sh_c] <= next_win_l1[sh_r][sh_c + 1];
                            end
                        end
                    end
                end else begin
                    for (sh_r = 0; sh_r < 8; sh_r = sh_r + 1) begin
                        for (sh_c = 0; sh_c < 8; sh_c = sh_c + 1) begin
                            win_mem_l0[sh_r][sh_c] <= next_win_l0[sh_r][sh_c];
                            win_mem_l1[sh_r][sh_c] <= next_win_l1[sh_r][sh_c];
                        end
                    end
                end
            end

            // Stage 1 Issue FSM (hold current Stage-1 read on Port-A write collision)
            if (!(pipe1_en && rd_hold_eff)) begin
                case (state)
                    S_IDLE: begin
                        pipe1_en <= 1'b0;
                        if (start) begin
                            reg_comp         <= comp;
                            reg_tu_size_log2 <= tu_size_log2;
                            reg_base_x       <= base_x;
                            reg_base_y       <= base_y;
                            reg_mode         <= in_mode;

                            rd_addr_a        <= comb_rd_addr_a;
                            rd_addr_b        <= comb_rd_addr_b;
                            pipe1_en         <= 1'b1;
                            pipe1_b_en       <= comb_b_en;
                            pipe1_mode       <= comb_pmode;
                            pipe1_wya        <= comb_wya;
                            pipe1_wxa        <= comb_wxa;
                            pipe1_wyb        <= comb_wyb;
                            pipe1_wxb        <= comb_wxb;
                            pipe1_emit       <= comb_emit;
                            pipe1_last       <= comb_last;
                            pipe1_save_row0  <= comb_save_row0;
                            pipe1_shift_h    <= comb_shift_h;
                            pipe1_shift_v    <= comb_shift_v;
                            pipe1_px         <= 6'd0;
                            pipe1_py         <= 6'd0;

                            if (step_max == 5'd0) begin
                                // 0D mode advances pixel immediately
                                issue_x    <= 6'd1;
                                issue_y    <= 6'd0;
                                issue_step <= 5'd0;
                            end else begin
                                issue_x    <= 6'd0;
                                issue_y    <= 6'd0;
                                issue_step <= 5'd1;
                            end
                            state <= S_ACTIVE;
                        end
                    end

                    S_ACTIVE: begin
                        rd_addr_a        <= comb_rd_addr_a;
                        rd_addr_b        <= comb_rd_addr_b;
                        pipe1_en         <= 1'b1;
                        pipe1_b_en       <= comb_b_en;
                        pipe1_mode       <= comb_pmode;
                        pipe1_wya        <= comb_wya;
                        pipe1_wxa        <= comb_wxa;
                        pipe1_wyb        <= comb_wyb;
                        pipe1_wxb        <= comb_wxb;
                        pipe1_emit       <= comb_emit;
                        pipe1_last       <= comb_last;
                        pipe1_save_row0  <= comb_save_row0;
                        pipe1_shift_h    <= comb_shift_h;
                        pipe1_shift_v    <= comb_shift_v;
                        pipe1_px         <= issue_x;
                        pipe1_py         <= issue_y;

                        if (comb_last) begin
                            state <= S_WAIT_LAST;
                        end else if (issue_step == step_max) begin
                            issue_step <= 5'd0;
                            if (iss_last_x) begin
                                issue_x <= 6'd0;
                                issue_y <= issue_y + 6'd1;
                            end else begin
                                issue_x <= issue_x + 6'd1;
                            end
                        end else begin
                            issue_step <= issue_step + 5'd1;
                        end
                    end

                    S_WAIT_LAST: begin
                        pipe1_en <= 1'b0;
                        if (pipe2_en && pipe2_last) begin
                            state <= S_IDLE;
                        end
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
