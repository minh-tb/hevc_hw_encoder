//=============================================================================
// inv_quant.v
// Inverse Quantization Unit
//
// Mapped from HM source:
//   TLibCommon/TComTrQuant.cpp  xDeQuant()
//
// HEVC inverse quantization formula (HM xDeQuant, ScalingList=OFF):
//   coeff = Clip3(CoeffMin, CoeffMax,
//             (level * g_invQuantScales[QP%6] * (1 << (QP/6))) >> rightShift)
//   where:
//     g_invQuantScales[QP%6] (HM TComTrQuant.cpp):
//       QP%6:  0     1     2     3     4     5
//       IQ:   40    45    51    57    64    72
//     rightShift = IQUANT_SHIFT - QP/6
//               = 6 - QP/6
//       BUT when QP/6 >= 6 (QP >= 36), shift becomes negative
//       → left shift instead: leftShift = QP/6 - 6
//     For 10-bit:
//       rightShift += (bitDepthAdjust = 2)
//       i.e. rightShift = 6 + bitDepthAdjust - QP/6 = 8 - QP/6
//
//     HM handles left/right shift cases:
//       if (rightShift > 0):
//         add = 1 << (rightShift-1)   (round half-up)
//         coeff = (level * IQ_scale + add) >> rightShift
//       else (leftShift >= 0):
//         coeff = (level * IQ_scale) << leftShift
//
// g_invQuantScales (HM TComTrQuant.cpp):
//   QP%6: 0  1  2  3  4  5
//   IQS: 40 45 51 57 64 72
//
// Clip bounds (HM):
//   CoeffMin = -(1 << (maxLog2TrDynamicRange))
//   CoeffMax =  (1 << (maxLog2TrDynamicRange)) - 1
//   maxLog2TrDynamicRange = 15 for main10 profile
//   → clips to [-32768, 32767]  (Short range)
//
// Config:
//   QP=32, ScalingList=0, BIT_DEPTH=10
//   For QP=32: QP%6=2, IQS=51, QP/6=5
//     rightShift = 8 - 5 = 3  (positive → right shift)
//     add = 1<<2 = 4
//
// Pipeline:
//   Single-cycle combinational IQ per coefficient.
//   1-cycle registered output (matches fwd_quant latency).
//=============================================================================

`include "parameter_pkg.vh"

module inv_quant (
    input  wire         clk,
    input  wire         rst_n,

    input  wire [5:0]   qp,
    input  wire [1:0]   tu_comp,            // 0=Y, 1=Cb, 2=Cr
    input  wire [2:0]   tu_size_log2,       // 2=4x4..5=32x32, used for iTransformShift

    // Input quantized level stream
    input  wire         in_valid,
    output wire         in_ready,
    input  wire signed [`COEFF_WIDTH-1:0] in_level,
    input  wire [9:0]   in_scan_idx,
    input  wire         in_last,

    // Output dequantized coefficient stream
    output reg          out_valid,
    input  wire         out_ready,
    output reg  signed [`COEFF_WIDTH-1:0] out_coeff,
    output reg  [9:0]   out_scan_idx,
    output reg          out_last
);

    //-------------------------------------------------------------------------
    // HEVC Table 8-10 Chroma QP Mapping (ITU-T H.265 Section 8.4.3)
    //-------------------------------------------------------------------------
    function automatic [5:0] chroma_qp_map;
        input [5:0] qp_y;
        begin
            if      (qp_y < 30) chroma_qp_map = qp_y;
            else if (qp_y == 30) chroma_qp_map = 29;
            else if (qp_y == 31) chroma_qp_map = 30;
            else if (qp_y == 32) chroma_qp_map = 31;
            else if (qp_y == 33) chroma_qp_map = 32;
            else if (qp_y == 34) chroma_qp_map = 33;
            else if (qp_y == 35) chroma_qp_map = 33;
            else if (qp_y == 36) chroma_qp_map = 34;
            else if (qp_y == 37) chroma_qp_map = 34;
            else if (qp_y == 38) chroma_qp_map = 35;
            else if (qp_y == 39) chroma_qp_map = 35;
            else if (qp_y == 40) chroma_qp_map = 36;
            else if (qp_y == 41) chroma_qp_map = 36;
            else if (qp_y == 42) chroma_qp_map = 37;
            else if (qp_y == 43) chroma_qp_map = 37;
            // HEVC Table 8-10: for qPi > 43, QpC = qPi - 6
            else chroma_qp_map = qp_y - 6'd6;
        end
    endfunction

    //-------------------------------------------------------------------------
    // g_invQuantScales — HM TComTrQuant.cpp
    //-------------------------------------------------------------------------
    function automatic [6:0] inv_quant_scale;
        input [2:0] qp_mod6;
        case (qp_mod6)
            3'd0: inv_quant_scale = 7'd40;
            3'd1: inv_quant_scale = 7'd45;
            3'd2: inv_quant_scale = 7'd51;
            3'd3: inv_quant_scale = 7'd57;
            3'd4: inv_quant_scale = 7'd64;
            3'd5: inv_quant_scale = 7'd72;
            default: inv_quant_scale = 7'd40;
        endcase
    endfunction

    //-------------------------------------------------------------------------
    // QP decomposition
    //-------------------------------------------------------------------------
    wire [5:0] actual_qp = (tu_comp == 0) ? qp : chroma_qp_map(qp);

    wire [2:0] qp_mod6 = (actual_qp >= 48) ? (actual_qp - 48) :
                          (actual_qp >= 42) ? (actual_qp - 42) :
                          (actual_qp >= 36) ? (actual_qp - 36) :
                          (actual_qp >= 30) ? (actual_qp - 30) :
                          (actual_qp >= 24) ? (actual_qp - 24) :
                          (actual_qp >= 18) ? (actual_qp - 18) :
                          (actual_qp >= 12) ? (actual_qp - 12) :
                          (actual_qp >=  6) ? (actual_qp -  6) : actual_qp[2:0];

    wire [3:0] qp_div6  = (actual_qp >= 48) ? 4'd8 :
                           (actual_qp >= 42) ? 4'd7 :
                           (actual_qp >= 36) ? 4'd6 :
                           (actual_qp >= 30) ? 4'd5 :
                           (actual_qp >= 24) ? 4'd4 :
                           (actual_qp >= 18) ? 4'd3 :
                           (actual_qp >= 12) ? 4'd2 :
                           (actual_qp >=  6) ? 4'd1 : 4'd0;

    wire [6:0] IQS = inv_quant_scale(qp_mod6);

    //-------------------------------------------------------------------------
    // Shift direction and amount
    // Mapped from HM TComTrQuant::xDeQuant:
    // shift = IQUANT_SHIFT - cQP.per - iTransformShift
    // iTransformShift = MAX_TR_DYNAMIC_RANGE - BIT_DEPTH - tu_size_log2
    //-------------------------------------------------------------------------
    localparam IQUANT_SHIFT  = 6;
    localparam MAX_TR_DYNAMIC_RANGE = 15;
    localparam BIT_DEPTH_ADJ = (`BIT_DEPTH > 8) ? (`BIT_DEPTH - 8) : 0;

    wire [4:0] cQP_per = qp_div6 + BIT_DEPTH_ADJ[4:0];
    
    // iTransformShift compensates for forward quant's TU-size-dependent shift
    wire signed [6:0] iTransformShift = $signed(MAX_TR_DYNAMIC_RANGE) - $signed(`BIT_DEPTH) - $signed({4'b0, tu_size_log2});
    
    wire signed [6:0] shift_full = $signed(IQUANT_SHIFT) - $signed({2'b0, cQP_per}) - iTransformShift;

    wire        do_right_shift = (shift_full > 0);
    wire [4:0]  right_shift    = do_right_shift ? shift_full[4:0] : 5'd0;
    wire [6:0]  neg_shift_full = -shift_full;
    wire [4:0]  left_shift     = do_right_shift ? 5'd0 : neg_shift_full[4:0];

    //-------------------------------------------------------------------------
    // IQ computation — combinational
    //
    // product = level * IQS
    // After shift: clips to [-32768, 32767]
    //-------------------------------------------------------------------------
    localparam signed [15:0] COEFF_MAX =  16'sd32767;
    localparam signed [16:0] COEFF_MIN = -17'sd32768;

    wire signed [31:0] product = $signed(in_level) * $signed({1'b0, IQS});

    // Right shift path (most common: QP <= 48)
    wire [31:0] add_right    = (right_shift > 5'd0) ?
                               (32'd1 << (right_shift - 5'd1)) : 32'd0;
    wire signed [31:0] sum_right = product + $signed(add_right);
    wire signed [31:0] coeff_right = (do_right_shift && right_shift > 5'd0) ?
                                     (sum_right >>> right_shift) :
                                     product;  // right_shift=0: no shift

    // Left shift path (QP > 48 — extremely rare at QP=32 target)
    wire signed [31:0] coeff_left = product <<< left_shift;

    // Select shift direction
    wire signed [31:0] coeff_unclipped = do_right_shift ? coeff_right : coeff_left;

    // Clip to Short range [-32768, 32767] (HM CoeffMin/CoeffMax)
    wire signed [`COEFF_WIDTH-1:0] coeff_clipped =
        (coeff_unclipped > $signed(32'sd32767))  ? COEFF_MAX :
        (coeff_unclipped < $signed(-32'sd32768)) ? COEFF_MIN :
        coeff_unclipped[`COEFF_WIDTH-1:0];

    //-------------------------------------------------------------------------
    // Output register — 1-cycle latency
    //-------------------------------------------------------------------------
    assign in_ready = out_ready | ~out_valid;

    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid    <= 1'b0;
            out_coeff    <= {`COEFF_WIDTH{1'b0}};
            out_scan_idx <= 10'd0;
            out_last     <= 1'b0;
        end else if (in_ready) begin
            out_valid    <= in_valid;
            out_coeff    <= in_valid ? coeff_clipped : {`COEFF_WIDTH{1'b0}};
            out_scan_idx <= in_scan_idx;
            out_last     <= in_last;
        end
    end

    //-------------------------------------------------------------------------
    // Simulation checks
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && in_valid && in_ready) begin
            if (qp > `QP_MAX)
                $display("ERROR [inv_quant] QP=%0d out of range at time=%0t",
                         qp, $time);
            // Warn if input level seems too large (possible upstream overflow)
            if (in_level > 16'sd8192 || in_level < -16'sd8192)
                $display("WARN  [inv_quant] large level=%0d at scan=%0d time=%0t",
                         in_level, in_scan_idx, $time);
        end
    end
    // synthesis translate_on

endmodule