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

    localparam S_IDLE       = 3'd0;
    localparam S_LOAD_REF   = 3'd1;
    localparam S_EVAL       = 3'd2;
    localparam S_DONE       = 3'd3;

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
    
    wire [15:0] wL = (N[7:0] - 8'd1 - {2'd0, cx_q}) * refL_y;
    wire [15:0] wR = ({2'd0, cx_q} + 8'd1) * refT_N;
    wire [15:0] wT = (N[7:0] - 8'd1 - {2'd0, cy_q}) * refT_x;
    wire [15:0] wB = ({2'd0, cy_q} + 8'd1) * refL_N;
    
    wire [15:0] planar_sum = wL + wR + wT + wB + N;
    wire [`PIXEL_WIDTH-1:0] pred_planar = planar_sum >> (pu_size_log2 + 1);

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
        end else begin
            state <= next_state;
            
            case (state)
                S_IDLE: begin
                    rmd_done <= 0;
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
                    end
                end
                
                S_DONE: begin
                    rmd_done <= 1;
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
                end
            endcase
        end
    end

    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE: if (start && pu_size_log2 <= 3'd5) next_state = S_LOAD_REF;
            S_LOAD_REF: if (ref_valid && ref_last) next_state = S_EVAL;
            S_EVAL: if (!eval_q && cy == N) next_state = S_DONE;
            S_DONE: next_state = S_IDLE;
        endcase
    end

endmodule
