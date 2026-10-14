//=============================================================================
// mc_unit.v
// Motion Compensation Unit — applies MV + interpolation to generate pred block
//
// Mapped from HM source:
//   TLibCommon/TComPrediction.cpp :: xPredInterUni()
//   TLibCommon/TComPrediction.cpp :: xPredInterBlk()
//   TLibCommon/TComPrediction.cpp :: getMvRange() / checkBiWeights()
//
// HM algorithm (one CU, uni-prediction, Main10):
//
//   void TComPrediction::xPredInterBlk(ComponentID compID,
//                                       TComDataCU* cu, TComPicYuv* refPic,
//                                       TComMv* mv, TComYuv* dstPic) {
//     1. Decompose MV into integer + fractional parts
//     Int xFrac = mv->getHor() & 3;     // luma: 2-bit, 1/4-pel
//     Int yFrac = mv->getVer() & 3;
//     Int refOffset = cu_x + (mv->getHor() >> 2);   // integer-pel ref position
//
//     2. Fetch reference block with border extension for filter taps
//     Pel* refPtr = refPic->getAddr(compID) + refOffset - filterTaps/2*stride;
//
//     3. Apply interpolation filter (8-tap luma, 4-tap chroma)
//     m_if.filterHor(compID, refPtr, stride, tmpBuf, BLK_SIZE, xFrac, !yFrac, bitDepth);
//     if (yFrac) m_if.filterVer(compID, tmpBuf, BLK_SIZE, dstBuf, BLK_SIZE, yFrac, true, bitDepth);
//   }
//
// Chroma MV derivation (HEVC 8.5.3.3.3, 4:2:0):
//   For 4:2:0, mvCLX = mvLX. The 1/4 luma-pel resolution intrinsically equals 1/8 chroma-pel resolution.
//   Therefore, the numerical value is identical and does not require shifting.
//   chroma_int_x  = cu_x/2 + mvLX[0] >> 3
//   chroma_frac_x = mvLX[0] & 7              (3-bit, 0..7, selects chroma filter row)
//
// Hardware FSM — sequential luma → Cb → Cr processing:
//
//   IDLE       wait for mc_start
//   FETCH_Y    request luma extended ref block from ref_frame_buffer
//   WAIT_Y     wait for luma ref data (variable latency)
//   FILT_Y     luma filter pipeline running (3 cycles, counted)
//   FETCH_CB   request Cb extended ref block
//   WAIT_CB    wait for Cb ref data
//   FILT_CB    Cb filter pipeline (3 cycles)
//   FETCH_CR   request Cr extended ref block
//   WAIT_CR    wait for Cr ref data
//   FILT_CR    Cr filter pipeline (3 cycles)
//   DONE       all three predicted blocks ready, assert mc_done
//
//   Total per CU (ideal, 1-cycle ref latency, 3-cycle filter):
//     (1+1+3) × 3 = 15 cycles luma+Cb+Cr
//
// Reference block fetch interface:
//   The ref_frame_buffer provides a rectangular region given top-left (x,y)
//   and a packed flat pixel array including border extension.
//   Border: 3 luma pixels (8-tap), 1 chroma pixel (4-tap)
//
// Block sizes (fixed for this implementation, parameterizable):
//   Luma:   BLK_SIZE × BLK_SIZE   = 4×4
//   Chroma: BLK_SIZE/2 × BLK_SIZE/2 = 2×2  (4:2:0)
//   Luma extended:   (BLK_SIZE+7) × (BLK_SIZE+7) = 11×11
//   Chroma extended: (BLK_SIZE/2+3) × (BLK_SIZE/2+3) = 5×5
//
// MV input format: signed integer, in 1/4-luma-pel units (quarter-pel)
//   e.g. MV_QP_W = 14 covers ±2048 integer-pel search range
//=============================================================================

`include "parameter_pkg.vh"

module mc_unit #(
    parameter PIXEL_WIDTH  = `PIXEL_WIDTH,   // 10
    parameter BLK_SIZE     = 4,              // luma block size (NxN)
    parameter MV_QP_W      = `MV_TOTAL_BITS,            // MV width in quarter-luma-pel units (signed)
    parameter CU_COORD_W   = `FRAME_DIM_WIDTH,            // frame coordinate width

    // Derived
    parameter BLK_C        = BLK_SIZE / 2,          // chroma block size (2 for 4:2:0)
    parameter BLK_EXT_Y    = BLK_SIZE + 7,          // luma extended  (11 for BLK_SIZE=4)
    parameter BLK_EXT_C    = BLK_C + 3,             // chroma extended (5  for BLK_C=2)
    parameter PX_Y         = PIXEL_WIDTH * BLK_SIZE * BLK_SIZE,       // luma flat bits
    parameter PX_C         = PIXEL_WIDTH * BLK_C   * BLK_C,           // chroma flat bits
    parameter PX_EXT_Y     = PIXEL_WIDTH * BLK_EXT_Y * BLK_EXT_Y,    // luma ext flat
    parameter PX_EXT_C     = PIXEL_WIDTH * BLK_EXT_C * BLK_EXT_C     // chroma ext flat
)(
    input  wire clk,
    input  wire rst_n,

    // MC request
    input  wire                        mc_start,
    output reg                         mc_ready,
    input  wire [2:0]                  mc_ref_slot,    // DPB slot of reference frame
    input  wire [CU_COORD_W-1:0]       mc_cu_x,        // CU top-left x (luma pixel)
    input  wire [CU_COORD_W-1:0]       mc_cu_y,        // CU top-left y (luma pixel)
    input  wire signed [MV_QP_W-1:0]  mc_mv_x,        // MV horizontal (quarter-luma-pel)
    input  wire signed [MV_QP_W-1:0]  mc_mv_y,        // MV vertical   (quarter-luma-pel)

    // Reference block fetch port — to ref_frame_buffer / DPB
    output reg                         ref_req_valid,
    output reg  [1:0]                  ref_req_comp,   // 0=Y, 1=Cb, 2=Cr
    output reg  [2:0]                  ref_req_slot,
    output reg  signed [CU_COORD_W-1:0]       ref_req_x,      // top-left of extended region
    output reg  signed [CU_COORD_W-1:0]       ref_req_y,
    input  wire                        ref_req_ready,
    input  wire                        ref_resp_valid,
    // Multiplexed response: luma or chroma extended block
    // Caller packs max(PX_EXT_Y, PX_EXT_C) and module uses appropriate slice
    input  wire [PX_EXT_Y-1:0]        ref_resp_y_flat,   // luma extended pixels
    input  wire [PX_EXT_C-1:0]        ref_resp_cb_flat,  // Cb extended pixels
    input  wire [PX_EXT_C-1:0]        ref_resp_cr_flat,  // Cr extended pixels

    // MC result
    output reg                         mc_done,
    output reg  [PX_Y-1:0]            pred_y_flat,    // predicted luma block
    output reg  [PX_C-1:0]            pred_cb_flat,   // predicted Cb block
    output reg  [PX_C-1:0]            pred_cr_flat    // predicted Cr block
);

    // =========================================================================
    // FSM encoding
    // =========================================================================
    localparam [3:0]
        S_IDLE     = 4'd0,
        S_FETCH_Y  = 4'd1,
        S_WAIT_Y   = 4'd2,
        S_FILT_Y   = 4'd3,
        S_FETCH_CB = 4'd4,
        S_WAIT_CB  = 4'd5,
        S_FILT_CB  = 4'd6,
        S_FETCH_CR = 4'd7,
        S_WAIT_CR  = 4'd8,
        S_FILT_CR  = 4'd9,
        S_DONE     = 4'd10;

    reg [3:0] state;

    // =========================================================================
    // Latched MV and position registers
    // =========================================================================
    reg [2:0]                  slot_r;
    reg [CU_COORD_W-1:0]       cu_x_r, cu_y_r;
    reg signed [MV_QP_W-1:0]  mv_x_r, mv_y_r;

    // =========================================================================
    // MV decomposition (combinational from latched values)
    //
    // Luma (quarter-pel):
    //   int_x  = mv_x >>> 2   (arithmetic shift, integer luma pixel offset)
    //   frac_x = mv_x[1:0]   (0..3, selects luma H-filter row)
    //
    // Chroma (eighth-chroma-pel, HEVC 8.5.3.3.3 for 4:2:0):
    //   cMV_x  = mv_x >>> 1   (arithmetic → eighth-chroma-pels)
    //   c_int_x  = cMV_x >>> 2 = mv_x >>> 3
    //   c_frac_x = cMV_x & 7  = (mv_x >>> 1) & 7
    // =========================================================================
    wire signed [CU_COORD_W-1:0] y_int_x  = $signed({1'b0, cu_x_r}) + (mv_x_r >>> 2);
    wire signed [CU_COORD_W-1:0] y_int_y  = $signed({1'b0, cu_y_r}) + (mv_y_r >>> 2);
    wire [1:0]  y_frac_x = mv_x_r[1:0];   // luma: 2-bit fractional (0..3)
    wire [1:0]  y_frac_y = mv_y_r[1:0];

    wire signed [CU_COORD_W-1:0] c_int_x  = $signed({1'b0, cu_x_r[CU_COORD_W-1:1]})
                                           + (mv_x_r >>> 3);
    wire signed [CU_COORD_W-1:0] c_int_y  = $signed({1'b0, cu_y_r[CU_COORD_W-1:1]})
                                           + (mv_y_r >>> 3);
    wire [2:0]  c_frac_x = mv_x_r[2:0];  // chroma: 3-bit (0..7)
    wire [2:0]  c_frac_y = mv_y_r[2:0];

    // Extended block top-left (subtract filter border)
    wire signed [CU_COORD_W-1:0] y_fetch_x = y_int_x - $signed({{(CU_COORD_W-2){1'b0}}, 2'd3});
    wire signed [CU_COORD_W-1:0] y_fetch_y = y_int_y - $signed({{(CU_COORD_W-2){1'b0}}, 2'd3});
    wire signed [CU_COORD_W-1:0] c_fetch_x = c_int_x - $signed({{(CU_COORD_W-1){1'b0}}, 1'd1});
    wire signed [CU_COORD_W-1:0] c_fetch_y = c_int_y - $signed({{(CU_COORD_W-1){1'b0}}, 1'd1});

    // =========================================================================
    // Luma filter instance (hpel_filter_luma)
    // Outputs H, V, HV simultaneously; mc_unit selects correct output
    // =========================================================================
    reg                 y_filt_valid_in;
    reg  [PX_EXT_Y-1:0] y_filt_ref;
    wire                y_filt_valid_out;
    wire [PX_Y-1:0]     y_h_out, y_v_out, y_hv_out;

    hpel_filter_luma #(.PIXEL_WIDTH(PIXEL_WIDTH), .BLK_SIZE(BLK_SIZE)) u_filt_y (
        .clk         (clk),
        .rst_n       (rst_n),
        .valid_in    (y_filt_valid_in),
        .frac_x      (y_frac_x),
        .frac_y      (y_frac_y),
        .ref_ext_flat(y_filt_ref),
        .valid_out   (y_filt_valid_out),
        .h_out_flat  (y_h_out),
        .v_out_flat  (y_v_out),
        .hv_out_flat (y_hv_out)
    );

    // =========================================================================
    // Chroma Cb filter instance (hpel_filter_chroma)
    // =========================================================================
    reg                 cb_filt_valid_in;
    reg  [PX_EXT_C-1:0] cb_filt_ref;
    wire                cb_filt_valid_out;
    wire [PX_C-1:0]     cb_h_out, cb_v_out, cb_hv_out;

    hpel_filter_chroma #(.PIXEL_WIDTH(PIXEL_WIDTH), .BLK_SIZE(BLK_C)) u_filt_cb (
        .clk         (clk),
        .rst_n       (rst_n),
        .valid_in    (cb_filt_valid_in),
        .frac_x      (c_frac_x),
        .frac_y      (c_frac_y),
        .ref_ext_flat(cb_filt_ref),
        .valid_out   (cb_filt_valid_out),
        .h_out_flat  (cb_h_out),
        .v_out_flat  (cb_v_out),
        .hv_out_flat (cb_hv_out)
    );

    // =========================================================================
    // Chroma Cr filter instance
    // =========================================================================
    reg                 cr_filt_valid_in;
    reg  [PX_EXT_C-1:0] cr_filt_ref;
    wire                cr_filt_valid_out;
    wire [PX_C-1:0]     cr_h_out, cr_v_out, cr_hv_out;

    hpel_filter_chroma #(.PIXEL_WIDTH(PIXEL_WIDTH), .BLK_SIZE(BLK_C)) u_filt_cr (
        .clk         (clk),
        .rst_n       (rst_n),
        .valid_in    (cr_filt_valid_in),
        .frac_x      (c_frac_x),
        .frac_y      (c_frac_y),
        .ref_ext_flat(cr_filt_ref),
        .valid_out   (cr_filt_valid_out),
        .h_out_flat  (cr_h_out),
        .v_out_flat  (cr_v_out),
        .hv_out_flat (cr_hv_out)
    );

    // =========================================================================
    // Filter output selection (MUX: integer / H / V / HV)
    // HM logic: if xFrac==0 && yFrac==0 → copy; xFrac!=0 && yFrac==0 → H only;
    //            xFrac==0 && yFrac!=0 → V only; both!=0 → HV
    // =========================================================================
    wire y_is_int = (y_frac_x == 2'd0) && (y_frac_y == 2'd0);
    wire y_is_h   = (y_frac_x != 2'd0) && (y_frac_y == 2'd0);
    wire y_is_v   = (y_frac_x == 2'd0) && (y_frac_y != 2'd0);

    wire c_is_int = (c_frac_x == 3'd0) && (c_frac_y == 3'd0);
    wire c_is_h   = (c_frac_x != 3'd0) && (c_frac_y == 3'd0);
    wire c_is_v   = (c_frac_x == 3'd0) && (c_frac_y != 3'd0);

    // Integer-pel luma copy (center pixel of extended block, no filter needed)
    // For integer MV, just extract the BLK_SIZE×BLK_SIZE center from the extended block
    // Center offset: row 3..6, col 3..6 within 11×11 extended block (BLK_SIZE=4)
    wire [PX_Y-1:0] y_int_out;
    genvar gi, gj;
    generate
        for (gi = 0; gi < BLK_SIZE; gi = gi + 1) begin : int_row_y
            for (gj = 0; gj < BLK_SIZE; gj = gj + 1) begin : int_col_y
                assign y_int_out[PIXEL_WIDTH*(BLK_SIZE*gi+gj) +: PIXEL_WIDTH] =
                    y_filt_ref[PIXEL_WIDTH*(BLK_EXT_Y*(gi+3) + (gj+3)) +: PIXEL_WIDTH];
            end
        end
    endgenerate

    wire [PX_C-1:0] cb_int_out, cr_int_out;
    generate
        for (gi = 0; gi < BLK_C; gi = gi + 1) begin : int_row_c
            for (gj = 0; gj < BLK_C; gj = gj + 1) begin : int_col_c
                assign cb_int_out[PIXEL_WIDTH*(BLK_C*gi+gj) +: PIXEL_WIDTH] =
                    cb_filt_ref[PIXEL_WIDTH*(BLK_EXT_C*(gi+1) + (gj+1)) +: PIXEL_WIDTH];
                assign cr_int_out[PIXEL_WIDTH*(BLK_C*gi+gj) +: PIXEL_WIDTH] =
                    cr_filt_ref[PIXEL_WIDTH*(BLK_EXT_C*(gi+1) + (gj+1)) +: PIXEL_WIDTH];
            end
        end
    endgenerate

    // =========================================================================
    // Main FSM
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= S_IDLE;
            mc_ready          <= 1'b1;
            mc_done           <= 1'b0;
            ref_req_valid     <= 1'b0;
            y_filt_valid_in   <= 1'b0;
            cb_filt_valid_in  <= 1'b0;
            cr_filt_valid_in  <= 1'b0;
        end else begin
            // Default pulse outputs
            ref_req_valid    <= 1'b0;
            y_filt_valid_in  <= 1'b0;
            cb_filt_valid_in <= 1'b0;
            cr_filt_valid_in <= 1'b0;
            mc_done          <= 1'b0;

            case (state)

            // ---------------------------------------------------------------
            S_IDLE: begin
                mc_ready <= 1'b1;
                if (mc_start) begin
                    mc_ready  <= 1'b0;
                    // Latch inputs
                    slot_r  <= mc_ref_slot;
                    cu_x_r  <= mc_cu_x;
                    cu_y_r  <= mc_cu_y;
                    mv_x_r  <= mc_mv_x;
                    mv_y_r  <= mc_mv_y;
                    state   <= S_FETCH_Y;
                end
            end

            // ---------------------------------------------------------------
            // LUMA FETCH + FILTER
            // ---------------------------------------------------------------
            S_FETCH_Y: begin
                // HM: refPtr = refPic->getAddr(Y) + (int_y-3)*stride + (int_x-3)
                ref_req_valid <= 1'b1;
                ref_req_comp  <= 2'd0;           // Y component
                ref_req_slot  <= slot_r;
                ref_req_x     <= y_fetch_x[CU_COORD_W-1:0];
                ref_req_y     <= y_fetch_y[CU_COORD_W-1:0];
                if (ref_req_valid && ref_req_ready) begin
                    ref_req_valid <= 1'b0;
                    state <= S_WAIT_Y;
                end
            end

            S_WAIT_Y: begin
                ref_req_valid <= 1'b0;
                if (ref_resp_valid) begin
                    y_filt_ref      <= ref_resp_y_flat;   // latch extended ref
                    $display("Time=%0t: [mc_unit] Y response ref_resp_y_flat=%0h", $time, ref_resp_y_flat);
                    y_filt_valid_in <= 1'b1;              // start filter pipeline
                    state           <= S_FILT_Y;
                end
            end

            S_FILT_Y: begin
                y_filt_valid_in <= 1'b0;
                // Wait 3 cycles for hpel_filter_luma pipeline
                // (valid_out fires on cycle 3 after valid_in)
                if (y_filt_valid_out) begin
                    // Select predicted luma pixels based on MV fraction
                    // HM xPredInterBlk selects H/V/HV output
                    if (y_is_int)
                        pred_y_flat <= y_int_out;
                    else if (y_is_h)
                        pred_y_flat <= y_h_out;
                    else if (y_is_v)
                        pred_y_flat <= y_v_out;
                    else
                        pred_y_flat <= y_hv_out;
                    state <= S_FETCH_CB;
                end
            end

            // ---------------------------------------------------------------
            // Cb FETCH + FILTER
            // ---------------------------------------------------------------
            S_FETCH_CB: begin
                ref_req_valid <= 1'b1;
                ref_req_comp  <= 2'd1;           // Cb component
                ref_req_slot  <= slot_r;
                ref_req_x     <= c_fetch_x[CU_COORD_W-1:0];
                ref_req_y     <= c_fetch_y[CU_COORD_W-1:0];
                if (ref_req_valid && ref_req_ready) begin
                    ref_req_valid <= 1'b0;
                    state <= S_WAIT_CB;
                end
            end

            S_WAIT_CB: begin
                ref_req_valid <= 1'b0;
                if (ref_resp_valid) begin
                    cb_filt_ref      <= ref_resp_cb_flat;
                    $display("Time=%0t: [mc_unit] Cb response ref_resp_cb_flat=%0h", $time, ref_resp_cb_flat);
                    cb_filt_valid_in <= 1'b1;
                    state            <= S_FILT_CB;
                end
            end

            S_FILT_CB: begin
                cb_filt_valid_in <= 1'b0;
                if (cb_filt_valid_out) begin
                    if (c_is_int)      pred_cb_flat <= cb_int_out;
                    else if (c_is_h)   pred_cb_flat <= cb_h_out;
                    else if (c_is_v)   pred_cb_flat <= cb_v_out;
                    else               pred_cb_flat <= cb_hv_out;
                    state <= S_FETCH_CR;
                end
            end

            // ---------------------------------------------------------------
            // Cr FETCH + FILTER
            // ---------------------------------------------------------------
            S_FETCH_CR: begin
                ref_req_valid <= 1'b1;
                ref_req_comp  <= 2'd2;           // Cr component
                ref_req_slot  <= slot_r;
                ref_req_x     <= c_fetch_x[CU_COORD_W-1:0];
                ref_req_y     <= c_fetch_y[CU_COORD_W-1:0];
                if (ref_req_valid && ref_req_ready) begin
                    ref_req_valid <= 1'b0;
                    state <= S_WAIT_CR;
                end
            end

            S_WAIT_CR: begin
                ref_req_valid <= 1'b0;
                if (ref_resp_valid) begin
                    cr_filt_ref      <= ref_resp_cr_flat;
                    $display("Time=%0t: [mc_unit] Cr response ref_resp_cr_flat=%0h", $time, ref_resp_cr_flat);
                    cr_filt_valid_in <= 1'b1;
                    state            <= S_FILT_CR;
                end
            end

            S_FILT_CR: begin
                cr_filt_valid_in <= 1'b0;
                if (cr_filt_valid_out) begin
                    if (c_is_int)      pred_cr_flat <= cr_int_out;
                    else if (c_is_h)   pred_cr_flat <= cr_h_out;
                    else if (c_is_v)   pred_cr_flat <= cr_v_out;
                    else               pred_cr_flat <= cr_hv_out;
                    state <= S_DONE;
                end
            end

            // ---------------------------------------------------------------
            // DONE — all three components ready
            // HM: predicted block stored; encoder computes residual next
            // ---------------------------------------------------------------
            S_DONE: begin
                mc_done  <= 1'b1;
                mc_ready <= 1'b1;
                $display("Time=%0t: [mc_unit] DONE pred_y=%0h pred_cb=%0h pred_cr=%0h",
                         $time, pred_y_flat, pred_cb_flat, pred_cr_flat);
                state    <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Simulation assertions
    // =========================================================================
    // synthesis translate_off
    always @(posedge clk) begin
        if (mc_done) begin
            // $display("INFO [mc_unit] MC done: mv=(%0d,%0d) qpel → int=(%0d,%0d) luma_frac=(%0d,%0d) chroma_frac=(%0d,%0d)", 
            //          $signed(mv_x_r), $signed(mv_y_r),
            //          $signed(y_int_x), $signed(y_int_y),
            //          y_frac_x, y_frac_y,
            //          c_frac_x, c_frac_y);
        end
        // Warn on extreme MVs (beyond ±512 integer pixels)
        if (mc_start) begin
            // if (mc_mv_x > $signed(14'sd2048) || mc_mv_x < -$signed(14'sd2048))
                // $display("WARN [mc_unit] mv_x=%0d exceeds ±512 integer-pel range",
                //          $signed(mc_mv_x));
            // if (mc_mv_y > $signed(14'sd2048) || mc_mv_y < -$signed(14'sd2048))
                // $display("WARN [mc_unit] mv_y=%0d exceeds ±512 integer-pel range",
                //          $signed(mc_mv_y));
        end
    end
    // synthesis translate_on

endmodule