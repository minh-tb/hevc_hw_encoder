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
    localparam S_DONE       = 3'd3;

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

    reg [5:0]  cx, cy;

    reg [5:0]  cx_q1, cy_q1, cx_q2, cy_q2;
    reg        eval_q1, eval_q2;
    reg        eval_c_q1, eval_c_q2;

    // Accumulators
    reg [31:0] sad_planar, sad_dc, sad_hor, sad_ver;
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
    
    wire [15:0] wL = (N[7:0] - 8'd1 - {2'd0, cx_q2}) * refL_y;
    wire [15:0] wR = ({2'd0, cx_q2} + 8'd1) * refT_N;
    wire [15:0] wT = (N[7:0] - 8'd1 - {2'd0, cy_q2}) * refT_x;
    wire [15:0] wB = ({2'd0, cy_q2} + 8'd1) * refL_N;
    
    wire [15:0] planar_sum = wL + wR + wT + wB + N;
    wire [`PIXEL_WIDTH-1:0] pred_planar = planar_sum >> (pu_size_log2 + 1);

    // Absolute Differences (used only in unpatched spatial-SAD mode)
    wire [31:0] ad_planar = (orig_rd_data > pred_planar) ? (orig_rd_data - pred_planar) : (pred_planar - orig_rd_data);
    wire [31:0] ad_dc     = (orig_rd_data > pred_dc)     ? (orig_rd_data - pred_dc)     : (pred_dc - orig_rd_data);
    wire [31:0] ad_hor    = (orig_rd_data > pred_hor)    ? (orig_rd_data - pred_hor)    : (pred_hor - orig_rd_data);
    wire [31:0] ad_ver    = (orig_rd_data > pred_ver)    ? (orig_rd_data - pred_ver)    : (pred_ver - orig_rd_data);

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
    wire [5:0] luma_mode_sad = (sad_planar <= sad_dc && sad_planar <= sad_hor && sad_planar <= sad_ver) ? `INTRA_PLANAR :
                               (sad_dc <= sad_hor && sad_dc <= sad_ver) ? `INTRA_DC :
                               (sad_hor <= sad_ver) ? 6'd10 : 6'd26;
    wire [5:0] win_luma_mode = luma_mode_sad;

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
            cx <= 6'd0; cy <= 6'd0;
            sad_planar <= 32'd0; sad_dc <= 32'd0; sad_hor <= 32'd0; sad_ver <= 32'd0;
        end else begin
            state <= next_state;
            
            case (state)
                S_IDLE: begin
                    rmd_done <= 1'b0;
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
                            cx <= 6'd0; cy <= 6'd0;
                            sad_planar <= 32'd0; sad_dc <= 32'd0; sad_hor <= 32'd0; sad_ver <= 32'd0;
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
                    // Stage 0: Issue BRAM read request
                    if (req_active) begin
                        orig_rd_addr <= { (lat_pu_y + cy), (lat_pu_x + cx) };
                        orig_c_rd_addr <= { (lat_pu_y[5:1] + cy[4:0]), (lat_pu_x[5:1] + cx[4:0]) };
                        cx_q1 <= cx;
                        cy_q1 <= cy;
                        eval_q1 <= 1'b1;
                        eval_c_q1 <= ({2'b00, cy} < N_C && {2'b00, cx} < N_C);

                        if (cx == N[5:0] - 6'd1) begin
                            cx <= 6'd0;
                            if (cy == N[5:0] - 6'd1) begin
                                cy <= 6'd0;
                                req_active <= 1'b0;
                            end else begin
                                cy <= cy + 6'd1;
                            end
                        end else begin
                            cx <= cx + 6'd1;
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
                        sad_planar <= sad_planar + ad_planar;
                        sad_dc     <= sad_dc     + ad_dc;
                        sad_hor    <= sad_hor    + ad_hor;
                        sad_ver    <= sad_ver    + ad_ver;
                    end
                    if (eval_c_q2) begin
                        sad_c_planar <= sad_c_planar + ad_u_planar + ad_v_planar;
                        sad_c_dc     <= sad_c_dc     + ad_u_dc     + ad_v_dc;
                        sad_c_hor    <= sad_c_hor    + ad_u_hor    + ad_v_hor;
                        sad_c_ver    <= sad_c_ver    + ad_u_ver    + ad_v_ver;
                        sad_c_34     <= sad_c_34     + ad_u_34     + ad_v_34;
                    end

                end
                

                S_DONE: begin
                    rmd_done <= 1'b1;
                    // synthesis translate_off
                    $display("Time=%0t: [INTRA_RMD] SAD: planar=%0d dc=%0d hor=%0d ver=%0d", $time, sad_planar, sad_dc, sad_hor, sad_ver);
                    $display("DEBUG [INTRA_RMD]: orig_rd_addr=%0d, orig_rd_data=%h, pred_planar=%h, refL_y=%h, refT_x=%h, refT_N=%h, refL_N=%h", 
                                orig_rd_addr, orig_rd_data, pred_planar, refL_y, refT_x, refT_N, refL_N);
                    // synthesis translate_on
                    // Comparator tree
                    if (sad_planar <= sad_dc && sad_planar <= sad_hor && sad_planar <= sad_ver) begin
                        best_mode <= `INTRA_PLANAR;
                        best_cost <= sad_planar;
                    end else if (sad_dc <= sad_hor && sad_dc <= sad_ver) begin
                        best_mode <= `INTRA_DC;
                        best_cost <= sad_dc;
                    end else if (sad_hor <= sad_ver) begin
                        best_mode <= 6'd10;
                        best_cost <= sad_hor;
                    end else begin
                        best_mode <= 6'd26;
                        best_cost <= sad_ver;
                    end
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
            S_EVAL:     if (!req_active && !eval_q1 && !eval_q2) next_state = S_DONE;
            S_DONE:     next_state = S_IDLE;
        endcase
    end

endmodule
