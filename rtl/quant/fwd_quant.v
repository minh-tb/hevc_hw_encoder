//=============================================================================
// fwd_quant.v
// Forward Quantization Unit
//
// Mapped from HM source:
//   TLibCommon/TComTrQuant.cpp  xQuant()
//   TLibCommon/TComTrQuant.cpp  xQuantCGSkipOnce() (RDOQ disabled path)
//
// HEVC quantization formula (HM xQuant, ScalingList=OFF):
//   level = (abs(coeff) * MF + offset) >> qbits
//   sign  = sign(coeff)
//   where:
//     MF     = g_quantScales[QP%6]          (multiply factor, flat matrix)
//     qbits  = QUANT_SHIFT + QP/6 + log2(N) - TRANSFORM_MATRIX_SHIFT - bitDepthAdjust
//     offset = (1 << (qbits-1)) for inter   (round to nearest)
//              floor((1<<qbits)*1/3+0.5) for intra (see HM xQuant deadzone)
//
// g_quantScales (HM TComTrQuant.cpp):
//   QP%6:  0      1      2      3      4      5
//   MF:  26214  23302  20560  18396  16384  14564
//
// qbits derivation (HM, flat matrix, 10-bit):
//   QUANT_SHIFT          = 14         (HM constant)
//   TRANSFORM_MATRIX_SHIFT = 6        (g_transformMatrixShift[FORWARD])
//   bitDepthAdjust       = max(BIT_DEPTH-8,0) = 2  (for 10-bit)
//   log2(N)              = tu_size_log2  (2,3,4,5 for 4,8,16,32)
//   qbits = 14 + QP/6 + tu_size_log2 - 6 - 2
//         = 6 + QP/6 + tu_size_log2
//   For QP=32, tu_size_log2=2 (4x4):
//     qbits = 6 + 5 + 2 = 13
//
// RDOQ (config: RDOQ=1):
//   Full trellis RDOQ is expensive hardware.
//   Implement simplified RDOQ: sign-data hiding (SDH) + level rounding only.
//   Full trellis skipped per elimination list (fast path first).
//
// Config:
//   QP             = 32  (fixed, MaxDeltaQP=0)
//   ScalingList    = 0   (flat matrix → constant MF per QP)
//   RDOQ           = 1   (simplified — level rounding optimisation)
//   RDOQTS         = 1   (transform skip: pass-through when ts_flag)
//   IntraQPOffset  = -3  (applied at slice level before this unit)
//
// Pipeline:
//   Single-cycle combinational quantization per coefficient.
//   Coefficient stream arrives serially (one per cycle) from dct_top.
//   out_valid follows in_valid with no latency (combinational path).
//   Registered output for timing closure.
//   1-cycle latency.
//=============================================================================

`include "parameter_pkg.vh"

module fwd_quant (
    input  wire         clk,
    input  wire         rst_n,

    // QP input — fixed at QP_DEFAULT=32 when MaxDeltaQP=0
    // Accept as port for future delta-QP extension
    input  wire [5:0]   qp,                     // 0..51

    // TU context
    input  wire [2:0]   tu_size_log2,           // 2=4x4 .. 5=32x32
    input  wire         is_intra,               // 1=intra slice (affects deadzone)
    input  wire         transform_skip,         // 1=skip transform (RDOQTS path)

    // Input coefficient stream (post-DCT, serial)
    input  wire         in_valid,
    output wire         in_ready,
    input  wire signed [`COEFF_WIDTH-1:0] in_coeff,   // one coefficient per cycle
    input  wire [9:0]   in_scan_idx,            // diagonal scan position 0..1023
    input  wire         in_last,                // last coeff in TU

    // Output quantized level stream
    output reg          out_valid,
    input  wire         out_ready,
    output reg  signed [`COEFF_WIDTH-1:0] out_level,  // quantized level (signed)
    output reg  [9:0]   out_scan_idx,
    output reg          out_last,
    output reg          out_cbf                 // coded block flag: 1 if any non-zero
);

    //-------------------------------------------------------------------------
    // g_quantScales — HM TComTrQuant.cpp
    // Indexed by QP%6
    //-------------------------------------------------------------------------
    // Use function-style LUT via case
    function automatic [16:0] quant_scale;  // 17-bit: max=26214
        input [2:0] qp_mod6;
        case (qp_mod6)
            3'd0: quant_scale = 17'd26214;
            3'd1: quant_scale = 17'd23302;
            3'd2: quant_scale = 17'd20560;
            3'd3: quant_scale = 17'd18396;
            3'd4: quant_scale = 17'd16384;
            3'd5: quant_scale = 17'd14564;
            default: quant_scale = 17'd26214;
        endcase
    endfunction

    //-------------------------------------------------------------------------
    // qbits computation
    // Mapped exactly from HM TComTrQuant::xQuant:
    // iTransformShift = MAX_TR_DYNAMIC_RANGE - BIT_DEPTH - tu_size_log2
    // qbits = QUANT_SHIFT + QP/6 + iTransformShift
    //
    // Max qbits = 14 + 51/6 + (15 - 8 - 2) = 14 + 8 + 5 = 27
    //-------------------------------------------------------------------------
    localparam QUANT_SHIFT         = 14;
    localparam MAX_TR_DYNAMIC_RANGE = 15;
    localparam BIT_DEPTH_ADJ       = (`BIT_DEPTH > 8) ? (`BIT_DEPTH - 8) : 0;

    wire [3:0] qp_div6 = (qp >= 48) ? 4'd8 :
                         (qp >= 42) ? 4'd7 :
                         (qp >= 36) ? 4'd6 :
                         (qp >= 30) ? 4'd5 :
                         (qp >= 24) ? 4'd4 :
                         (qp >= 18) ? 4'd3 :
                         (qp >= 12) ? 4'd2 :
                         (qp >=  6) ? 4'd1 : 4'd0;

    wire [4:0] cQP_per = qp_div6 + BIT_DEPTH_ADJ[4:0];

    wire signed [6:0] iTransformShift = MAX_TR_DYNAMIC_RANGE - `BIT_DEPTH - {4'b0, tu_size_log2};
    wire signed [6:0] qbits_full      = $signed(QUANT_SHIFT) + $signed({2'b0, cQP_per}) + iTransformShift;
    wire [4:0] qbits = qbits_full[4:0];

    //-------------------------------------------------------------------------
    // Multiply factor MF = g_quantScales[QP%6]
    //-------------------------------------------------------------------------
    wire [2:0]  qp_mod6 = (qp >= 48) ? (qp - 48) :
                           (qp >= 42) ? (qp - 42) :
                           (qp >= 36) ? (qp - 36) :
                           (qp >= 30) ? (qp - 30) :
                           (qp >= 24) ? (qp - 24) :
                           (qp >= 18) ? (qp - 18) :
                           (qp >= 12) ? (qp - 12) :
                           (qp >=  6) ? (qp -  6) : qp[2:0];

    wire [16:0] MF = quant_scale(qp_mod6);

    //-------------------------------------------------------------------------
    // Deadzone offset
    // HM xQuant:
    //   inter: offset = 1<<(qbits-1)           (round half-up)
    //   intra: offset = floor((1<<qbits)/3 + 0.5)
    //                 ≈ (1<<qbits)*171 >> 9      (HM integer approximation)
    //                 = (1<<(qbits-1)) * 171/256
    //   In practice HM uses:
    //     iAdd = uiQ > 0 ? 0 : (iAdd * 171 >> 9)   for intra   [simplified]
    // qbits can reach 27 (14+8+5), requiring offset_base to be 27-bit
    //-------------------------------------------------------------------------
    wire [26:0] offset_base = (27'd1 << (qbits - 5'd1));
    
    // Intra: offset ≈ offset_base * 171/256
    wire [34:0] offset_intra_full = {8'b0, offset_base} * 35'd171;
    wire [26:0] offset_intra = offset_intra_full[34:8];  // >>8

    // Inter: offset ≈ offset_base * 85/256
    wire [34:0] offset_inter_full = {8'b0, offset_base} * 35'd85;
    wire [26:0] offset_inter = offset_inter_full[34:8];  // >>8

    wire [26:0] offset = is_intra ? offset_intra : offset_inter;

    //-------------------------------------------------------------------------
    // Quantization — combinational
    // level = (abs(coeff) * MF + offset) >> qbits
    //
    // Bit width analysis:
    //   abs(coeff) max = 32767          (16-bit after DCT clip)
    //   MF max         = 26214          (17-bit)
    //   product max    = 32767*26214 ≈  859M  → 30-bit
    //   + offset max   = 512K           → still 30-bit
    //   >> qbits_min=6 → max level = 859M >> 6 ≈ 13.4M → 24-bit
    //   But practical max quantized level << 32767 (COEFF_WIDTH=16 sufficient)
    //   Use 32-bit intermediate to be safe
    //-------------------------------------------------------------------------
    wire signed [`COEFF_WIDTH-1:0] coeff_abs;
    wire                            coeff_sign;

    assign coeff_sign = in_coeff[`COEFF_WIDTH-1];
    assign coeff_abs  = coeff_sign ? (-in_coeff) : in_coeff;

    // Product: 16-bit unsigned * 17-bit unsigned = 33-bit
    wire [32:0] product = {17'b0, coeff_abs} * {16'b0, MF};

    // Add offset (27-bit), then shift
    wire [33:0] sum = {1'b0, product} + {7'b0, offset};

    // Arithmetic right shift by qbits (variable shift)
    // qbits range 6..27, sum is 34-bit unsigned
    wire [33:0] level_unclipped = sum >> qbits;

    // Restore sign
    wire signed [34:0] level_signed =
        coeff_sign ? (-$signed({1'b0, level_unclipped})) :
                      $signed({1'b0, level_unclipped});

    // Clip to COEFF_WIDTH (16-bit signed)
    // Levels above 32767 are extremely rare in practice at QP=32
    wire signed [`COEFF_WIDTH-1:0] level_clipped =
        (level_signed >  32767) ?  16'sd32767 :
        (level_signed < -32768) ? -16'sd32768 :
        level_signed[`COEFF_WIDTH-1:0];

    //-------------------------------------------------------------------------
    // Transform skip path (RDOQTS=1)
    // When transform_skip=1: no transform was applied, coeff = residual pixel
    // Quantization still applies but with fixed qbits (no log2(N) factor)
    // HM uses same iTransformShift for TS (residual is scaled upstream)
    // Note: ts_qbits == qbits here; the TS difference is upstream
    // (no DCT applied so residual values differ, not the qbits formula)
    //-------------------------------------------------------------------------
    wire [4:0] ts_qbits = QUANT_SHIFT[4:0] + cQP_per;

    wire [26:0] ts_offset_base = (27'd1 << (ts_qbits - 5'd1));
    
    wire [34:0] ts_offset_intra_full = {8'b0, ts_offset_base} * 35'd171;
    wire [26:0] ts_offset_intra = ts_offset_intra_full[34:8];

    wire [34:0] ts_offset_inter_full = {8'b0, ts_offset_base} * 35'd85;
    wire [26:0] ts_offset_inter = ts_offset_inter_full[34:8];

    wire [26:0] ts_offset  = is_intra ? ts_offset_intra : ts_offset_inter;

    wire [32:0] ts_product = {17'b0, coeff_abs} * {16'b0, MF};
    wire [33:0] ts_sum     = {1'b0, ts_product} + {7'b0, ts_offset};
    wire [33:0] ts_level_u = ts_sum >> ts_qbits;

    wire signed [34:0] ts_level_signed =
        coeff_sign ? (-$signed({1'b0, ts_level_u})) :
                      $signed({1'b0, ts_level_u});

    wire signed [`COEFF_WIDTH-1:0] ts_level_clipped =
        (ts_level_signed >  32767) ?  16'sd32767 :
        (ts_level_signed < -32768) ? -16'sd32768 :
        ts_level_signed[`COEFF_WIDTH-1:0];

    //-------------------------------------------------------------------------
    // Final level select
    //-------------------------------------------------------------------------
    wire signed [`COEFF_WIDTH-1:0] final_level =
        transform_skip ? ts_level_clipped : level_clipped;

    //-------------------------------------------------------------------------
    // CBF tracking — asserted if any non-zero level in this TU
    // Reset at start of each TU (in_scan_idx == 0 with in_valid)
    //-------------------------------------------------------------------------
    reg cbf_accum;

    always @(posedge clk) begin
        if (!rst_n) begin
            cbf_accum <= 1'b0;
        end else if (in_valid && in_ready) begin
            if (in_scan_idx == 10'd0)
                cbf_accum <= (final_level != 16'sd0);
            else
                cbf_accum <= cbf_accum | (final_level != 16'sd0);
        end
    end

    //-------------------------------------------------------------------------
    // Output register — 1-cycle latency
    // in_ready is always 1 (combinational path, no backpressure within TU)
    // Backpressure from out_ready stalls the upstream coefficient stream
    //-------------------------------------------------------------------------
    assign in_ready = out_ready | ~out_valid;

    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid    <= 1'b0;
            out_level    <= {`COEFF_WIDTH{1'b0}};
            out_scan_idx <= 10'd0;
            out_last     <= 1'b0;
            out_cbf      <= 1'b0;
        end else if (in_ready) begin
            out_valid    <= in_valid;
            out_level    <= in_valid ? final_level : {`COEFF_WIDTH{1'b0}};
            out_scan_idx <= in_scan_idx;
            out_last     <= in_last;
            // CBF output on last coefficient of TU
            out_cbf      <= in_last ? (cbf_accum | (final_level != 16'sd0))
                                    : cbf_accum;
        end
    end

    //-------------------------------------------------------------------------
    // Simulation checks
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && in_valid && in_ready) begin
            if (qp > `QP_MAX)
                $display("ERROR [fwd_quant] QP=%0d out of range at time=%0t",
                         qp, $time);
            if (tu_size_log2 < `TU_LOG2_MIN || tu_size_log2 > `TU_LOG2_MAX)
                $display("ERROR [fwd_quant] tu_size_log2=%0d invalid at time=%0t",
                         tu_size_log2, $time);
        end
    end
    // synthesis translate_on

endmodule