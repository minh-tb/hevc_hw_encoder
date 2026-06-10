//=============================================================================
// intra_pred_top.v
// Intra Prediction Dispatcher
//
// Mapped from HM source:
//   TLibCommon/TComPrediction.cpp
//   Void TComPrediction::predIntraAng()
//
// HM routing logic (predIntraAng):
//   if (uiDirMode == PLANAR_IDX)   → xPredIntraPlanar()
//   else if (uiDirMode == DC_IDX)  → xPredIntraDc()
//   else                           → xPredIntraAng()
//
// Architecture:
//   1. ref_sample_filter runs first — always, for all modes
//   2. Filtered ref samples broadcast to all three predictors simultaneously
//   3. Only one predictor is active (in_valid gated by mode select)
//   4. Output muxed from whichever predictor has out_valid asserted
//
// Modes:
//   INTRA_PLANAR = 0   → intra_planar
//   INTRA_DC     = 1   → intra_dc
//   INTRA_ANG   2..34  → intra_angular
//
// Config:
//   AMP_ENABLE = 1 — asymmetric PUs possible but all use same 35 modes
//   Chroma modes: DM (= luma mode), Planar, DC, Vertical, Horizontal, Diagonal
//                 chroma always valid subset of luma modes — same modules used
//
// Pipeline:
//   ref_sample_filter → [planar | dc | angular] → output mux
//   Latency dominated by predictor stage (N² cycles for N×N block)
//=============================================================================

`include "parameter_pkg.vh"
`include "hevc_interfaces.vh"

module intra_pred_top (
    input  wire         clk,
    input  wire         rst_n,

    // PU context (from CU_INFO_BUS)
    input  wire [2:0]   pu_size_log2,       // 2=4×4 .. 5=32×32
    input  wire [5:0]   intra_mode,         // 0=Planar, 1=DC, 2..34=Angular
    input  wire         is_luma,            // 1=luma, 0=chroma

    // Raw reference samples input (from CTU neighbor buffer)
    // ref[0..4N]: corner + top row + left col
    input  wire         ref_valid,
    output wire         ref_ready,
    input  wire [`PIXEL_WIDTH-1:0] ref_sample,
    input  wire [7:0]   ref_idx,            // 0..4N
    input  wire         ref_last,

    // Predicted pixel output (row-major, N×N)
    output wire         out_valid,
    input  wire         out_ready,
    output wire [`PIXEL_WIDTH-1:0] out_pixel,
    output wire [5:0]   out_x,
    output wire [5:0]   out_y,
    output wire         out_last
);

    //-------------------------------------------------------------------------
    // Mode decode
    //-------------------------------------------------------------------------
    wire sel_planar = (intra_mode == `INTRA_PLANAR);
    wire sel_dc     = (intra_mode == `INTRA_DC);
    wire sel_ang    = (intra_mode >= `INTRA_ANG_FIRST) &&
                      (intra_mode <= `INTRA_ANG_LAST);

    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && ref_valid && !sel_planar && !sel_dc && !sel_ang)
            $display("ERROR [intra_pred_top] invalid intra_mode=%0d at time=%0t",
                     intra_mode, $time);
    end
    // synthesis translate_on

    //-------------------------------------------------------------------------
    // Stage 1: ref_sample_filter
    // Always runs first regardless of mode
    // Filtered output broadcast to all predictors
    //-------------------------------------------------------------------------
    wire                    filt_valid;
    wire                    filt_ready;
    wire [`PIXEL_WIDTH-1:0] filt_sample;
    wire [7:0]              filt_idx;
    wire                    filt_last;

    // filt_ready: whichever predictor is selected drives ready
    // Only one predictor accepts at a time

    ref_sample_filter u_ref_filter (
        .clk            (clk),
        .rst_n          (rst_n),
        .pu_size_log2   (pu_size_log2),
        .intra_mode     (intra_mode),
        .is_luma        (is_luma),
        .in_valid       (ref_valid),
        .in_ready       (ref_ready),
        .in_sample      (ref_sample),
        .in_idx         (ref_idx),
        .in_last        (ref_last),
        .out_valid      (filt_valid),
        .out_ready      (filt_ready),
        .out_sample     (filt_sample),
        .out_idx        (filt_idx),
        .out_last       (filt_last)
    );

    //-------------------------------------------------------------------------
    // Stage 2: Predictor instances
    // filt_valid gated per predictor — only active one receives samples
    //-------------------------------------------------------------------------
    wire filt_valid_planar = filt_valid && sel_planar;
    wire filt_valid_dc     = filt_valid && sel_dc;
    wire filt_valid_ang    = filt_valid && sel_ang;

    wire filt_ready_planar, filt_ready_dc, filt_ready_ang;

    // filt_ready is OR of active predictor's ready
    // Only one will be active at a time — no arbitration needed
    assign filt_ready = (sel_planar ? filt_ready_planar :
                         sel_dc     ? filt_ready_dc     :
                         sel_ang    ? filt_ready_ang    :
                         1'b0);

    //----------------------------------------------------------------------
    // Planar predictor
    //----------------------------------------------------------------------
    wire                    out_valid_planar;
    wire [`PIXEL_WIDTH-1:0] out_pixel_planar;
    wire [5:0]              out_x_planar, out_y_planar;
    wire                    out_last_planar;

    intra_planar u_planar (
        .clk            (clk),
        .rst_n          (rst_n),
        .pu_size_log2   (pu_size_log2),
        .in_valid       (filt_valid_planar),
        .in_ready       (filt_ready_planar),
        .in_sample      (filt_sample),
        .in_idx         (filt_idx),
        .in_last        (filt_last),
        .out_valid      (out_valid_planar),
        .out_ready      (out_ready),
        .out_pixel      (out_pixel_planar),
        .out_x          (out_x_planar),
        .out_y          (out_y_planar),
        .out_last       (out_last_planar)
    );

    //----------------------------------------------------------------------
    // DC predictor
    //----------------------------------------------------------------------
    wire                    out_valid_dc;
    wire [`PIXEL_WIDTH-1:0] out_pixel_dc;
    wire [5:0]              out_x_dc, out_y_dc;
    wire                    out_last_dc;

    intra_dc u_dc (
        .clk            (clk),
        .rst_n          (rst_n),
        .pu_size_log2   (pu_size_log2),
        .is_luma        (is_luma),
        .in_valid       (filt_valid_dc),
        .in_ready       (filt_ready_dc),
        .in_sample      (filt_sample),
        .in_idx         (filt_idx),
        .in_last        (filt_last),
        .out_valid      (out_valid_dc),
        .out_ready      (out_ready),
        .out_pixel      (out_pixel_dc),
        .out_x          (out_x_dc),
        .out_y          (out_y_dc),
        .out_last       (out_last_dc)
    );

    //----------------------------------------------------------------------
    // Angular predictor
    //----------------------------------------------------------------------
    wire                    out_valid_ang;
    wire [`PIXEL_WIDTH-1:0] out_pixel_ang;
    wire [5:0]              out_x_ang, out_y_ang;
    wire                    out_last_ang;

    intra_angular u_angular (
        .clk            (clk),
        .rst_n          (rst_n),
        .pu_size_log2   (pu_size_log2),
        .intra_mode     (intra_mode),
        .is_luma        (is_luma),
        .in_valid       (filt_valid_ang),
        .in_ready       (filt_ready_ang),
        .in_sample      (filt_sample),
        .in_idx         (filt_idx),
        .in_last        (filt_last),
        .out_valid      (out_valid_ang),
        .out_ready      (out_ready),
        .out_pixel      (out_pixel_ang),
        .out_x          (out_x_ang),
        .out_y          (out_y_ang),
        .out_last       (out_last_ang)
    );

    //-------------------------------------------------------------------------
    // Output mux — only one predictor asserts out_valid at a time
    //-------------------------------------------------------------------------
    assign out_valid = out_valid_planar | out_valid_dc | out_valid_ang;

    assign out_pixel = out_valid_planar ? out_pixel_planar :
                       out_valid_dc     ? out_pixel_dc     :
                       out_valid_ang    ? out_pixel_ang    :
                       {`PIXEL_WIDTH{1'b0}};

    assign out_x     = out_valid_planar ? out_x_planar :
                       out_valid_dc     ? out_x_dc     :
                       out_valid_ang    ? out_x_ang    :
                       6'd0;

    assign out_y     = out_valid_planar ? out_y_planar :
                       out_valid_dc     ? out_y_dc     :
                       out_valid_ang    ? out_y_ang    :
                       6'd0;

    assign out_last  = out_valid_planar ? out_last_planar :
                       out_valid_dc     ? out_last_dc     :
                       out_valid_ang    ? out_last_ang    :
                       1'b0;

    //-------------------------------------------------------------------------
    // Simulation: warn if multiple out_valid asserted simultaneously
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n) begin
            if ((out_valid_planar + out_valid_dc + out_valid_ang) > 1)
                $display("ERROR [intra_pred_top] multiple predictors active at time=%0t",
                         $time);
        end
    end
    // synthesis translate_on

endmodule