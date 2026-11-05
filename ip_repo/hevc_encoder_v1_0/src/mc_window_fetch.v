//=============================================================================
// mc_window_fetch.v
// Synthesizable Sliding-Column Window DPB Fetch Engine for HEVC Inter Prediction
//
// Normative References:
//   - ITU-T H.265 Clause 8.5.3.3.3 (Fractional sample interpolation)
//   - ITU-T H.265 Clause 8.5.3.3.3.1 (Derivation of reference sample matrices)
//   - HM 18.0 TComInterpolationFilter & TComPrediction
//
// Architecture (Option A: Sliding-Column Window):
//   - Reads DPB RAMs through a single synchronous read port per reference list (1-cycle BRAM latency).
//   - 2-stage tracking pipeline: rd_addr issued at T, BRAM latches at T+1, data sampled at T+2.
//   - At the start of each TU row (x=0): fetches full 8x8 (luma, 64 reads) or 4x4 (chroma, 16 reads).
//   - For each subsequent column (x > 0): shifts window left by 1 column and fetches 8 (luma) or 4 (chroma)
//     new samples into the vacated rightmost column.
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

    // Synchronous DPB RAM read interface
    output reg  [13:0]            rd_addr,             // {y, x} without slot bit, Clip3-clamped
    input  wire [PW-1:0]          rd_data_l0,          // 1-cycle sync BRAM return L0
    input  wire [PW-1:0]          rd_data_l1,          // 1-cycle sync BRAM return L1

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
    // FSM States
    //-------------------------------------------------------------------------
    localparam [2:0]
        S_IDLE          = 3'd0,
        S_FULL_ADDR     = 3'd1,
        S_FULL_DRAIN_1  = 3'd2,
        S_FULL_DRAIN_2  = 3'd3,
        S_COL_ADDR      = 3'd4,
        S_COL_DRAIN_1   = 3'd5,
        S_COL_DRAIN_2   = 3'd6,
        S_EMIT          = 3'd7;

    reg [2:0] state;

    // Latched TU parameters
    reg [1:0]         reg_comp;
    reg [2:0]         reg_tu_size_log2;
    reg signed [12:0] reg_base_x;
    reg signed [12:0] reg_base_y;

    // Current output coordinates within TU
    reg [5:0] cur_x;
    reg [5:0] cur_y;

    // Read address step counter
    reg [6:0] rd_cnt;

    // Window storage (2D arrays)
    reg [PW-1:0] win_mem_l0 [0:7][0:7];
    reg [PW-1:0] win_mem_l1 [0:7][0:7];

    // 2-stage pipeline registers for BRAM synchronous read return (addr -> RAM -> user)
    reg       pipe1_en;
    reg [2:0] pipe1_wy;
    reg [2:0] pipe1_wx;

    reg       pipe2_en;
    reg [2:0] pipe2_wy;
    reg [2:0] pipe2_wx;

    // TU size in pixels: N = 1 << tu_size_log2
    wire [5:0] tu_n = 6'd1 << reg_tu_size_log2;

    // Window dimension: 8 for luma, 4 for chroma
    wire is_luma = (reg_comp == 2'd0);
    wire [6:0] full_cnt_max = is_luma ? 7'd64 : 7'd16;
    wire [6:0] col_cnt_max  = is_luma ? 7'd8  : 7'd4;

    assign busy = (state != S_IDLE);

    //-------------------------------------------------------------------------
    // Combinational next address computation for current rd_cnt
    //-------------------------------------------------------------------------
    reg [2:0] next_wy;
    reg [2:0] next_wx;
    reg signed [12:0] target_x;
    reg signed [12:0] target_y;

    always @(*) begin
        if (state == S_FULL_ADDR || (state == S_IDLE && start)) begin
            if ((state == S_IDLE ? comp : reg_comp) == 2'd0) begin
                next_wy = rd_cnt[5:3];
                next_wx = rd_cnt[2:0];
                target_x = (state == S_IDLE ? base_x : reg_base_x) + $signed({7'd0, cur_x}) + $signed({10'd0, next_wx}) - 13'sd3;
                target_y = (state == S_IDLE ? base_y : reg_base_y) + $signed({7'd0, cur_y}) + $signed({10'd0, next_wy}) - 13'sd3;
            end else begin
                next_wy = {1'b0, rd_cnt[3:2]};
                next_wx = {1'b0, rd_cnt[1:0]};
                target_x = (state == S_IDLE ? base_x : reg_base_x) + $signed({7'd0, cur_x}) + $signed({10'd0, next_wx}) - 13'sd1;
                target_y = (state == S_IDLE ? base_y : reg_base_y) + $signed({7'd0, cur_y}) + $signed({10'd0, next_wy}) - 13'sd1;
            end
        end else begin // S_COL_ADDR
            if (reg_comp == 2'd0) begin
                next_wy = rd_cnt[2:0];
                next_wx = 3'd7;
                target_x = reg_base_x + $signed({7'd0, cur_x}) + 13'sd4; // cur_x + 7 - 3
                target_y = reg_base_y + $signed({7'd0, cur_y}) + $signed({10'd0, next_wy}) - 13'sd3;
            end else begin
                next_wy = {1'b0, rd_cnt[1:0]};
                next_wx = 3'd3;
                target_x = reg_base_x + $signed({7'd0, cur_x}) + 13'sd2; // cur_x + 3 - 1
                target_y = reg_base_y + $signed({7'd0, cur_y}) + $signed({10'd0, next_wy}) - 13'sd1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Flatten helper for current win_mem_l0 and win_mem_l1
    //-------------------------------------------------------------------------
    integer fy_i, fx_i;
    reg [PW*64-1:0] flat_l0_comb;
    reg [PW*64-1:0] flat_l1_comb;
    always @(*) begin
        flat_l0_comb = {(PW*64){1'b0}};
        flat_l1_comb = {(PW*64){1'b0}};
        if (reg_comp == 2'd0) begin
            for (fy_i = 0; fy_i < 8; fy_i = fy_i + 1) begin
                for (fx_i = 0; fx_i < 8; fx_i = fx_i + 1) begin
                    flat_l0_comb[PW*(fy_i*8 + fx_i) +: PW] = win_mem_l0[fy_i][fx_i];
                    flat_l1_comb[PW*(fy_i*8 + fx_i) +: PW] = win_mem_l1[fy_i][fx_i];
                end
            end
        end else begin
            for (fy_i = 0; fy_i < 4; fy_i = fy_i + 1) begin
                for (fx_i = 0; fx_i < 4; fx_i = fx_i + 1) begin
                    flat_l0_comb[PW*(fy_i*4 + fx_i) +: PW] = win_mem_l0[fy_i][fx_i];
                    flat_l1_comb[PW*(fy_i*4 + fx_i) +: PW] = win_mem_l1[fy_i][fx_i];
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // Main Sequential FSM and Datapath
    //-------------------------------------------------------------------------
    integer sh_r, sh_c;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            reg_comp         <= 2'd0;
            reg_tu_size_log2 <= 3'd2;
            reg_base_x       <= 13'sd0;
            reg_base_y       <= 13'sd0;
            cur_x            <= 6'd0;
            cur_y            <= 6'd0;
            rd_cnt           <= 7'd0;
            rd_addr          <= 14'd0;
            pipe1_en         <= 1'b0;
            pipe1_wy         <= 3'd0;
            pipe1_wx         <= 3'd0;
            pipe2_en         <= 1'b0;
            pipe2_wy         <= 3'd0;
            pipe2_wx         <= 3'd0;
            win_valid        <= 1'b0;
            win_x            <= 6'd0;
            win_y            <= 6'd0;
            win_last         <= 1'b0;
            win_l0_flat      <= {(PW*64){1'b0}};
            win_l1_flat      <= {(PW*64){1'b0}};
            for (sh_r = 0; sh_r < 8; sh_r = sh_r + 1) begin
                for (sh_c = 0; sh_c < 8; sh_c = sh_c + 1) begin
                    win_mem_l0[sh_r][sh_c] <= {PW{1'b0}};
                    win_mem_l1[sh_r][sh_c] <= {PW{1'b0}};
                end
            end
        end else begin
            // Default 1-cycle strobes
            win_valid <= 1'b0;
            win_last  <= 1'b0;

            // Pipeline Stage 2: data returns from RAM, write to win_mem
            pipe2_en <= pipe1_en;
            pipe2_wy <= pipe1_wy;
            pipe2_wx <= pipe1_wx;

            if (pipe2_en) begin
                win_mem_l0[pipe2_wy][pipe2_wx] <= rd_data_l0;
                win_mem_l1[pipe2_wy][pipe2_wx] <= rd_data_l1;
            end

            case (state)
                S_IDLE: begin
                    pipe1_en <= 1'b0;
                    if (start) begin
                        reg_comp         <= comp;
                        reg_tu_size_log2 <= tu_size_log2;
                        reg_base_x       <= base_x;
                        reg_base_y       <= base_y;
                        cur_x            <= 6'd0;
                        cur_y            <= 6'd0;
                        rd_cnt           <= 7'd1;

                        // Issue first address (wy=0, wx=0)
                        if (comp == 2'd0)
                            rd_addr <= {clamp_128(base_y - 13'sd3), clamp_128(base_x - 13'sd3)};
                        else
                            rd_addr <= {2'b00, clamp_64(base_y - 13'sd1), clamp_64(base_x - 13'sd1)};

                        pipe1_en <= 1'b1;
                        pipe1_wy <= 3'd0;
                        pipe1_wx <= 3'd0;
                        state    <= S_FULL_ADDR;
                    end
                end

                S_FULL_ADDR: begin
                    // Issue next read address
                    if (reg_comp == 2'd0)
                        rd_addr <= {clamp_128(target_y), clamp_128(target_x)};
                    else
                        rd_addr <= {2'b00, clamp_64(target_y), clamp_64(target_x)};

                    pipe1_en <= 1'b1;
                    pipe1_wy <= next_wy;
                    pipe1_wx <= next_wx;

                    if (rd_cnt == full_cnt_max - 7'd1) begin
                        state <= S_FULL_DRAIN_1;
                    end else begin
                        rd_cnt <= rd_cnt + 7'd1;
                    end
                end

                S_FULL_DRAIN_1: begin
                    // Drain cycle 1: pipe1 advances to pipe2
                    pipe1_en <= 1'b0;
                    state    <= S_FULL_DRAIN_2;
                end

                S_FULL_DRAIN_2: begin
                    // Drain cycle 2: pipe2 writes last sample into win_mem on next posedge
                    pipe1_en <= 1'b0;
                    state    <= S_EMIT;
                end

                S_COL_ADDR: begin
                    // Issue next column sample address
                    if (reg_comp == 2'd0)
                        rd_addr <= {clamp_128(target_y), clamp_128(target_x)};
                    else
                        rd_addr <= {2'b00, clamp_64(target_y), clamp_64(target_x)};

                    pipe1_en <= 1'b1;
                    pipe1_wy <= next_wy;
                    pipe1_wx <= next_wx;

                    if (rd_cnt == col_cnt_max - 7'd1) begin
                        state <= S_COL_DRAIN_1;
                    end else begin
                        rd_cnt <= rd_cnt + 7'd1;
                    end
                end

                S_COL_DRAIN_1: begin
                    // Drain cycle 1: pipe1 advances to pipe2
                    pipe1_en <= 1'b0;
                    state    <= S_COL_DRAIN_2;
                end

                S_COL_DRAIN_2: begin
                    // Drain cycle 2: pipe2 writes last column sample into win_mem on next posedge
                    pipe1_en <= 1'b0;
                    state    <= S_EMIT;
                end

                S_EMIT: begin
                    // Emit 1-cycle valid with current window and coordinates
                    win_valid   <= 1'b1;
                    win_x       <= cur_x;
                    win_y       <= cur_y;
                    win_last    <= (cur_x == tu_n - 6'd1) && (cur_y == tu_n - 6'd1);
                    win_l0_flat <= flat_l0_comb;
                    win_l1_flat <= flat_l1_comb;

                    if ((cur_x == tu_n - 6'd1) && (cur_y == tu_n - 6'd1)) begin
                        // TU complete
                        state <= S_IDLE;
                    end else if (cur_x == tu_n - 6'd1) begin
                        // Row complete, advance to next row start (x=0, y=y+1)
                        cur_x   <= 6'd0;
                        cur_y   <= cur_y + 6'd1;
                        rd_cnt  <= 7'd1;

                        // Issue first address of new row (wy=0, wx=0)
                        if (reg_comp == 2'd0)
                            rd_addr <= {clamp_128(reg_base_y + $signed({7'd0, cur_y + 6'd1}) - 13'sd3),
                                        clamp_128(reg_base_x - 13'sd3)};
                        else
                            rd_addr <= {2'b00,
                                        clamp_64(reg_base_y + $signed({7'd0, cur_y + 6'd1}) - 13'sd1),
                                        clamp_64(reg_base_x - 13'sd1)};

                        pipe1_en <= 1'b1;
                        pipe1_wy <= 3'd0;
                        pipe1_wx <= 3'd0;
                        state    <= S_FULL_ADDR;
                    end else begin
                        // Next column in same row: slide window left by 1 column
                        cur_x <= cur_x + 6'd1;
                        if (reg_comp == 2'd0) begin
                            for (sh_r = 0; sh_r < 8; sh_r = sh_r + 1) begin
                                win_mem_l0[sh_r][0] <= win_mem_l0[sh_r][1];
                                win_mem_l0[sh_r][1] <= win_mem_l0[sh_r][2];
                                win_mem_l0[sh_r][2] <= win_mem_l0[sh_r][3];
                                win_mem_l0[sh_r][3] <= win_mem_l0[sh_r][4];
                                win_mem_l0[sh_r][4] <= win_mem_l0[sh_r][5];
                                win_mem_l0[sh_r][5] <= win_mem_l0[sh_r][6];
                                win_mem_l0[sh_r][6] <= win_mem_l0[sh_r][7];

                                win_mem_l1[sh_r][0] <= win_mem_l1[sh_r][1];
                                win_mem_l1[sh_r][1] <= win_mem_l1[sh_r][2];
                                win_mem_l1[sh_r][2] <= win_mem_l1[sh_r][3];
                                win_mem_l1[sh_r][3] <= win_mem_l1[sh_r][4];
                                win_mem_l1[sh_r][4] <= win_mem_l1[sh_r][5];
                                win_mem_l1[sh_r][5] <= win_mem_l1[sh_r][6];
                                win_mem_l1[sh_r][6] <= win_mem_l1[sh_r][7];
                            end
                        end else begin
                            for (sh_r = 0; sh_r < 4; sh_r = sh_r + 1) begin
                                win_mem_l0[sh_r][0] <= win_mem_l0[sh_r][1];
                                win_mem_l0[sh_r][1] <= win_mem_l0[sh_r][2];
                                win_mem_l0[sh_r][2] <= win_mem_l0[sh_r][3];

                                win_mem_l1[sh_r][0] <= win_mem_l1[sh_r][1];
                                win_mem_l1[sh_r][1] <= win_mem_l1[sh_r][2];
                                win_mem_l1[sh_r][2] <= win_mem_l1[sh_r][3];
                            end
                        end

                        // Issue first read address for new column (wy=0)
                        rd_cnt <= 7'd1;
                        if (reg_comp == 2'd0)
                            rd_addr <= {clamp_128(reg_base_y + $signed({7'd0, cur_y}) - 13'sd3),
                                        clamp_128(reg_base_x + $signed({7'd0, cur_x + 6'd1}) + 13'sd4)};
                        else
                            rd_addr <= {2'b00,
                                        clamp_64(reg_base_y + $signed({7'd0, cur_y}) - 13'sd1),
                                        clamp_64(reg_base_x + $signed({7'd0, cur_x + 6'd1}) + 13'sd2)};

                        pipe1_en <= 1'b1;
                        pipe1_wy <= 3'd0;
                        pipe1_wx <= is_luma ? 3'd7 : 3'd3;
                        state    <= S_COL_ADDR;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
