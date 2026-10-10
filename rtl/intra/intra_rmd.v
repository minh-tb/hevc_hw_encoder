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

    // Reference memory load
    input  wire         ref_valid,
    input  wire [`PIXEL_WIDTH-1:0] ref_sample,
    input  wire [7:0]   ref_idx,
    input  wire         ref_last,

    // Outputs to mode_decision
    output reg          rmd_done,
    output reg  [5:0]   best_mode,
    output reg  [31:0]  best_cost
);

`ifdef REMEDIATION
    localparam S_IDLE       = 3'd0;
    localparam S_LOAD_REF   = 3'd1;
    localparam S_EVAL       = 3'd2;
    localparam S_HADAMARD   = 3'd3;
    localparam S_DONE       = 3'd4;
`else
    localparam S_IDLE       = 3'd0;
    localparam S_LOAD_REF   = 3'd1;
    localparam S_EVAL       = 3'd2;
    localparam S_DONE       = 3'd3;
`endif

    reg [2:0] state, next_state;

    // Reference array (max 129 samples for N=32)
    reg [`PIXEL_WIDTH-1:0] ref_buf [0:128];

`ifndef SYNTHESIS
    integer rmd_init_i;
    initial begin
        for (rmd_init_i = 0; rmd_init_i <= 128; rmd_init_i = rmd_init_i + 1)
            ref_buf[rmd_init_i] = 10'd512;
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            for (rmd_init_i = 0; rmd_init_i <= 128; rmd_init_i = rmd_init_i + 1)
                ref_buf[rmd_init_i] <= 10'd512;
        end
    end
`endif

    // Iteration counters
    reg [5:0] cx, cy;
    wire [7:0] N = 8'd1 << pu_size_log2;  // 8-bit to avoid overflow (N<<1 = 64 for log2=5)

    // Internal latches for pu_x/pu_y (captured on start)
    reg [5:0] lat_pu_x, lat_pu_y;

    // Pipeline registers for coordinates to match orig_rd_data latency
    reg [5:0] cx_q, cy_q;
    reg       eval_q;

    // Accumulators
    reg [31:0] sad_planar, sad_dc, sad_hor, sad_ver;

    // DC Prediction (Average of N top + N left reference samples)
    // top:  ref[1..N]
    // left: ref[2N+1..3N]
    reg [15:0] dc_sum;
    always @(posedge clk) begin
        if (state == S_LOAD_REF && ref_valid) begin
            // Top row: ref[1..N]
            if (ref_idx >= 8'd1 && ref_idx <= N[7:0]) begin
                dc_sum <= dc_sum + ref_sample;
            end
            // Left col: ref[2N+1..3N]
            if (ref_idx >= (N<<1) + 8'd1 && ref_idx <= (N<<1) + N[7:0]) begin
                dc_sum <= dc_sum + ref_sample;
            end
        end else if (state == S_IDLE) begin
            dc_sum <= 0;
        end
    end
    
    // Divide by 2N with rounding -> (dc_sum + N) >> (pu_size_log2 + 1)
    wire [15:0] dc_val = (dc_sum + {8'd0, N}) >> (pu_size_log2 + 1);
    wire [`PIXEL_WIDTH-1:0] pred_dc = dc_val[`PIXEL_WIDTH-1:0];

    // Horizontal Prediction
    wire [7:0] idx_left = (N << 1) + 8'd1 + {2'd0, cy_q};
    wire [`PIXEL_WIDTH-1:0] pred_hor = ref_buf[idx_left];

    // Vertical Prediction
    wire [7:0] idx_top = 8'd1 + {2'd0, cx_q};
    wire [`PIXEL_WIDTH-1:0] pred_ver = ref_buf[idx_top];

    // Planar Prediction
    wire [`PIXEL_WIDTH-1:0] refL_y = ref_buf[idx_left];
    wire [`PIXEL_WIDTH-1:0] refT_x = ref_buf[idx_top];
    wire [7:0] idx_refT_N = 8'd1 + N[7:0];            // Top-right corner = ref_buf[1+N]
    wire [7:0] idx_refL_N = (N << 1) + 8'd1 + N[7:0];  // Bottom-left corner = ref_buf[2N+1+N]
    wire [`PIXEL_WIDTH-1:0] refT_N = ref_buf[idx_refT_N];
    wire [`PIXEL_WIDTH-1:0] refL_N = ref_buf[idx_refL_N];
    
`ifdef REMEDIATION
    wire [17:0] wL = (N[7:0] - 8'd1 - {2'd0, cx_q}) * refL_y;
    wire [17:0] wR = ({2'd0, cx_q} + 8'd1) * refT_N;
    wire [17:0] wT = (N[7:0] - 8'd1 - {2'd0, cy_q}) * refT_x;
    wire [17:0] wB = ({2'd0, cy_q} + 8'd1) * refL_N;
    
    wire [17:0] planar_sum = wL + wR + wT + wB + {10'd0, N};
    wire [17:0] raw_pred_planar = planar_sum >> (pu_size_log2 + 1);
    wire [`PIXEL_WIDTH-1:0] pred_planar = (raw_pred_planar > 18'd1023) ? 10'd1023 : raw_pred_planar[`PIXEL_WIDTH-1:0];

    // Buffer 4x4 differences for Hadamard transform
    reg signed [10:0] diff_planar_buf [0:15];
    reg signed [10:0] diff_dc_buf     [0:15];
    reg signed [10:0] diff_hor_buf    [0:15];
    reg signed [10:0] diff_ver_buf    [0:15];

    wire signed [10:0] diff_p = $signed({1'b0, orig_rd_data}) - $signed({1'b0, pred_planar});
    wire signed [10:0] diff_d = $signed({1'b0, orig_rd_data}) - $signed({1'b0, pred_dc});
    wire signed [10:0] diff_h = $signed({1'b0, orig_rd_data}) - $signed({1'b0, pred_hor});
    wire signed [10:0] diff_v = $signed({1'b0, orig_rd_data}) - $signed({1'b0, pred_ver});

    reg had_start;
    wire had_done_p, had_done_d, had_done_h, had_done_v;
    wire [15:0] satd_p, satd_d, satd_h, satd_v;

    hadamard_satd_4x4 u_had_p (
        .clk(clk), .rst_n(rst_n), .start(had_start),
        .diff_0(diff_planar_buf[0]), .diff_1(diff_planar_buf[1]), .diff_2(diff_planar_buf[2]), .diff_3(diff_planar_buf[3]),
        .diff_4(diff_planar_buf[4]), .diff_5(diff_planar_buf[5]), .diff_6(diff_planar_buf[6]), .diff_7(diff_planar_buf[7]),
        .diff_8(diff_planar_buf[8]), .diff_9(diff_planar_buf[9]), .diff_10(diff_planar_buf[10]), .diff_11(diff_planar_buf[11]),
        .diff_12(diff_planar_buf[12]), .diff_13(diff_planar_buf[13]), .diff_14(diff_planar_buf[14]), .diff_15(diff_planar_buf[15]),
        .done(had_done_p), .satd_out(satd_p)
    );

    hadamard_satd_4x4 u_had_d (
        .clk(clk), .rst_n(rst_n), .start(had_start),
        .diff_0(diff_dc_buf[0]), .diff_1(diff_dc_buf[1]), .diff_2(diff_dc_buf[2]), .diff_3(diff_dc_buf[3]),
        .diff_4(diff_dc_buf[4]), .diff_5(diff_dc_buf[5]), .diff_6(diff_dc_buf[6]), .diff_7(diff_dc_buf[7]),
        .diff_8(diff_dc_buf[8]), .diff_9(diff_dc_buf[9]), .diff_10(diff_dc_buf[10]), .diff_11(diff_dc_buf[11]),
        .diff_12(diff_dc_buf[12]), .diff_13(diff_dc_buf[13]), .diff_14(diff_dc_buf[14]), .diff_15(diff_dc_buf[15]),
        .done(had_done_d), .satd_out(satd_d)
    );

    hadamard_satd_4x4 u_had_h (
        .clk(clk), .rst_n(rst_n), .start(had_start),
        .diff_0(diff_hor_buf[0]), .diff_1(diff_hor_buf[1]), .diff_2(diff_hor_buf[2]), .diff_3(diff_hor_buf[3]),
        .diff_4(diff_hor_buf[4]), .diff_5(diff_hor_buf[5]), .diff_6(diff_hor_buf[6]), .diff_7(diff_hor_buf[7]),
        .diff_8(diff_hor_buf[8]), .diff_9(diff_hor_buf[9]), .diff_10(diff_hor_buf[10]), .diff_11(diff_hor_buf[11]),
        .diff_12(diff_hor_buf[12]), .diff_13(diff_hor_buf[13]), .diff_14(diff_hor_buf[14]), .diff_15(diff_hor_buf[15]),
        .done(had_done_h), .satd_out(satd_h)
    );

    hadamard_satd_4x4 u_had_v (
        .clk(clk), .rst_n(rst_n), .start(had_start),
        .diff_0(diff_ver_buf[0]), .diff_1(diff_ver_buf[1]), .diff_2(diff_ver_buf[2]), .diff_3(diff_ver_buf[3]),
        .diff_4(diff_ver_buf[4]), .diff_5(diff_ver_buf[5]), .diff_6(diff_ver_buf[6]), .diff_7(diff_ver_buf[7]),
        .diff_8(diff_ver_buf[8]), .diff_9(diff_ver_buf[9]), .diff_10(diff_ver_buf[10]), .diff_11(diff_ver_buf[11]),
        .diff_12(diff_ver_buf[12]), .diff_13(diff_ver_buf[13]), .diff_14(diff_ver_buf[14]), .diff_15(diff_ver_buf[15]),
        .done(had_done_v), .satd_out(satd_v)
    );
`else
    wire [15:0] wL = (N[7:0] - 8'd1 - {2'd0, cx_q}) * refL_y;
    wire [15:0] wR = ({2'd0, cx_q} + 8'd1) * refT_N;
    wire [15:0] wT = (N[7:0] - 8'd1 - {2'd0, cy_q}) * refT_x;
    wire [15:0] wB = ({2'd0, cy_q} + 8'd1) * refL_N;
    
    wire [15:0] planar_sum = wL + wR + wT + wB + N;
    wire [`PIXEL_WIDTH-1:0] pred_planar = planar_sum >> (pu_size_log2 + 1);
`endif

    // Absolute Differences
    wire [31:0] ad_planar = (orig_rd_data > pred_planar) ? (orig_rd_data - pred_planar) : (pred_planar - orig_rd_data);
    wire [31:0] ad_dc     = (orig_rd_data > pred_dc)     ? (orig_rd_data - pred_dc)     : (pred_dc - orig_rd_data);
    wire [31:0] ad_hor    = (orig_rd_data > pred_hor)    ? (orig_rd_data - pred_hor)    : (pred_hor - orig_rd_data);
    wire [31:0] ad_ver    = (orig_rd_data > pred_ver)    ? (orig_rd_data - pred_ver)    : (pred_ver - orig_rd_data);

    assign rmd_active = (state == S_EVAL);

    // FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            rmd_done <= 0;
            cx <= 0; cy <= 0;
            cx_q <= 0; cy_q <= 0;
            eval_q <= 0;
            sad_planar <= 0; sad_dc <= 0; sad_hor <= 0; sad_ver <= 0;
            lat_pu_x <= 0; lat_pu_y <= 0;
            orig_rd_addr <= 0;
`ifdef REMEDIATION
            had_start <= 1'b0;
`endif
        end else begin
            state <= next_state;
            
            case (state)
                S_IDLE: begin
                    rmd_done <= 0;
`ifdef REMEDIATION
                    had_start <= 1'b0;
`endif
                    if (start) begin
                        if (pu_size_log2 > 3'd5) begin
                            // Fast return for 64x64
                            rmd_done <= 1;
                            best_cost <= 32'hFFFFFFFF;
                            best_mode <= 6'd0;
                        end else begin
                            cx <= 0; cy <= 0;
                            sad_planar <= 0; sad_dc <= 0; sad_hor <= 0; sad_ver <= 0;
                            eval_q <= 0;
                            lat_pu_x <= pu_x;
                            lat_pu_y <= pu_y;
                        end
                    end
                end
                
                S_LOAD_REF: begin
                    if (ref_valid) ref_buf[ref_idx] <= ref_sample;
                end
                
                S_EVAL: begin
                    // Read Request
                    if (cy < N[5:0]) begin
                        orig_rd_addr <= { (lat_pu_y + cy[5:0]), (lat_pu_x + cx[5:0]) };
                        if (cx == N[5:0] - 6'd1) begin
                            cx <= 0;
                            cy <= cy + 1;
                        end else begin
                            cx <= cx + 1;
                        end
                    end
                    
                    // Pipeline
                    cx_q <= cx;
                    cy_q <= cy;
                    eval_q <= (cy < N[5:0]);
                    
                    // Accumulate
                    if (eval_q) begin
                        sad_planar <= sad_planar + ad_planar;
                        sad_dc     <= sad_dc     + ad_dc;
                        sad_hor    <= sad_hor    + ad_hor;
                        sad_ver    <= sad_ver    + ad_ver;
`ifdef REMEDIATION
                        if (pu_size_log2 == 3'd2) begin
                            diff_planar_buf[{cy_q[1:0], cx_q[1:0]}] <= diff_p;
                            diff_dc_buf    [{cy_q[1:0], cx_q[1:0]}] <= diff_d;
                            diff_hor_buf   [{cy_q[1:0], cx_q[1:0]}] <= diff_h;
                            diff_ver_buf   [{cy_q[1:0], cx_q[1:0]}] <= diff_v;
                        end
`endif
                    end
`ifdef REMEDIATION
                    if (!eval_q && cy == N && pu_size_log2 == 3'd2) begin
                        had_start <= 1'b1;
                    end
`endif
                end
                
`ifdef REMEDIATION
                S_HADAMARD: begin
                    had_start <= 1'b0;
                    if (had_done_p) begin
                        if (satd_p <= satd_d && satd_p <= satd_h && satd_p <= satd_v) begin
                            best_mode <= `INTRA_PLANAR;
                            best_cost <= {16'd0, satd_p};
                        end else if (satd_d <= satd_h && satd_d <= satd_v) begin
                            best_mode <= `INTRA_DC;
                            best_cost <= {16'd0, satd_d};
                        end else if (satd_h <= satd_v) begin
                            best_mode <= 6'd10;
                            best_cost <= {16'd0, satd_h};
                        end else begin
                            best_mode <= 6'd26;
                            best_cost <= {16'd0, satd_v};
                        end
                    end
                end
`endif

                S_DONE: begin
                    rmd_done <= 1;
`ifdef REMEDIATION
                    if (pu_size_log2 != 3'd2) begin
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
                    end
`else
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
`endif
                end
            endcase
        end
    end

    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE: if (start && pu_size_log2 <= 3'd5) next_state = S_LOAD_REF;
            S_LOAD_REF: if (ref_valid && ref_last) next_state = S_EVAL;
`ifdef REMEDIATION
            S_EVAL: begin
                if (!eval_q && cy == N) begin
                    if (pu_size_log2 == 3'd2) next_state = S_HADAMARD;
                    else next_state = S_DONE;
                end
            end
            S_HADAMARD: if (had_done_p) next_state = S_DONE;
`else
            S_EVAL: if (!eval_q && cy == N) next_state = S_DONE;
`endif
            S_DONE: next_state = S_IDLE;
        endcase
    end

endmodule
