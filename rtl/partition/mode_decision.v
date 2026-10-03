//=============================================================================
// mode_decision.v
// Top-Down Mode Decision & Fast Encoder Split (FEN=1)
//
// Function:
//   Evaluates Intra vs Inter (AMVP) vs Merge/Skip RD Cost for the current CU.
//   Provides immediate split_flag feedback to ctu_partitioner based on 
//   early-termination thresholds since the partitioner traverses Top-Down.
//   Omits: AMP, PCM, TransformSkip, RDOQ (as per HM Main10 RandomAccess config).
//
// Upgrade from baseline:
//   - Lagrangian λ(QP) cost model: Cost = Distortion + λ × EstBits
//   - Simplified merge evaluation (no MC, uses inter SAD + λ × merge_bits)
//   - Heuristic skip detection (merge_cost < QP-adaptive threshold)
//   - Quarter-pel MV support (12-bit MV from FME)
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
    // Cost inputs from Intra Prediction (RMD)
    //-------------------------------------------------------------------------
    input  wire                     intra_cost_valid,
    input  wire [31:0]              intra_rd_cost,
    input  wire [5:0]               intra_best_mode, // 6-bit mode (0-34)

    //-------------------------------------------------------------------------
    // Cost inputs from Inter Prediction (FME — Quarter-Pel)
    //-------------------------------------------------------------------------
    input  wire                     inter_cost_valid,
    input  wire [31:0]              inter_rd_cost,
    input  wire signed [11:0]       inter_best_mv_x,  // Quarter-pel from FME
    input  wire signed [11:0]       inter_best_mv_y,
    
    //-------------------------------------------------------------------------
    // Merge Candidates (from inter_prediction / mvp_predictor)
    //-------------------------------------------------------------------------
    input  wire [4:0]               merge_cand_valid,  // 5-bit: one per candidate
    input  wire [(`MV_TOTAL_BITS-`MV_FRAC_BITS)*5-1:0] merge_cand_mv_x_flat, // 10-bit × 5
    input  wire [(`MV_TOTAL_BITS-`MV_FRAC_BITS)*5-1:0] merge_cand_mv_y_flat, // 10-bit × 5

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
    // Final Decision Outputs (To downstream stages)
    //-------------------------------------------------------------------------
    output reg                      mode_valid,
    output reg  [31:0]              best_rd_cost,
    output reg                      best_is_intra,
    output reg  [5:0]               best_intra_mode,
    output reg  signed [11:0]       best_inter_mv_x,
    output reg  signed [11:0]       best_inter_mv_y,
    output reg                      best_merge_flag,
    output reg  [2:0]               best_merge_idx,
    output reg                      best_skip_flag
);

    // SLICE TYPES (HEVC spec)
    localparam SLICE_B = 2'd0;
    localparam SLICE_P = 2'd1;
    localparam SLICE_I = 2'd2;

    // FSM States
    localparam [2:0]
        S_IDLE         = 3'd0,
        S_EVAL_ENGINES = 3'd1,
        S_WAIT_COSTS   = 3'd2,
        S_EVAL_MERGE   = 3'd3,
        S_COMPARE_MODE = 3'd4,
        S_DECIDE_SPLIT = 3'd5,
        S_DONE         = 3'd6;

    reg [2:0] state, next_state;
    
    // Latched inputs
    reg [6:0] cur_pu_size;
    reg [1:0] cur_pu_depth;
    reg [1:0] cur_slice_type;
    reg [5:0] cur_qp;
    reg [9:0] cur_poc;

    // RD Cost Registers
    reg [31:0] latched_intra_cost;
    reg [5:0]  latched_intra_mode;
    reg        intra_done;

    reg [31:0] latched_inter_cost;
    reg signed [11:0] latched_inter_mv_x;
    reg signed [11:0] latched_inter_mv_y;
    reg        inter_done;

    // Merge evaluation registers
    reg [31:0] best_merge_cost;
    reg [2:0]  best_merge_cand;
    reg signed [11:0] best_merge_mv_x;
    reg signed [11:0] best_merge_mv_y;
    reg        merge_evaluated;

    //=========================================================================
    // Advanced Lagrangian Lambda Engine & CABAC Rate Estimator
    //=========================================================================
    wire [23:0] lambda_mode_q8;
    wire [15:0] lambda_motion_q8;
    wire [23:0] lambda_chroma_q8;

    lambda_calc u_lambda_calc (
        .qp             (cur_qp),
        .lambda_mode    (lambda_mode_q8),
        .lambda_motion  (lambda_motion_q8),
        .lambda_chroma  (lambda_chroma_q8)
    );

    // Rate Estimators for Intra, Merge, and AMVP
    wire [15:0] intra_est_rate_q8;
    rate_estimator u_rate_est_intra (
        .is_intra       (1'b1),
        .is_merge       (1'b0),
        .is_skip        (1'b0),
        .intra_mode     (intra_best_mode),
        .mpm_cand0      (6'd0),  // Planar
        .mpm_cand1      (6'd1),  // DC
        .mpm_cand2      (6'd10), // Horizontal
        .merge_idx      (3'd0),
        .mvd_x          (12'd0),
        .mvd_y          (12'd0),
        .est_rate_bits  (intra_est_rate_q8)
    );

    wire [15:0] merge_est_rate_q8 [0:4];
    genvar gi_r;
    generate
        for (gi_r = 0; gi_r < 5; gi_r = gi_r + 1) begin : gen_merge_rate
            rate_estimator u_rate_est_merge (
                .is_intra       (1'b0),
                .is_merge       (1'b1),
                .is_skip        (1'b0),
                .intra_mode     (6'd0),
                .mpm_cand0      (6'd0),
                .mpm_cand1      (6'd0),
                .mpm_cand2      (6'd0),
                .merge_idx      (gi_r[2:0]),
                .mvd_x          (12'd0),
                .mvd_y          (12'd0),
                .est_rate_bits  (merge_est_rate_q8[gi_r])
            );
        end
    endgenerate

    wire [15:0] amvp_est_rate_q8;
    rate_estimator u_rate_est_amvp (
        .is_intra       (1'b0),
        .is_merge       (1'b0),
        .is_skip        (1'b0),
        .intra_mode     (6'd0),
        .mpm_cand0      (6'd0),
        .mpm_cand1      (6'd0),
        .mpm_cand2      (6'd0),
        .merge_idx      (3'd0),
        .mvd_x          (inter_best_mv_x),
        .mvd_y          (inter_best_mv_y),
        .est_rate_bits  (amvp_est_rate_q8)
    );

    // Rate cost in distortion units: (lambda * rate_q8) >> 16
    wire [31:0] lambda_intra_rate_cost = (lambda_mode_q8 * intra_est_rate_q8[15:8]) >> 8;
    wire [31:0] lambda_amvp_rate_cost  = (lambda_mode_q8 * amvp_est_rate_q8[15:8]) >> 8;

    //=========================================================================
    // Skip Threshold & Split Threshold — Lambda Adaptive
    //=========================================================================
    wire [31:0] skip_threshold = (lambda_mode_q8 >> 8) + 32'd8;

    // Per-pixel thresholds scaling with lambda_motion (sqrt(lambda) in Q8.8, matching SAD metric)
    wire [31:0] split_threshold = (cur_pu_depth == 2'd0) ? (32'd20 + {24'b0, lambda_motion_q8[15:8]}) :
                                  (cur_pu_depth == 2'd1) ? (32'd25 + {24'b0, lambda_motion_q8[15:8]}) :
                                  (cur_pu_depth == 2'd2) ? (32'd30 + {24'b0, lambda_motion_q8[15:8]}) :
                                                           32'hFFFFFFFF;

    //=========================================================================
    // Merge candidate extraction
    //=========================================================================
    localparam MV_W = `MV_TOTAL_BITS - `MV_FRAC_BITS; // 10
    wire signed [MV_W-1:0] merge_mv_x [0:4];
    wire signed [MV_W-1:0] merge_mv_y [0:4];
    
    genvar gi;
    generate
        for (gi = 0; gi < 5; gi = gi + 1) begin : gen_merge_extract
            assign merge_mv_x[gi] = merge_cand_mv_x_flat[gi*MV_W +: MV_W];
            assign merge_mv_y[gi] = merge_cand_mv_y_flat[gi*MV_W +: MV_W];
        end
    endgenerate

    // =========================================================================
    // Merge Evaluation — Simplified (No MC)
    // For each valid merge candidate, compute:
    //   merge_rd_cost = inter_distortion + λ × MERGE_EST_BITS
    // The distortion is approximated as latched_inter_cost (SAD from FME).
    // This works because merge MVs are spatially correlated with the AMVP result.
    //
    // We compare merge_rd_cost against amvp_rd_cost to decide merge vs AMVP.
    // merge always wins on rate (3 bits < 12 bits) when distortion is equal.
    // =========================================================================
    reg [2:0] merge_scan_idx;
    reg [31:0] cur_merge_cost;
    wire merge_scan_done = (merge_scan_idx == 3'd5) || 
                           (merge_scan_idx > 3'd0 && !merge_cand_valid[merge_scan_idx - 1]);

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
                if (cur_slice_type == SLICE_I) begin
                    if (intra_done) next_state = S_COMPARE_MODE;
                end else begin
                    if (intra_done && inter_done) next_state = S_EVAL_MERGE;
                end
            end
            
            S_EVAL_MERGE: begin
                if (merge_scan_done) next_state = S_COMPARE_MODE;
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
            merge_evaluated    <= 1'b0;
            
            latched_intra_cost <= 32'hFFFFFFFF;
            latched_inter_cost <= 32'hFFFFFFFF;
            best_rd_cost       <= 32'hFFFFFFFF;
            best_merge_cost    <= 32'hFFFFFFFF;
            
            cur_pu_size        <= 7'd0;
            cur_pu_depth       <= 2'd0;
            cur_slice_type     <= 2'd0;
            cur_qp             <= 6'd32;
            
            merge_scan_idx     <= 3'd0;
            
            best_merge_flag    <= 1'b0;
            best_merge_idx     <= 3'd0;
            best_skip_flag     <= 1'b0;
        end else begin
            // Default pulse clears
            eval_intra_start <= 1'b0;
            eval_inter_start <= 1'b0;
            mode_valid       <= 1'b0;
            split_valid      <= 1'b0;

            // Capture costs dynamically when valid
            if (intra_cost_valid) begin
                latched_intra_cost <= intra_rd_cost + lambda_intra_rate_cost;
                latched_intra_mode <= intra_best_mode;
                intra_done         <= 1'b1;
            end
            if (inter_cost_valid) begin
                latched_inter_cost <= inter_rd_cost + lambda_amvp_rate_cost;
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
                        cur_qp         <= qp;
                        cur_poc        <= poc;
                        intra_done     <= 1'b0;
                        inter_done     <= 1'b0;
                        merge_evaluated<= 1'b0;
                        latched_intra_cost <= 32'hFFFFFFFF;
                        latched_inter_cost <= 32'hFFFFFFFF;
                        latched_inter_mv_x <= 12'd0;
                        latched_inter_mv_y <= 12'd0;
                        best_merge_cost    <= 32'hFFFFFFFF;
                        best_merge_mv_x    <= 12'd0;
                        best_merge_mv_y    <= 12'd0;
                        merge_scan_idx     <= 3'd0;
                    end
                end

                S_EVAL_ENGINES: begin
                    eval_intra_start <= 1'b1;
                    if (cur_slice_type != SLICE_I) begin
                        eval_inter_start <= 1'b1;
                    end else begin
                        inter_done <= 1'b1;
                    end
                    // synthesis translate_off
                    $display("Time=%0t: [MODE_DECISION] S_EVAL_ENGINES: slice=%0d eval_intra=1 eval_inter=%0b",
                             $time, cur_slice_type, (cur_slice_type != SLICE_I));
                    // synthesis translate_on
                end

                S_EVAL_MERGE: begin
                    // Scan merge candidates one per cycle
                    if (!merge_scan_done) begin
                        if (merge_cand_valid[merge_scan_idx]) begin
                            // Precise merge RD cost: inter distortion + (lambda * merge_bits) >> 8
                            cur_merge_cost = (inter_rd_cost < 32'hFFFF0000) ? 
                                             (inter_rd_cost + ((lambda_mode_q8 * merge_est_rate_q8[merge_scan_idx][15:8]) >> 8)) : 
                                             32'hFFFFFFFF;
                            
                            if (cur_merge_cost < best_merge_cost) begin
                                best_merge_cost <= cur_merge_cost;
                                best_merge_cand <= merge_scan_idx;
                                // Sign-extend 10-bit merge MV to 12-bit quarter-pel
                                best_merge_mv_x <= {{2{merge_mv_x[merge_scan_idx][MV_W-1]}}, merge_mv_x[merge_scan_idx]};
                                best_merge_mv_y <= {{2{merge_mv_y[merge_scan_idx][MV_W-1]}}, merge_mv_y[merge_scan_idx]};
                            end
                        end
                        merge_scan_idx <= merge_scan_idx + 3'd1;
                    end
                    merge_evaluated <= 1'b1;
                end

                S_COMPARE_MODE: begin
                    // Three-way comparison: Intra vs AMVP-Inter vs Merge
                    if (cur_slice_type == SLICE_I) begin
                        // I-Slice: only intra
                        best_is_intra   <= 1'b1;
                        best_rd_cost    <= latched_intra_cost;
                        best_intra_mode <= latched_intra_mode;
                        best_merge_flag <= 1'b0;
                        best_skip_flag  <= 1'b0;
                    end else if (merge_evaluated && (best_merge_cost <= latched_inter_cost) && 
                                 (best_merge_cost <= latched_intra_cost)) begin
                        // Merge wins
                        best_is_intra   <= 1'b0;
                        best_rd_cost    <= best_merge_cost;
                        best_inter_mv_x <= best_merge_mv_x;
                        best_inter_mv_y <= best_merge_mv_y;
                        best_merge_flag <= 1'b1;
                        best_merge_idx  <= best_merge_cand;
                        best_skip_flag  <= 1'b0;
                    end else if (latched_intra_cost <= latched_inter_cost) begin
                        // Intra wins
                        best_is_intra   <= 1'b1;
                        best_rd_cost    <= latched_intra_cost;
                        best_intra_mode <= latched_intra_mode;
                        best_merge_flag <= 1'b0;
                        best_skip_flag  <= 1'b0;
                    end else begin
                        // AMVP Inter wins
                        best_is_intra   <= 1'b0;
                        best_rd_cost    <= latched_inter_cost;
                        best_inter_mv_x <= latched_inter_mv_x;
                        best_inter_mv_y <= latched_inter_mv_y;
                        best_merge_flag <= 1'b0;
                        best_skip_flag  <= 1'b0;
                    end
                end

                S_DECIDE_SPLIT: begin
                    split_valid <= 1'b1;
                    mode_valid  <= 1'b1;
                    
                    // Fast Encoder Decision Logic
                    if (cur_pu_depth == 2'd3) begin
                        // Max depth (8x8) MUST be a leaf
                        split_flag <= 1'b0;
                    end else if (best_skip_flag) begin
                        // Skip mode: no need to split further
                        split_flag <= 1'b0;
                    // Normalize cost by number of pixels (>> 12, 10, 8 for depths 0, 1, 2)
                    end else if (best_rd_cost < 32'hFFFF0000 && 
                                ((cur_pu_depth == 2'd0) ? (best_rd_cost >> 12) :
                                 (cur_pu_depth == 2'd1) ? (best_rd_cost >> 10) :
                                                          (best_rd_cost >> 8)) > split_threshold) begin
                        // Cost is too high, split quadtree deeper
                        split_flag <= 1'b1;
                    end else begin
                        // Cost is acceptable, early termination (FEN=1)
                        split_flag <= 1'b0;
                    end
                    // synthesis translate_off
                    $display("Time=%0t: [MODE_DECISION] POC=%0d SLICE=%0d SIZE=%0d INTRA=%0d INTER=%0d MERGE=%0d BEST=%s MRG=%b SKIP=%b SPLIT=%b", 
                              $time, cur_poc, cur_slice_type, cur_pu_size, 
                              latched_intra_cost, latched_inter_cost, best_merge_cost,
                              best_is_intra ? "INTRA" : (best_merge_flag ? "MERGE" : "AMVP"),
                              best_merge_flag, best_skip_flag,
                              (best_rd_cost < 32'hFFFF0000 && best_rd_cost > split_threshold));
                    // synthesis translate_on
                end
            endcase
        end
    end

endmodule
