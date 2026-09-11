//=============================================================================
// intra_prediction.v
// Intra Prediction — Top-Level Wrapper for Datapath Integration
//
// Integrates all intra sub-modules into a single block:
//   - intra_rmd          : Rough Mode Decision (SAD-based, 4 candidate modes)
//   - ref_sample_filter  : [1,2,1]/4 filter + strong intra smoothing
//   - intra_pred_top     : Mode dispatcher → planar / DC / angular
//     - intra_planar
//     - intra_dc
//     - intra_angular
//
// Datapath connections (from system diagram):
//
//   Mode Decision & RMD ──cu_info──► ┌─────────────────────┐
//                                    │                     │
//   Reconstruction Unit ──ref_sam──► │  intra_prediction   │──pred_pixel──► Pred Mux
//                                    │                     │
//   Input Buffer (orig) ──orig_rd──► │  (this module)      │──rmd_result─► Mode Decision
//                                    └─────────────────────┘
//
// Operating modes:
//   1. RMD phase: mode_decision asserts rmd_start.
//      intra_rmd reads original pixels via orig_rd bus, loads reference
//      samples, computes SAD for Planar/DC/Hor/Ver, returns best_mode/cost.
//
//   2. Prediction phase: mode_decision asserts pred_start with chosen
//      intra_mode. ref_sample_filter → intra_pred_top pipeline produces
//      predicted pixels streamed to pred_mux output.
//
//   Both phases share the same reference sample input port (ref_*).
//   An internal FSM arbitrates access between RMD and prediction.
//
//=============================================================================

`include "parameter_pkg.vh"
`include "hevc_interfaces.vh"

module intra_prediction (
    input  wire         clk,
    input  wire         rst_n,

    //=========================================================================
    // PORT A: CU Context (from mode_decision / ctu_partitioner)
    //=========================================================================
    input  wire [5:0]   cu_x,               // CU top-left x in CTU (0..63)
    input  wire [5:0]   cu_y,               // CU top-left y in CTU (0..63)
    input  wire [2:0]   pu_size_log2,       // 2=4×4, 3=8×8, 4=16×16, 5=32×32
    input  wire         is_luma,            // 1=luma, 0=chroma component

    //=========================================================================
    // PORT B: RMD Control (from/to mode_decision)
    //=========================================================================
    input  wire         rmd_start,          // Pulse: begin rough mode decision
    output wire         rmd_done,           // Pulse: RMD complete
    output wire [5:0]   rmd_best_mode,      // Best mode from RMD (0=Planar,1=DC,10=Hor,26=Ver)
    output wire [31:0]  rmd_best_cost,      // SAD cost of best mode

    //=========================================================================
    // PORT C: Prediction Control (from mode_decision)
    //=========================================================================
    input  wire         pred_start,         // Pulse: begin prediction with pred_intra_mode
    input  wire [5:0]   pred_intra_mode,    // Chosen intra mode (0..34)

    //=========================================================================
    // PORT D: Reference Samples (from reconstruction unit / neighbor buffer)
    //   Serial stream: ref[0]=corner, ref[1..2N]=top, ref[2N+1..4N]=left
    //   Directly connects to both RMD and prediction pipeline
    //=========================================================================
    input  wire                         ref_valid,
    output wire                         ref_ready,
    input  wire [`PIXEL_WIDTH-1:0]      ref_sample,
    input  wire [7:0]                   ref_idx,
    input  wire                         ref_last,

    //=========================================================================
    // PORT E: Original Pixel Read (for RMD SAD — from input/CTU buffer)
    //=========================================================================
    output wire [11:0]                  orig_rd_addr,
    output wire                         orig_rd_active,     // 1 when RMD is reading
    input  wire [`PIXEL_WIDTH-1:0]      orig_rd_data,       // 1-cycle read latency

    //=========================================================================
    // PORT F: Predicted Pixel Output (to pred_mux → residual computation)
    //   Row-major N×N pixel stream with valid/ready handshake
    //=========================================================================
    output wire                         pred_valid,
    input  wire                         pred_ready,
    output wire [`PIXEL_WIDTH-1:0]      pred_pixel,
    output wire [5:0]                   pred_x,             // Pixel x within PU
    output wire [5:0]                   pred_y,             // Pixel y within PU
    output wire                         pred_last           // Last pixel of PU
);

    //=========================================================================
    // Internal wires
    //=========================================================================
    wire        rmd_done_i;
    wire        pred_valid_i;
    wire        pred_last_i;
    wire        pred_ref_ready_i;

    //=========================================================================
    // Internal FSM — arbitrate between RMD and Prediction phases
    //=========================================================================
    localparam S_IDLE     = 2'd0;
    localparam S_RMD      = 2'd1;   // Rough mode decision active
    localparam S_PREDICT  = 2'd2;   // Prediction pipeline active

    reg [1:0] phase;
    reg [5:0] latched_mode;         // Mode latched on pred_start

    always @(posedge clk) begin
        if (!rst_n) begin
            phase        <= S_IDLE;
            latched_mode <= 6'd0;
        end else begin
            case (phase)
                S_IDLE: begin
                    if (rmd_start)
                        phase <= S_RMD;
                    else if (pred_start) begin
                        phase        <= S_PREDICT;
                        latched_mode <= pred_intra_mode;
                    end
                end

                S_RMD: begin
                    if (rmd_done_i)
                        phase <= S_IDLE;
                end

                S_PREDICT: begin
                    if (pred_last_i && pred_valid_i && pred_ready)
                        phase <= S_IDLE;
                end
            endcase
        end
    end

    //=========================================================================
    // Reference sample routing
    //   RMD phase:       ref_* → intra_rmd
    //   Prediction phase: ref_* → intra_pred_top (via ref_sample_filter)
    //=========================================================================
    wire ref_to_rmd  = (phase == S_RMD);
    wire ref_to_pred = (phase == S_PREDICT);

    // RMD reference port
    wire rmd_ref_valid = ref_valid && ref_to_rmd;
    // Prediction reference port
    wire pred_ref_valid = ref_valid && ref_to_pred;

    // Ready back-pressure: only active destination drives ready
    // rmd_ref_ready_i not used — RMD always accepts (no backpressure in S_LOAD_REF)

    assign ref_ready = ref_to_rmd  ? 1'b1 :            // RMD always accepts during load
                       ref_to_pred ? pred_ref_ready_i :
                       1'b0;

    //=========================================================================
    // Instantiation: intra_rmd
    //=========================================================================
    wire [5:0]  rmd_best_mode_i;
    wire [31:0] rmd_best_cost_i;

    wire [`PIXEL_WIDTH-1:0] pred_pixel_i;
    wire [5:0]  pred_x_i, pred_y_i;

    intra_rmd u_rmd (
        .clk            (clk),
        .rst_n          (rst_n),

        // Control
        .start          (rmd_start),
        .pu_x           (cu_x),
        .pu_y           (cu_y),
        .pu_size_log2   (pu_size_log2),

        // Original pixel read
        .orig_rd_addr   (orig_rd_addr),
        .rmd_active     (orig_rd_active),
        .orig_rd_data   (orig_rd_data),

        // Reference samples
        .ref_valid      (rmd_ref_valid),
        .ref_sample     (ref_sample),
        .ref_idx        (ref_idx),
        .ref_last       (ref_last),

        // Results
        .rmd_done       (rmd_done_i),
        .best_mode      (rmd_best_mode_i),
        .best_cost      (rmd_best_cost_i)
    );

    assign rmd_done      = rmd_done_i;
    assign rmd_best_mode = rmd_best_mode_i;
    assign rmd_best_cost = rmd_best_cost_i;

    //=========================================================================
    // Instantiation: intra_pred_top
    //   Contains ref_sample_filter + planar/dc/angular internally
    //=========================================================================
    intra_pred_top u_pred (
        .clk            (clk),
        .rst_n          (rst_n),

        // PU context
        .pu_size_log2   (pu_size_log2),
        .intra_mode     (latched_mode),
        .is_luma        (is_luma),

        // Reference samples (filtered internally by ref_sample_filter)
        .ref_valid      (pred_ref_valid),
        .ref_ready      (pred_ref_ready_i),
        .ref_sample     (ref_sample),
        .ref_idx        (ref_idx),
        .ref_last       (ref_last),

        // Predicted pixel output
        .out_valid      (pred_valid_i),
        .out_ready      (pred_ready),
        .out_pixel      (pred_pixel_i),
        .out_x          (pred_x_i),
        .out_y          (pred_y_i),
        .out_last       (pred_last_i)
    );

    //=========================================================================
    // Output assignments
    //   Prediction output only valid during S_PREDICT phase
    //=========================================================================
    assign pred_valid = pred_valid_i && (phase == S_PREDICT);
    assign pred_pixel = pred_pixel_i;
    assign pred_x     = pred_x_i;
    assign pred_y     = pred_y_i;
    assign pred_last  = pred_last_i;

    //=========================================================================
    // Simulation assertions
    //=========================================================================
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n) begin
            // Cannot start both RMD and prediction simultaneously
            if (rmd_start && pred_start)
                $display("ERROR [intra_prediction] rmd_start and pred_start asserted simultaneously at time=%0t", $time);

            // Cannot start when busy
            if ((phase != S_IDLE) && (rmd_start || pred_start))
                $display("WARN  [intra_prediction] start asserted while busy (phase=%0d) at time=%0t", phase, $time);

            // Mode range check
            if (pred_start && pred_intra_mode > 6'd34)
                $display("ERROR [intra_prediction] invalid pred_intra_mode=%0d at time=%0t", pred_intra_mode, $time);
        end
    end

    // Phase tracking
    always @(posedge clk) begin
        if (rst_n) begin
            if (rmd_start && phase == S_IDLE)
                $display("INFO  [intra_prediction] RMD started cu=(%0d,%0d) size_log2=%0d at time=%0t",
                         cu_x, cu_y, pu_size_log2, $time);
            if (rmd_done_i)
                $display("INFO  [intra_prediction] RMD done best_mode=%0d best_cost=%0d at time=%0t",
                         rmd_best_mode_i, rmd_best_cost_i, $time);
            if (pred_start && phase == S_IDLE)
                $display("INFO  [intra_prediction] Prediction started mode=%0d at time=%0t",
                         pred_intra_mode, $time);
            if (pred_last_i && pred_valid_i && pred_ready && phase == S_PREDICT)
                $display("INFO  [intra_prediction] Prediction done at time=%0t", $time);
        end
    end
    // synthesis translate_on

endmodule
