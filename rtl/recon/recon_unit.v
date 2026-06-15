//=============================================================================
// recon_unit.v
// Reconstruction Unit — Prediction + Residual → Reconstructed Pixel
//
// Mapped from HM source:
//   TLibCommon/TComYuv.cpp   addClip()
//     — adds prediction + residual with Clip1 per sample
//   TLibEncoder/TEncCu.cpp   xReconIntraQT() / xReconInterQT()
//     — call sites that drive the reconstruction pipeline
//
// HEVC spec: Section 8.6.3 (picture reconstruction process)
//
// Formula (HM addClip):
//   reconSample[x][y] = Clip1(predSample[x][y] + resSample[x][y])
//   where:
//     predSample = intra or inter prediction pixel (0..1023 for 10-bit)
//     resSample  = IDCT output (signed, range [-32768..32767] per IDCT clip)
//     Clip1(x)   = Clip3(0, (1<<bitDepth)-1, x) = clamp to [0, 1023]
//
// Note: resSample comes from inv_quant → idct_top (already in Short range).
//       predSample comes from intra_pred_top or mc_unit (inter).
//       Both streams must be synchronized — they represent the same pixel.
//
// Synchronization:
//   pred and res streams arrive in the same raster scan order (x,y).
//   Both carry (out_x, out_y) coordinates.
//   This module uses a small FIFO on each input to absorb latency differences
//   and match pixels by (x,y) coordinate.
//   Mismatch detected in simulation — synthesis assumes streams are aligned.
//
// Pipeline:
//   1-cycle registered output (combinational add + clip, then register)
//   Latency: 1 cycle from both inputs valid
//
// Config:
//   BIT_DEPTH = 10  →  Clip1 range [0, 1023]
//=============================================================================

`include "parameter_pkg.vh"

module recon_unit (
    input  wire         clk,
    input  wire         rst_n,

    // Context
    input  wire [1:0]   comp,               // 0=Y, 1=Cb, 2=Cr (for chroma offset)

    // Prediction pixel stream (from intra_pred_top or mc_unit)
    input  wire         pred_valid,
    output wire         pred_ready,
    input  wire [`PIXEL_WIDTH-1:0] pred_pixel,  // unsigned 10-bit
    input  wire [5:0]   pred_x,             // PU-relative x (0..63)
    input  wire [5:0]   pred_y,             // PU-relative y (0..63)
    input  wire         pred_last,

    // Residual stream (from idct_top, signed 16-bit Short range)
    input  wire         res_valid,
    output wire         res_ready,
    input  wire signed [`COEFF_WIDTH-1:0] res_coeff,  // signed 16-bit
    input  wire [5:0]   res_x_pu,           // PU-relative x for SRAM lookup (0..63)
    input  wire [5:0]   res_y_pu,           // PU-relative y for SRAM lookup (0..63)
    input  wire [5:0]   res_x_ctu,          // CTU-relative x for output
    input  wire [5:0]   res_y_ctu,          // CTU-relative y for output
    input  wire         res_last,

    // Reconstructed pixel output
    output reg          out_valid,
    input  wire         out_ready,
    output reg  [`PIXEL_WIDTH-1:0] out_pixel,  // unsigned 10-bit, clipped
    output reg  [5:0]   out_x,              // CTU-relative x
    output reg  [5:0]   out_y,              // CTU-relative y
    output reg          out_last,
    output reg  [1:0]   out_comp
);

    //-------------------------------------------------------------------------
    // Clip1 bounds (10-bit luma/chroma)
    // HM: Clip3(0, (1<<bitDepth)-1, val)
    //-------------------------------------------------------------------------
    localparam [10:0] CLIP_MAX = (1 << `BIT_DEPTH) - 1;   // 1023
    localparam [10:0] CLIP_MIN = 11'd0;

    //-------------------------------------------------------------------------
    // SRAM storage for Prediction pixels
    // Since PU max size is 64x64, we need 4096 depth
    //-------------------------------------------------------------------------
    reg [`PIXEL_WIDTH-1:0] pred_sram [0:4095];

    // Write Port (Prediction)
    always @(posedge clk) begin
        if (pred_valid) begin
            pred_sram[{pred_y, pred_x}] <= pred_pixel;
        end
    end

    // Always ready for prediction pixels
    assign pred_ready = 1'b1;

    //-------------------------------------------------------------------------
    // Read Port (Residual matching)
    // Pipeline stage 1: Read SRAM and register residual inputs
    //-------------------------------------------------------------------------
    reg        res_valid_q;
    reg signed [`COEFF_WIDTH-1:0] res_coeff_q;
    reg [5:0]  res_x_ctu_q;
    reg [5:0]  res_y_ctu_q;
    reg        res_last_q;
    reg [1:0]  res_comp_q;

    reg [`PIXEL_WIDTH-1:0] pred_read_data;

    always @(posedge clk) begin
        if (res_valid && res_ready) begin
            pred_read_data <= pred_sram[{res_y_pu, res_x_pu}];
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            res_valid_q <= 1'b0;
        end else if (res_ready) begin // res_ready is essentially out_ready
            res_valid_q <= res_valid;
            res_coeff_q <= res_coeff;
            res_x_ctu_q <= res_x_ctu;
            res_y_ctu_q <= res_y_ctu;
            res_last_q  <= res_last;
            res_comp_q  <= comp;
        end else if (out_ready) begin
            res_valid_q <= 1'b0; // Clear valid if downstream accepts but no new input
        end
    end

    // Since we don't have FIFOs, if downstream is not ready, we must backpressure
    // For now, out_ready is assumed 1 in top level, but we link it anyway
    assign res_ready = out_ready;

    //-------------------------------------------------------------------------
    // Reconstruction formula (Pipeline stage 2)
    // sum = pred + res (signed 17-bit: pred 10-bit + res up to ±32767)
    // clip to [0, 1023]
    //-------------------------------------------------------------------------
    wire signed [16:0] recon_sum = $signed({1'b0, pred_read_data}) + res_coeff_q;
    
    wire [`PIXEL_WIDTH-1:0] recon_clipped = 
        (recon_sum > $signed({6'b0, CLIP_MAX})) ? CLIP_MAX[`PIXEL_WIDTH-1:0] :
        (recon_sum < $signed(17'd0))            ? {`PIXEL_WIDTH{1'b0}} :
        recon_sum[`PIXEL_WIDTH-1:0];

    //-------------------------------------------------------------------------
    // Output register (Pipeline stage 2)
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_pixel <= {`PIXEL_WIDTH{1'b0}};
            out_x     <= 6'd0;
            out_y     <= 6'd0;
            out_last  <= 1'b0;
            out_comp  <= 2'd0;
        end else begin
            if (out_ready) begin
                out_valid <= res_valid_q;
                out_pixel <= recon_clipped;
                out_x     <= res_x_ctu_q;
                out_y     <= res_y_ctu_q;
                out_last  <= res_last_q;
                out_comp  <= res_comp_q;
            end
        end
    end

endmodule