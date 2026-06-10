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
// Transform skip path (config: TransformSkip=1):
//   When transform_skip=1, resSample is the raw quantized residual
//   (no IDCT applied). The formula is identical — just add and clip.
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
    input  wire         transform_skip,     // 1=skip (same path, for annotation)
    input  wire [1:0]   comp,               // 0=Y, 1=Cb, 2=Cr (for chroma offset)

    // Prediction pixel stream (from intra_pred_top or mc_unit)
    input  wire         pred_valid,
    output wire         pred_ready,
    input  wire [`PIXEL_WIDTH-1:0] pred_pixel,  // unsigned 10-bit
    input  wire [5:0]   pred_x,
    input  wire [5:0]   pred_y,
    input  wire         pred_last,

    // Residual stream (from idct_top, signed 16-bit Short range)
    input  wire         res_valid,
    output wire         res_ready,
    input  wire signed [`COEFF_WIDTH-1:0] res_coeff,  // signed 16-bit
    input  wire [5:0]   res_x,
    input  wire [5:0]   res_y,
    input  wire         res_last,

    // Reconstructed pixel output
    output reg          out_valid,
    input  wire         out_ready,
    output reg  [`PIXEL_WIDTH-1:0] out_pixel,  // unsigned 10-bit, clipped
    output reg  [5:0]   out_x,
    output reg  [5:0]   out_y,
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
    // Small sync FIFOs — depth 4 sufficient for intra pipeline skew
    // Pred and res arrive within a few cycles of each other
    //
    // Pred FIFO: holds prediction pixels until residual arrives
    // Res FIFO:  holds residuals until prediction arrives
    //-------------------------------------------------------------------------
    localparam SYNC_DEPTH = 4;
    localparam SYNC_BITS  = 2;  // log2(4)

    // Pred FIFO storage
    // Entry: {comp[1:0], pixel[9:0], x[5:0], y[5:0], last[0]} = 25 bits
    localparam PRED_W = 2 + `PIXEL_WIDTH + 6 + 6 + 1;
    reg [PRED_W-1:0] pred_fifo [0:SYNC_DEPTH-1];
    reg [SYNC_BITS:0] pred_wr, pred_rd;
    wire pred_fifo_full  = (pred_wr[SYNC_BITS] != pred_rd[SYNC_BITS]) &&
                           (pred_wr[SYNC_BITS-1:0] == pred_rd[SYNC_BITS-1:0]);
    wire pred_fifo_empty = (pred_wr == pred_rd);

    // Res FIFO storage
    // Entry: {coeff[15:0], x[5:0], y[5:0], last[0]} = 29 bits
    localparam RES_W = `COEFF_WIDTH + 6 + 6 + 1;   // 29
    reg [RES_W-1:0] res_fifo [0:SYNC_DEPTH-1];
    reg [SYNC_BITS:0] res_wr, res_rd;
    wire res_fifo_full  = (res_wr[SYNC_BITS] != res_rd[SYNC_BITS]) &&
                          (res_wr[SYNC_BITS-1:0] == res_rd[SYNC_BITS-1:0]);
    wire res_fifo_empty = (res_wr == res_rd);

    //-------------------------------------------------------------------------
    // Input acceptance — accept when respective FIFO not full
    //-------------------------------------------------------------------------
    assign pred_ready = !pred_fifo_full;
    assign res_ready  = !res_fifo_full;

    wire pred_fire = pred_valid && pred_ready;
    wire res_fire  = res_valid  && res_ready;

    //-------------------------------------------------------------------------
    // FIFO push
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            pred_wr <= {(SYNC_BITS+1){1'b0}};
            res_wr  <= {(SYNC_BITS+1){1'b0}};
        end else begin
            if (pred_fire) begin
                pred_fifo[pred_wr[SYNC_BITS-1:0]] <=
                    {comp, pred_pixel, pred_x, pred_y, pred_last};
                pred_wr <= pred_wr + 1'b1;
            end
            if (res_fire) begin
                res_fifo[res_wr[SYNC_BITS-1:0]] <=
                    {res_coeff, res_x, res_y, res_last};
                res_wr <= res_wr + 1'b1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // FIFO pop and reconstruct
    // Pop both FIFOs together when both have data and output is ready
    //-------------------------------------------------------------------------
    wire can_output = !pred_fifo_empty && !res_fifo_empty &&
                      (out_ready || !out_valid);

    // Unpack FIFO heads
    wire [1:0]                     pred_head_comp  = pred_fifo[pred_rd[SYNC_BITS-1:0]][PRED_W-1:PRED_W-2];
    wire [`PIXEL_WIDTH-1:0]        pred_head_pixel = pred_fifo[pred_rd[SYNC_BITS-1:0]][PRED_W-3:13];
    wire [5:0]                     pred_head_x     = pred_fifo[pred_rd[SYNC_BITS-1:0]][12:7];
    wire [5:0]                     pred_head_y     = pred_fifo[pred_rd[SYNC_BITS-1:0]][6:1];
    wire                           pred_head_last  = pred_fifo[pred_rd[SYNC_BITS-1:0]][0];

    wire signed [`COEFF_WIDTH-1:0] res_head_coeff  = res_fifo[res_rd[SYNC_BITS-1:0]][RES_W-1:RES_W-`COEFF_WIDTH];
    wire [5:0]                     res_head_x      = res_fifo[res_rd[SYNC_BITS-1:0]][12:7];
    wire [5:0]                     res_head_y      = res_fifo[res_rd[SYNC_BITS-1:0]][6:1];
    wire                           res_head_last   = res_fifo[res_rd[SYNC_BITS-1:0]][0];

    //-------------------------------------------------------------------------
    // Reconstruction formula
    // sum = pred + res (signed 17-bit: pred 10-bit + res up to ±32767)
    // clip to [0, 1023]
    //
    // HM addClip():
    //   iTemp = pSrc0[x] + pSrc1[x]
    //   pDst[x] = Clip3(0, (1<<bitDepth)-1, iTemp)
    //-------------------------------------------------------------------------
    wire signed [16:0] recon_sum = $signed({1'b0, pred_head_pixel}) +
                                    $signed(res_head_coeff);

    wire [`PIXEL_WIDTH-1:0] recon_clipped =
        (recon_sum > $signed({6'b0, CLIP_MAX})) ? CLIP_MAX[`PIXEL_WIDTH-1:0] :
        (recon_sum < $signed(17'd0))            ? {`PIXEL_WIDTH{1'b0}} :
        recon_sum[`PIXEL_WIDTH-1:0];

    //-------------------------------------------------------------------------
    // Output register + FIFO pop
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_pixel <= {`PIXEL_WIDTH{1'b0}};
            out_x     <= 6'd0;
            out_y     <= 6'd0;
            out_last  <= 1'b0;
            out_comp  <= 2'd0;
            pred_rd   <= {(SYNC_BITS+1){1'b0}};
            res_rd    <= {(SYNC_BITS+1){1'b0}};
        end else begin
            if (can_output) begin
                out_valid <= 1'b1;
                out_pixel <= recon_clipped;
                out_x     <= pred_head_x;
                out_y     <= pred_head_y;
                out_last  <= pred_head_last;
                out_comp  <= pred_head_comp;
                pred_rd   <= pred_rd + 1'b1;
                res_rd    <= res_rd  + 1'b1;
            end else if (out_ready) begin
                out_valid <= 1'b0;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Simulation: coordinate mismatch detection
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && can_output) begin
            if (pred_head_x != res_head_x || pred_head_y != res_head_y) begin
                $display("ERROR [recon_unit] coord mismatch: pred(%0d,%0d) res(%0d,%0d) at time=%0t",
                         pred_head_x, pred_head_y,
                         res_head_x,  res_head_y,  $time);
            end
            if (pred_head_last != res_head_last) begin
                $display("WARN  [recon_unit] last flag mismatch at (%0d,%0d) time=%0t",
                         pred_head_x, pred_head_y, $time);
            end
        end
    end
    // synthesis translate_on

endmodule