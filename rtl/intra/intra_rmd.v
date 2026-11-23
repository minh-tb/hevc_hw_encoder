`include "parameter_pkg.vh"

module intra_rmd (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         start,
    input  wire [5:0]   pu_x,
    input  wire [5:0]   pu_y,
    input  wire [2:0]   pu_size_log2,

    // Original memory read interface
    output reg  [11:0]  orig_rd_addr,
    output wire         rmd_active,

    // Original memory read data (1 cycle latency)
    input  wire [`PIXEL_WIDTH-1:0] orig_rd_data,

    // Chroma original memory read interface (1 pixel/cycle, synchronous BRAM read)
    output reg  [9:0]               orig_c_rd_addr,
    input  wire [`PIXEL_WIDTH-1:0]  orig_u_rd_data,
    input  wire [`PIXEL_WIDTH-1:0]  orig_v_rd_data,

    // Reference memory load
    input  wire         ref_valid,
    input  wire [`PIXEL_WIDTH-1:0] ref_sample,
    input  wire [7:0]   ref_idx,
    input  wire         ref_last,

    // Sequential chroma reference load (1 pixel/cycle during S_LOAD_REF)
    input  wire [`PIXEL_WIDTH-1:0]  ref_sample_u,
    input  wire [`PIXEL_WIDTH-1:0]  ref_sample_v,

    // Outputs to mode_decision
    output reg          rmd_done,
    output reg  [5:0]   best_mode,
    output reg  [31:0]  best_cost,

    // Chroma Intra RDO outputs (ITU-T H.265 Clause 8.4.3 Table 8-2)
    output reg  [2:0]   best_chroma_pred_mode,
    output reg  [5:0]   best_chroma_dir
);

    localparam S_IDLE       = 3'd0;
    localparam S_LOAD_REF   = 3'd1;
    localparam S_EVAL       = 3'd2;
    localparam S_HADAMARD   = 3'd3;
    localparam S_DONE       = 3'd4;

    reg [2:0] state, next_state;

    // Reference array (max 129 samples for N=32)
    reg [`PIXEL_WIDTH-1:0] ref_buf   [0:128];
    // Chroma reference arrays (max 65 samples for N_C=16)
    reg [`PIXEL_WIDTH-1:0] ref_buf_u [0:64];
    reg [`PIXEL_WIDTH-1:0] ref_buf_v [0:64];

`ifndef SYNTHESIS
    integer rmd_init_i;
    initial begin
        for (rmd_init_i = 0; rmd_init_i <= 128; rmd_init_i = rmd_init_i + 1)
            ref_buf[rmd_init_i] = 10'd512;
        for (rmd_init_i = 0; rmd_init_i <= 64; rmd_init_i = rmd_init_i + 1) begin
            ref_buf_u[rmd_init_i] = 10'd512;
            ref_buf_v[rmd_init_i] = 10'd512;
        end
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            for (rmd_init_i = 0; rmd_init_i <= 128; rmd_init_i = rmd_init_i + 1)
                ref_buf[rmd_init_i] <= 10'd512;
            for (rmd_init_i = 0; rmd_init_i <= 64; rmd_init_i = rmd_init_i + 1) begin
                ref_buf_u[rmd_init_i] <= 10'd512;
                ref_buf_v[rmd_init_i] <= 10'd512;
            end
        end
    end
`endif

    // Iteration & pipeline registers (2-stage q1->q2 matches 1-cycle synchronous BRAM latency)
    wire [7:0] N = 8'd1 << pu_size_log2;  // 8-bit to avoid overflow (N<<1 = 64 for log2=5)
    wire [7:0] N_C = N >> 1;

    reg        req_active;
    reg [5:0]  lat_pu_x, lat_pu_y;

    reg [1:0]  sub_x, sub_y;
    reg [2:0]  tile_x, tile_y;
    wire [3:0] tile_max_w = N[5:2] - 4'd1;
    wire [2:0] tile_max = tile_max_w[2:0];
    wire [6:0] total_tiles = (pu_size_log2 == 3'd2) ? 7'd1 :
                             (pu_size_log2 == 3'd3) ? 7'd4 :
                             (pu_size_log2 == 3'd4) ? 7'd16 : 7'd64;
    wire [5:0] cx = {1'b0, tile_x, sub_x};
    wire [5:0] cy = {1'b0, tile_y, sub_y};

    reg [5:0]  cx_q1, cy_q1, cx_q2, cy_q2;
    reg        eval_q1, eval_q2;
    reg        eval_c_q1, eval_c_q2;

    // Accumulators
    reg [31:0] satd_acc_p, satd_acc_d, satd_acc_h, satd_acc_v;
    reg [6:0]  tiles_acc;
    reg [31:0] sad_c_planar, sad_c_dc, sad_c_hor, sad_c_ver, sad_c_34;

    // DC Prediction (Average of N top + N left reference samples)
    // top:  ref[1..N]
    // left: ref[2N+1..3N]
    reg [15:0] dc_sum;
    reg [15:0] dc_sum_u, dc_sum_v;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dc_sum   <= 16'd0;
            dc_sum_u <= 16'd0;
            dc_sum_v <= 16'd0;
        end else if (state == S_LOAD_REF && ref_valid) begin
            // Top row: ref[1..N]
            if (ref_idx >= 8'd1 && ref_idx <= N[7:0]) begin
                dc_sum <= dc_sum + ref_sample;
            end
            // Left col: ref[2N+1..3N]
            if (ref_idx >= (N<<1) + 8'd1 && ref_idx <= (N<<1) + N[7:0]) begin
                dc_sum <= dc_sum + ref_sample;
            end
            // Chroma top: ref_u/v[1..N_C]
            if (ref_idx >= 8'd1 && ref_idx <= N_C) begin
                dc_sum_u <= dc_sum_u + ref_sample_u;
                dc_sum_v <= dc_sum_v + ref_sample_v;
            end
            // Chroma left: ref_u/v[2N_C+1..3N_C] = [N+1..N+N_C]
            if (ref_idx >= N + 8'd1 && ref_idx <= N + N_C) begin
                dc_sum_u <= dc_sum_u + ref_sample_u;
                dc_sum_v <= dc_sum_v + ref_sample_v;
            end
        end else if (state == S_IDLE) begin
            dc_sum   <= 16'd0;
            dc_sum_u <= 16'd0;
            dc_sum_v <= 16'd0;
        end
    end
    
    // Divide by 2N with rounding -> (dc_sum + N) >> (pu_size_log2 + 1)
    wire [15:0] dc_val = (dc_sum + {8'd0, N}) >> (pu_size_log2 + 1);
    wire [`PIXEL_WIDTH-1:0] pred_dc = dc_val[`PIXEL_WIDTH-1:0];

    // Chroma DC: 2*N_C = N samples, rounded divide by N: (dc_sum + N_C) >> pu_size_log2
    wire [15:0] dc_val_u = (dc_sum_u + {8'd0, N_C}) >> pu_size_log2;
    wire [15:0] dc_val_v = (dc_sum_v + {8'd0, N_C}) >> pu_size_log2;
    wire [`PIXEL_WIDTH-1:0] pred_dc_u = dc_val_u[`PIXEL_WIDTH-1:0];
    wire [`PIXEL_WIDTH-1:0] pred_dc_v = dc_val_v[`PIXEL_WIDTH-1:0];

    // Horizontal Prediction
    wire [7:0] idx_left = (N << 1) + 8'd1 + {2'd0, cy_q2};
    wire [`PIXEL_WIDTH-1:0] pred_hor = ref_buf[idx_left];

    // Chroma Horizontal Prediction (mode 10)
    wire [7:0] idx_left_c = N + 8'd1 + {3'd0, cy_q2[4:0]};
    wire [`PIXEL_WIDTH-1:0] pred_hor_u = ref_buf_u[idx_left_c[6:0]];
    wire [`PIXEL_WIDTH-1:0] pred_hor_v = ref_buf_v[idx_left_c[6:0]];

    // Vertical Prediction
    wire [7:0] idx_top = 8'd1 + {2'd0, cx_q2};
    wire [`PIXEL_WIDTH-1:0] pred_ver = ref_buf[idx_top];

    // Chroma Vertical Prediction (mode 26)
    wire [7:0] idx_top_c = 8'd1 + {3'd0, cx_q2[4:0]};
    wire [`PIXEL_WIDTH-1:0] pred_ver_u = ref_buf_u[idx_top_c[6:0]];
    wire [`PIXEL_WIDTH-1:0] pred_ver_v = ref_buf_v[idx_top_c[6:0]];

    // Planar Prediction
    wire [`PIXEL_WIDTH-1:0] refL_y = ref_buf[idx_left];
    wire [`PIXEL_WIDTH-1:0] refT_x = ref_buf[idx_top];
    wire [7:0] idx_refT_N = 8'd1 + N[7:0];            // Top-right corner = ref_buf[1+N]
    wire [7:0] idx_refL_N = (N << 1) + 8'd1 + N[7:0];  // Bottom-left corner = ref_buf[2N+1+N]
    wire [`PIXEL_WIDTH-1:0] refT_N = ref_buf[idx_refT_N];
    wire [`PIXEL_WIDTH-1:0] refL_N = ref_buf[idx_refL_N];

    // Chroma Planar Prediction (mode 0)
    wire [7:0] idx_refT_Nc = 8'd1 + N_C;
    wire [7:0] idx_refL_Nc = N + 8'd1 + N_C;
    wire [`PIXEL_WIDTH-1:0] refT_N_u = ref_buf_u[idx_refT_Nc[6:0]];
    wire [`PIXEL_WIDTH-1:0] refL_N_u = ref_buf_u[idx_refL_Nc[6:0]];
    wire [`PIXEL_WIDTH-1:0] refT_N_v = ref_buf_v[idx_refT_Nc[6:0]];
    wire [`PIXEL_WIDTH-1:0] refL_N_v = ref_buf_v[idx_refL_Nc[6:0]];

    wire [17:0] wL_u = (N_C - 8'd1 - {3'd0, cx_q2[4:0]}) * pred_hor_u;
    wire [17:0] wR_u = ({3'd0, cx_q2[4:0]} + 8'd1) * refT_N_u;
    wire [17:0] wT_u = (N_C - 8'd1 - {3'd0, cy_q2[4:0]}) * pred_ver_u;
    wire [17:0] wB_u = ({3'd0, cy_q2[4:0]} + 8'd1) * refL_N_u;
    wire [17:0] planar_sum_u = wL_u + wR_u + wT_u + wB_u + {10'd0, N_C};
    wire [17:0] raw_pred_planar_u = planar_sum_u >> pu_size_log2;
    wire [`PIXEL_WIDTH-1:0] pred_planar_u = (raw_pred_planar_u > 18'd1023) ? 10'd1023 : raw_pred_planar_u[`PIXEL_WIDTH-1:0];

    wire [17:0] wL_v = (N_C - 8'd1 - {3'd0, cx_q2[4:0]}) * pred_hor_v;
    wire [17:0] wR_v = ({3'd0, cx_q2[4:0]} + 8'd1) * refT_N_v;
    wire [17:0] wT_v = (N_C - 8'd1 - {3'd0, cy_q2[4:0]}) * pred_ver_v;
    wire [17:0] wB_v = ({3'd0, cy_q2[4:0]} + 8'd1) * refL_N_v;
    wire [17:0] planar_sum_v = wL_v + wR_v + wT_v + wB_v + {10'd0, N_C};
    wire [17:0] raw_pred_planar_v = planar_sum_v >> pu_size_log2;
    wire [`PIXEL_WIDTH-1:0] pred_planar_v = (raw_pred_planar_v > 18'd1023) ? 10'd1023 : raw_pred_planar_v[`PIXEL_WIDTH-1:0];

    // Chroma Diagonal 34 Prediction (mode 34: ref_top[x + y + 2])
    wire [6:0] idx_34 = {2'd0, cx_q2[4:0]} + {2'd0, cy_q2[4:0]} + 7'd2;
    wire [`PIXEL_WIDTH-1:0] pred_34_u = ref_buf_u[idx_34];
    wire [`PIXEL_WIDTH-1:0] pred_34_v = ref_buf_v[idx_34];
    
    wire [17:0] wL = (N[7:0] - 8'd1 - {2'd0, cx_q2}) * refL_y;
    wire [17:0] wR = ({2'd0, cx_q2} + 8'd1) * refT_N;
    wire [17:0] wT = (N[7:0] - 8'd1 - {2'd0, cy_q2}) * refT_x;
    wire [17:0] wB = ({2'd0, cy_q2} + 8'd1) * refL_N;
    
    wire [17:0] planar_sum = wL + wR + wT + wB + {10'd0, N};
    wire [17:0] raw_pred_planar = planar_sum >> (pu_size_log2 + 1);
    wire [`PIXEL_WIDTH-1:0] pred_planar = (raw_pred_planar > 18'd1023) ? 10'd1023 : raw_pred_planar[`PIXEL_WIDTH-1:0];

    // Double-buffered 4x4 residual tile banks (User Safeguard #2):
    // wr_bank receives S_EVAL writes while rd_bank holds completed tile steady for u_had_*
    reg signed [10:0] diff_planar_buf [0:31];
    reg signed [10:0] diff_dc_buf     [0:31];
    reg signed [10:0] diff_hor_buf    [0:31];
    reg signed [10:0] diff_ver_buf    [0:31];
    reg               wr_bank, rd_bank;

    wire signed [10:0] diff_p = $signed({1'b0, orig_rd_data}) - $signed({1'b0, pred_planar});
    wire signed [10:0] diff_d = $signed({1'b0, orig_rd_data}) - $signed({1'b0, pred_dc});
    wire signed [10:0] diff_h = $signed({1'b0, orig_rd_data}) - $signed({1'b0, pred_hor});
    wire signed [10:0] diff_v = $signed({1'b0, orig_rd_data}) - $signed({1'b0, pred_ver});

    reg had_start;
    wire had_done_p, had_done_d, had_done_h, had_done_v;
    wire [15:0] satd_p, satd_d, satd_h, satd_v;

    hadamard_satd_4x4 u_had_p (
        .clk(clk), .rst_n(rst_n), .start(had_start),
        .diff_0(diff_planar_buf[{rd_bank, 4'd0}]),   .diff_1(diff_planar_buf[{rd_bank, 4'd1}]),
        .diff_2(diff_planar_buf[{rd_bank, 4'd2}]),   .diff_3(diff_planar_buf[{rd_bank, 4'd3}]),
        .diff_4(diff_planar_buf[{rd_bank, 4'd4}]),   .diff_5(diff_planar_buf[{rd_bank, 4'd5}]),
        .diff_6(diff_planar_buf[{rd_bank, 4'd6}]),   .diff_7(diff_planar_buf[{rd_bank, 4'd7}]),
        .diff_8(diff_planar_buf[{rd_bank, 4'd8}]),   .diff_9(diff_planar_buf[{rd_bank, 4'd9}]),
        .diff_10(diff_planar_buf[{rd_bank, 4'd10}]), .diff_11(diff_planar_buf[{rd_bank, 4'd11}]),
        .diff_12(diff_planar_buf[{rd_bank, 4'd12}]), .diff_13(diff_planar_buf[{rd_bank, 4'd13}]),
        .diff_14(diff_planar_buf[{rd_bank, 4'd14}]), .diff_15(diff_planar_buf[{rd_bank, 4'd15}]),
        .done(had_done_p), .satd_out(satd_p)
    );

    hadamard_satd_4x4 u_had_d (
        .clk(clk), .rst_n(rst_n), .start(had_start),
        .diff_0(diff_dc_buf[{rd_bank, 4'd0}]),   .diff_1(diff_dc_buf[{rd_bank, 4'd1}]),
        .diff_2(diff_dc_buf[{rd_bank, 4'd2}]),   .diff_3(diff_dc_buf[{rd_bank, 4'd3}]),
        .diff_4(diff_dc_buf[{rd_bank, 4'd4}]),   .diff_5(diff_dc_buf[{rd_bank, 4'd5}]),
        .diff_6(diff_dc_buf[{rd_bank, 4'd6}]),   .diff_7(diff_dc_buf[{rd_bank, 4'd7}]),
        .diff_8(diff_dc_buf[{rd_bank, 4'd8}]),   .diff_9(diff_dc_buf[{rd_bank, 4'd9}]),
        .diff_10(diff_dc_buf[{rd_bank, 4'd10}]), .diff_11(diff_dc_buf[{rd_bank, 4'd11}]),
        .diff_12(diff_dc_buf[{rd_bank, 4'd12}]), .diff_13(diff_dc_buf[{rd_bank, 4'd13}]),
        .diff_14(diff_dc_buf[{rd_bank, 4'd14}]), .diff_15(diff_dc_buf[{rd_bank, 4'd15}]),
        .done(had_done_d), .satd_out(satd_d)
    );

    hadamard_satd_4x4 u_had_h (
        .clk(clk), .rst_n(rst_n), .start(had_start),
        .diff_0(diff_hor_buf[{rd_bank, 4'd0}]),   .diff_1(diff_hor_buf[{rd_bank, 4'd1}]),
        .diff_2(diff_hor_buf[{rd_bank, 4'd2}]),   .diff_3(diff_hor_buf[{rd_bank, 4'd3}]),
        .diff_4(diff_hor_buf[{rd_bank, 4'd4}]),   .diff_5(diff_hor_buf[{rd_bank, 4'd5}]),
        .diff_6(diff_hor_buf[{rd_bank, 4'd6}]),   .diff_7(diff_hor_buf[{rd_bank, 4'd7}]),
        .diff_8(diff_hor_buf[{rd_bank, 4'd8}]),   .diff_9(diff_hor_buf[{rd_bank, 4'd9}]),
        .diff_10(diff_hor_buf[{rd_bank, 4'd10}]), .diff_11(diff_hor_buf[{rd_bank, 4'd11}]),
        .diff_12(diff_hor_buf[{rd_bank, 4'd12}]), .diff_13(diff_hor_buf[{rd_bank, 4'd13}]),
        .diff_14(diff_hor_buf[{rd_bank, 4'd14}]), .diff_15(diff_hor_buf[{rd_bank, 4'd15}]),
        .done(had_done_h), .satd_out(satd_h)
    );

    hadamard_satd_4x4 u_had_v (
        .clk(clk), .rst_n(rst_n), .start(had_start),
        .diff_0(diff_ver_buf[{rd_bank, 4'd0}]),   .diff_1(diff_ver_buf[{rd_bank, 4'd1}]),
        .diff_2(diff_ver_buf[{rd_bank, 4'd2}]),   .diff_3(diff_ver_buf[{rd_bank, 4'd3}]),
        .diff_4(diff_ver_buf[{rd_bank, 4'd4}]),   .diff_5(diff_ver_buf[{rd_bank, 4'd5}]),
        .diff_6(diff_ver_buf[{rd_bank, 4'd6}]),   .diff_7(diff_ver_buf[{rd_bank, 4'd7}]),
        .diff_8(diff_ver_buf[{rd_bank, 4'd8}]),   .diff_9(diff_ver_buf[{rd_bank, 4'd9}]),
        .diff_10(diff_ver_buf[{rd_bank, 4'd10}]), .diff_11(diff_ver_buf[{rd_bank, 4'd11}]),
        .diff_12(diff_ver_buf[{rd_bank, 4'd12}]), .diff_13(diff_ver_buf[{rd_bank, 4'd13}]),
        .diff_14(diff_ver_buf[{rd_bank, 4'd14}]), .diff_15(diff_ver_buf[{rd_bank, 4'd15}]),
        .done(had_done_v), .satd_out(satd_v)
    );

    // Chroma Absolute Differences
    wire [31:0] ad_u_planar = (orig_u_rd_data > pred_planar_u) ? (orig_u_rd_data - pred_planar_u) : (pred_planar_u - orig_u_rd_data);
    wire [31:0] ad_u_dc     = (orig_u_rd_data > pred_dc_u)     ? (orig_u_rd_data - pred_dc_u)     : (pred_dc_u - orig_u_rd_data);
    wire [31:0] ad_u_hor    = (orig_u_rd_data > pred_hor_u)    ? (orig_u_rd_data - pred_hor_u)    : (pred_hor_u - orig_u_rd_data);
    wire [31:0] ad_u_ver    = (orig_u_rd_data > pred_ver_u)    ? (orig_u_rd_data - pred_ver_u)    : (pred_ver_u - orig_u_rd_data);
    wire [31:0] ad_u_34     = (orig_u_rd_data > pred_34_u)     ? (orig_u_rd_data - pred_34_u)     : (pred_34_u - orig_u_rd_data);

    wire [31:0] ad_v_planar = (orig_v_rd_data > pred_planar_v) ? (orig_v_rd_data - pred_planar_v) : (pred_planar_v - orig_v_rd_data);
    wire [31:0] ad_v_dc     = (orig_v_rd_data > pred_dc_v)     ? (orig_v_rd_data - pred_dc_v)     : (pred_dc_v - orig_v_rd_data);
    wire [31:0] ad_v_hor    = (orig_v_rd_data > pred_hor_v)    ? (orig_v_rd_data - pred_hor_v)    : (pred_hor_v - orig_v_rd_data);
    wire [31:0] ad_v_ver    = (orig_v_rd_data > pred_ver_v)    ? (orig_v_rd_data - pred_ver_v)    : (pred_ver_v - orig_v_rd_data);
    wire [31:0] ad_v_34     = (orig_v_rd_data > pred_34_v)     ? (orig_v_rd_data - pred_34_v)     : (pred_34_v - orig_v_rd_data);

    assign rmd_active = (state == S_EVAL);

    // Winning Luma Mode derivation for Table 8-2
    wire [5:0] win_luma_mode = best_mode;

    // ITU-T H.265 Clause 8.4.3 Table 8-2 candidate directions
    wire [5:0] dir_cand0 = (win_luma_mode == `INTRA_PLANAR) ? 6'd34 : `INTRA_PLANAR;
    wire [5:0] dir_cand1 = (win_luma_mode == 6'd26)         ? 6'd34 : 6'd26;
    wire [5:0] dir_cand2 = (win_luma_mode == 6'd10)         ? 6'd34 : 6'd10;
    wire [5:0] dir_cand3 = (win_luma_mode == `INTRA_DC)     ? 6'd34 : `INTRA_DC;
    wire [5:0] dir_cand4 = win_luma_mode; // DM_CHROMA

    localparam CHROMA_RATE_LAMBDA = 32'd8;
    wire [31:0] sad_cand0 = (dir_cand0 == `INTRA_PLANAR) ? sad_c_planar :
                            (dir_cand0 == `INTRA_DC)     ? sad_c_dc :
                            (dir_cand0 == 6'd10)         ? sad_c_hor :
                            (dir_cand0 == 6'd26)         ? sad_c_ver : sad_c_34;

    wire [31:0] sad_cand1 = (dir_cand1 == `INTRA_PLANAR) ? sad_c_planar :
                            (dir_cand1 == `INTRA_DC)     ? sad_c_dc :
                            (dir_cand1 == 6'd10)         ? sad_c_hor :
                            (dir_cand1 == 6'd26)         ? sad_c_ver : sad_c_34;

    wire [31:0] sad_cand2 = (dir_cand2 == `INTRA_PLANAR) ? sad_c_planar :
                            (dir_cand2 == `INTRA_DC)     ? sad_c_dc :
                            (dir_cand2 == 6'd10)         ? sad_c_hor :
                            (dir_cand2 == 6'd26)         ? sad_c_ver : sad_c_34;

    wire [31:0] sad_cand3 = (dir_cand3 == `INTRA_PLANAR) ? sad_c_planar :
                            (dir_cand3 == `INTRA_DC)     ? sad_c_dc :
                            (dir_cand3 == 6'd10)         ? sad_c_hor :
                            (dir_cand3 == 6'd26)         ? sad_c_ver : sad_c_34;

    wire [31:0] sad_cand4 = (dir_cand4 == `INTRA_PLANAR) ? sad_c_planar :
                            (dir_cand4 == `INTRA_DC)     ? sad_c_dc :
                            (dir_cand4 == 6'd10)         ? sad_c_hor :
                            (dir_cand4 == 6'd26)         ? sad_c_ver : sad_c_34;

    wire [31:0] cost_cand0 = sad_cand0 + CHROMA_RATE_LAMBDA;
    wire [31:0] cost_cand1 = sad_cand1 + CHROMA_RATE_LAMBDA;
    wire [31:0] cost_cand2 = sad_cand2 + CHROMA_RATE_LAMBDA;
    wire [31:0] cost_cand3 = sad_cand3 + CHROMA_RATE_LAMBDA;
    wire [31:0] cost_cand4 = sad_cand4;

    // FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            rmd_done <= 1'b0;
            req_active <= 1'b0;
            cx_q1 <= 6'd0; cy_q1 <= 6'd0;
            cx_q2 <= 6'd0; cy_q2 <= 6'd0;
            eval_q1 <= 1'b0; eval_q2 <= 1'b0;
            eval_c_q1 <= 1'b0; eval_c_q2 <= 1'b0;
            sad_c_planar <= 32'd0; sad_c_dc <= 32'd0; sad_c_hor <= 32'd0; sad_c_ver <= 32'd0; sad_c_34 <= 32'd0;
            orig_c_rd_addr <= 10'd0;
            best_mode <= 6'd0;
            best_cost <= 32'd0;
            best_chroma_pred_mode <= 3'd4;
            best_chroma_dir <= 6'd0;
            lat_pu_x <= 6'd0; lat_pu_y <= 6'd0;
            orig_rd_addr <= 12'd0;
            sub_x <= 2'd0; sub_y <= 2'd0;
            tile_x <= 3'd0; tile_y <= 3'd0;
            satd_acc_p <= 32'd0; satd_acc_d <= 32'd0; satd_acc_h <= 32'd0; satd_acc_v <= 32'd0;
            tiles_acc <= 7'd0;
            wr_bank <= 1'b0; rd_bank <= 1'b0;
            had_start <= 1'b0;
        end else begin
            state <= next_state;
            
            case (state)
                S_IDLE: begin
                    rmd_done <= 1'b0;
                    had_start <= 1'b0;
                    if (start) begin
                        if (pu_size_log2 > 3'd5) begin
                            // Fast return for 64x64
                            rmd_done <= 1'b1;
                            best_cost <= 32'hFFFFFFFF;
                            best_mode <= 6'd0;
                            best_chroma_pred_mode <= 3'd4;
                            best_chroma_dir <= 6'd0;
                        end else begin
                            req_active <= 1'b1;
                            cx_q1 <= 6'd0; cy_q1 <= 6'd0;
                            cx_q2 <= 6'd0; cy_q2 <= 6'd0;
                            eval_q1 <= 1'b0; eval_q2 <= 1'b0;
                            eval_c_q1 <= 1'b0; eval_c_q2 <= 1'b0;
                            sad_c_planar <= 32'd0; sad_c_dc <= 32'd0; sad_c_hor <= 32'd0; sad_c_ver <= 32'd0; sad_c_34 <= 32'd0;
                            lat_pu_x <= pu_x;
                            lat_pu_y <= pu_y;
                            best_chroma_pred_mode <= 3'd4;
                            best_chroma_dir <= 6'd0;
                            sub_x <= 2'd0; sub_y <= 2'd0;
                            tile_x <= 3'd0; tile_y <= 3'd0;
                            satd_acc_p <= 32'd0; satd_acc_d <= 32'd0; satd_acc_h <= 32'd0; satd_acc_v <= 32'd0;
                            tiles_acc <= 7'd0;
                            wr_bank <= 1'b0; rd_bank <= 1'b0;
                        end
                    end
                end
                
                S_LOAD_REF: begin
                    if (ref_valid) begin
                        ref_buf[ref_idx] <= ref_sample;
                        if (ref_idx <= (N << 1)) begin
                            ref_buf_u[ref_idx[6:0]] <= ref_sample_u;
                            ref_buf_v[ref_idx[6:0]] <= ref_sample_v;
                        end
                    end
                end
                
                S_EVAL: begin
                    had_start <= 1'b0;
                    // Stage 0: Issue BRAM read request
                    if (req_active) begin
                        orig_rd_addr <= { (lat_pu_y + cy), (lat_pu_x + cx) };
                        orig_c_rd_addr <= { (lat_pu_y[5:1] + cy[4:0]), (lat_pu_x[5:1] + cx[4:0]) };
                        cx_q1 <= cx;
                        cy_q1 <= cy;
                        eval_q1 <= 1'b1;
                        eval_c_q1 <= ({2'b00, cy} < N_C && {2'b00, cx} < N_C);

                        if (sub_x == 2'd3) begin
                            sub_x <= 2'd0;
                            if (sub_y == 2'd3) begin
                                sub_y <= 2'd0;
                                if (tile_x == tile_max) begin
                                    tile_x <= 3'd0;
                                    if (tile_y == tile_max) begin
                                        tile_y <= 3'd0;
                                        req_active <= 1'b0;
                                    end else begin
                                        tile_y <= tile_y + 3'd1;
                                    end
                                end else begin
                                    tile_x <= tile_x + 3'd1;
                                end
                            end else begin
                                sub_y <= sub_y + 2'd1;
                            end
                        end else begin
                            sub_x <= sub_x + 2'd1;
                        end
                    end else begin
                        eval_q1 <= 1'b0;
                        eval_c_q1 <= 1'b0;
                    end

                    // Stage 1 (q1 -> q2): Match 1-cycle synchronous BRAM read output register
                    cx_q2 <= cx_q1;
                    cy_q2 <= cy_q1;
                    eval_q2 <= eval_q1;
                    eval_c_q2 <= eval_c_q1;

                    // Stage 2: Consume aligned orig_rd_data / orig_u/v_rd_data
                    if (eval_q2) begin
                        diff_planar_buf[{wr_bank, cy_q2[1:0], cx_q2[1:0]}] <= diff_p;
                        diff_dc_buf    [{wr_bank, cy_q2[1:0], cx_q2[1:0]}] <= diff_d;
                        diff_hor_buf   [{wr_bank, cy_q2[1:0], cx_q2[1:0]}] <= diff_h;
                        diff_ver_buf   [{wr_bank, cy_q2[1:0], cx_q2[1:0]}] <= diff_v;
                        if (cx_q2[1:0] == 2'd3 && cy_q2[1:0] == 2'd3) begin
                            had_start <= 1'b1;
                            rd_bank   <= wr_bank;
                            wr_bank   <= ~wr_bank;
                        end
                    end
                    if (eval_c_q2) begin
                        sad_c_planar <= sad_c_planar + ad_u_planar + ad_v_planar;
                        sad_c_dc     <= sad_c_dc     + ad_u_dc     + ad_v_dc;
                        sad_c_hor    <= sad_c_hor    + ad_u_hor    + ad_v_hor;
                        sad_c_ver    <= sad_c_ver    + ad_u_ver    + ad_v_ver;
                        sad_c_34     <= sad_c_34     + ad_u_34     + ad_v_34;
                    end

                    // Accumulate completed 4x4 tile SATD outputs while streaming subsequent tiles
                    if (had_done_p) begin
                        satd_acc_p <= satd_acc_p + {16'd0, satd_p};
                        satd_acc_d <= satd_acc_d + {16'd0, satd_d};
                        satd_acc_h <= satd_acc_h + {16'd0, satd_h};
                        satd_acc_v <= satd_acc_v + {16'd0, satd_v};
                        tiles_acc  <= tiles_acc + 7'd1;
                    end
                end
                
                S_HADAMARD: begin
                    had_start <= 1'b0;
                    if (had_done_p) begin
                        satd_acc_p <= satd_acc_p + {16'd0, satd_p};
                        satd_acc_d <= satd_acc_d + {16'd0, satd_d};
                        satd_acc_h <= satd_acc_h + {16'd0, satd_h};
                        satd_acc_v <= satd_acc_v + {16'd0, satd_v};
                        tiles_acc  <= tiles_acc + 7'd1;
                    end else if (tiles_acc == total_tiles) begin
                        if (satd_acc_p <= satd_acc_d && satd_acc_p <= satd_acc_h && satd_acc_p <= satd_acc_v) begin
                            best_mode <= `INTRA_PLANAR;
                            best_cost <= satd_acc_p;
                        end else if (satd_acc_d <= satd_acc_h && satd_acc_d <= satd_acc_v) begin
                            best_mode <= `INTRA_DC;
                            best_cost <= satd_acc_d;
                        end else if (satd_acc_h <= satd_acc_v) begin
                            best_mode <= 6'd10;
                            best_cost <= satd_acc_h;
                        end else begin
                            best_mode <= 6'd26;
                            best_cost <= satd_acc_v;
                        end
                    end
                end

                S_DONE: begin
                    rmd_done <= 1'b1;
                    // ITU-T H.265 Clause 8.4.3 Table 8-2 Chroma Intra Mode Selection
                    if (cost_cand4 <= cost_cand0 && cost_cand4 <= cost_cand1 && cost_cand4 <= cost_cand2 && cost_cand4 <= cost_cand3) begin
                        best_chroma_pred_mode <= 3'd4;
                        best_chroma_dir       <= dir_cand4;
                    end else if (cost_cand0 <= cost_cand1 && cost_cand0 <= cost_cand2 && cost_cand0 <= cost_cand3) begin
                        best_chroma_pred_mode <= 3'd0;
                        best_chroma_dir       <= dir_cand0;
                    end else if (cost_cand1 <= cost_cand2 && cost_cand1 <= cost_cand3) begin
                        best_chroma_pred_mode <= 3'd1;
                        best_chroma_dir       <= dir_cand1;
                    end else if (cost_cand2 <= cost_cand3) begin
                        best_chroma_pred_mode <= 3'd2;
                        best_chroma_dir       <= dir_cand2;
                    end else begin
                        best_chroma_pred_mode <= 3'd3;
                        best_chroma_dir       <= dir_cand3;
                    end
                end
            endcase
        end
    end

    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE:     if (start && pu_size_log2 <= 3'd5) next_state = S_LOAD_REF;
            S_LOAD_REF: if (ref_valid && ref_last) next_state = S_EVAL;
            S_EVAL:     if (!req_active && !eval_q1 && !eval_q2) next_state = S_HADAMARD;
            S_HADAMARD: if (!had_done_p && (tiles_acc == total_tiles)) next_state = S_DONE;
            S_DONE:     next_state = S_IDLE;
        endcase
    end

endmodule
