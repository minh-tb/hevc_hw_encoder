//=============================================================================
// mode_decision.v
// Top-Down Mode Decision & Fast Encoder Split (FEN=1)
//
// Function:
//   Evaluates Intra vs Inter RD Cost for the current CU.
//   Provides immediate split_flag feedback to ctu_partitioner based on 
//   early-termination thresholds since the partitioner traverses Top-Down.
//   Omits: AMP, PCM, TransformSkip, RDOQ (as per HM Main10 RandomAccess config).
//=============================================================================

`include "parameter_pkg.vh"
`include "hevc_interfaces.vh"

module mode_decision (
    input  wire                     clk,
    input  wire                     rst_n,

    //-------------------------------------------------------------------------
    // Interface with CTU Partitioner (Split Feedback)
    //-------------------------------------------------------------------------
    output reg                      split_valid,
    output reg                      split_flag,
    input  wire                     split_ready,
    
    //-------------------------------------------------------------------------
    // Inputs from PU/CU Splitter (Current CU to Evaluate)
    //-------------------------------------------------------------------------
    input  wire                     pu_valid,
    input  wire [6:0]               pu_size,       // 8, 16, 32, 64
    input  wire [1:0]               pu_depth,      // 0=64, 1=32, 2=16, 3=8
    input  wire [1:0]               slice_type,    // 0=B, 1=P, 2=I
    input  wire [5:0]               qp,
    input  wire [9:0]               poc,
    
    //-------------------------------------------------------------------------
    // Cost inputs from Intra Prediction
    //-------------------------------------------------------------------------
    input  wire                     intra_cost_valid,
    input  wire [31:0]              intra_rd_cost,
    input  wire [5:0]               intra_best_mode, // 6-bit mode (0-34)

    //-------------------------------------------------------------------------
    // Cost inputs from Inter Prediction (TZ Search)
    //-------------------------------------------------------------------------
    input  wire                     inter_cost_valid,
    input  wire [31:0]              inter_rd_cost,
    input  wire [11:0]              inter_best_mv_x,
    input  wire [11:0]              inter_best_mv_y,
    
    //-------------------------------------------------------------------------
    // Cost inputs from CABAC (Rate Estimation) - Simplified for FEN
    //-------------------------------------------------------------------------
    input  wire                     rate_cost_valid,
    input  wire [31:0]              est_bit_rate,

    //-------------------------------------------------------------------------
    // Control to trigger Intra/Inter engines
    //-------------------------------------------------------------------------
    output reg                      eval_intra_start,
    output reg                      eval_inter_start,
    
    //-------------------------------------------------------------------------
    // Final Decision Outputs (To downstream stages like transform/quant)
    //-------------------------------------------------------------------------
    output reg                      mode_valid,
    output reg  [31:0]              best_rd_cost,
    output reg                      best_is_intra,
    output reg  [5:0]               best_intra_mode,
    output reg  [11:0]              best_inter_mv_x,
    output reg  [11:0]              best_inter_mv_y
);

    // SLICE TYPES (HEVC spec)
    localparam SLICE_B = 2'd0;
    localparam SLICE_P = 2'd1;
    localparam SLICE_I = 2'd2;

    // FSM States
    localparam S_IDLE         = 3'd0,
               S_EVAL_ENGINES = 3'd1,
               S_WAIT_COSTS   = 3'd2,
               S_COMPARE_MODE = 3'd3,
               S_DECIDE_SPLIT = 3'd4,
               S_DONE         = 3'd5;

    reg [2:0] state, next_state;
    
    // Latched inputs
    reg [6:0] cur_pu_size;
    reg [1:0] cur_pu_depth;
    reg [1:0] cur_slice_type;
    reg [9:0] cur_poc;

    // RD Cost Registers
    reg [31:0] latched_intra_cost;
    reg [5:0]  latched_intra_mode;
    reg        intra_done;

    reg [31:0] latched_inter_cost;
    reg [11:0] latched_inter_mv_x;
    reg [11:0] latched_inter_mv_y;
    reg        inter_done;
    
    //-------------------------------------------------------------------------
    // Fast Encoder Decision (FEN) Split Thresholds
    // Since we traverse Top-Down, we use early termination to decide if we 
    // should stop splitting. If Best Cost < Threshold, we set split_flag = 0.
    //-------------------------------------------------------------------------
    wire [31:0] split_threshold;
    assign split_threshold = (cur_pu_depth == 2'd0) ? 32'd250000 : // 64x64
                             (cur_pu_depth == 2'd1) ? 32'd60000  : // 32x32
                             (cur_pu_depth == 2'd2) ? 32'd15000  : // 16x16
                                                      32'hFFFFFFFF; // 8x8 (Max depth, always leaf)

    // FSM State Register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
        end else begin
            state <= next_state;
        end
    end

    // FSM Next State Logic
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE: begin
                if (pu_valid) next_state = S_EVAL_ENGINES;
            end
            
            S_EVAL_ENGINES: begin
                next_state = S_WAIT_COSTS;
            end
            
            S_WAIT_COSTS: begin
                // I-Slice only waits for Intra. P/B-Slice waits for both.
                if (cur_slice_type == SLICE_I) begin
                    if (intra_done) next_state = S_COMPARE_MODE;
                end else begin
                    if (intra_done && inter_done) next_state = S_COMPARE_MODE;
                end
            end
            
            S_COMPARE_MODE: begin
                next_state = S_DECIDE_SPLIT;
            end
            
            S_DECIDE_SPLIT: begin
                if (split_ready) next_state = S_DONE;
            end
            
            S_DONE: begin
                next_state = S_IDLE;
            end
            
            default: next_state = S_IDLE;
        endcase
    end

    // FSM Outputs & Datapath
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            split_valid        <= 1'b0;
            split_flag         <= 1'b0;
            eval_intra_start   <= 1'b0;
            eval_inter_start   <= 1'b0;
            mode_valid         <= 1'b0;
            
            intra_done         <= 1'b0;
            inter_done         <= 1'b0;
            
            latched_intra_cost <= 32'hFFFFFFFF;
            latched_inter_cost <= 32'hFFFFFFFF;
            best_rd_cost       <= 32'hFFFFFFFF;
            
            cur_pu_size        <= 7'd0;
            cur_pu_depth       <= 2'd0;
            cur_slice_type     <= 2'd0;
        end else begin
            // Default pulse clears
            eval_intra_start <= 1'b0;
            eval_inter_start <= 1'b0;
            mode_valid       <= 1'b0;
            split_valid      <= 1'b0;

            // Capture costs dynamically when valid
            if (intra_cost_valid) begin
                latched_intra_cost <= intra_rd_cost;
                latched_intra_mode <= intra_best_mode;
                intra_done         <= 1'b1;
            end
            if (inter_cost_valid) begin
                latched_inter_cost <= inter_rd_cost;
                latched_inter_mv_x <= inter_best_mv_x;
                latched_inter_mv_y <= inter_best_mv_y;
                inter_done         <= 1'b1;
            end

            case (state)
                S_IDLE: begin
                    if (pu_valid) begin
                        cur_pu_size    <= pu_size;
                        cur_pu_depth   <= pu_depth;
                        cur_slice_type <= slice_type;
                        cur_poc        <= poc;
                        intra_done     <= 1'b0;
                        inter_done     <= 1'b0;
                        latched_intra_cost <= 32'hFFFFFFFF;
                        latched_inter_cost <= 32'hFFFFFFFF;
                    end
                end

                S_EVAL_ENGINES: begin
                    eval_intra_start <= 1'b1;
                    if (cur_slice_type != SLICE_I) begin
                        eval_inter_start <= 1'b1;
                    end else begin
                        inter_done <= 1'b1; // Skip inter wait for I-frames
                    end
                end

                S_COMPARE_MODE: begin
                    // Find the lowest cost
                    if (cur_slice_type == SLICE_I || (latched_intra_cost <= latched_inter_cost)) begin
                        best_is_intra   <= 1'b1;
                        best_rd_cost    <= latched_intra_cost;
                        best_intra_mode <= latched_intra_mode;
                    end else begin
                        best_is_intra   <= 1'b0;
                        best_rd_cost    <= latched_inter_cost;
                        best_inter_mv_x <= latched_inter_mv_x;
                        best_inter_mv_y <= latched_inter_mv_y;
                    end
                end

                S_DECIDE_SPLIT: begin
                    split_valid <= 1'b1;
                    mode_valid  <= 1'b1;
                    
                    // Fast Encoder Decision Logic
                    if (cur_pu_depth == 2'd3) begin
                        // Max depth (8x8) MUST be a leaf
                        split_flag <= 1'b0;
                    end else if (best_rd_cost > split_threshold) begin
                        // Cost is too high, split quadtree deeper
                        split_flag <= 1'b1;
                    end else begin
                        // Cost is acceptable, early termination (FEN=1)
                        split_flag <= 1'b0;
                    end
                    $display("Time=%0t: [MODE_DECISION] POC=%0d, SLICE=%0d, SIZE=%0d, INTRA_COST=%0d, INTER_COST=%0d, BEST_IS_INTRA=%b, SPLIT_FLAG=%b", 
                              $time, cur_poc, cur_slice_type, cur_pu_size, latched_intra_cost, latched_inter_cost, best_is_intra, (best_rd_cost > split_threshold));
                end
            endcase
        end
    end

endmodule
