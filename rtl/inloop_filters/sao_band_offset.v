//=============================================================================
// sao_band_offset.v
// SAO — Band Offset Filter
//
// Mapped from HM source:
//   TLibCommon/TComSampleAdaptiveOffset.cpp
//
// HEVC spec: Section 8.7.3.2.4 (band offset process)
//
// SAO BO Algorithm:
//   The intensity range is divided into 32 bands.
//   For each pixel, its band index is: bandIdx = pixel >> (BIT_DEPTH - 5)
//   If bandIdx is within the 4 consecutive bands starting at band_position,
//   the corresponding offset is added to the pixel.
//
// Pipeline: 2 cycles (band match + offset apply)
//=============================================================================

`include "parameter_pkg.vh"

module sao_band_offset (
    input  wire         clk,
    input  wire         rst_n,

    // SAO parameters for this CTU/component (latched for full CTU)
    input  wire [4:0]   band_position,      // starting band (0..31)
    input  wire [19:0]  offset,             // saoOffset[0..3] packed {off3, off2, off1, off0}, each signed 5-bit

    // Pixel stream input
    input  wire         in_valid,
    output wire         in_ready,
    input  wire [`PIXEL_WIDTH-1:0] pixel_in,    // current pixel p
    input  wire         in_last,

    // Pixel stream output
    output reg          out_valid,
    input  wire         out_ready,
    output reg  [`PIXEL_WIDTH-1:0] pixel_out,
    output reg          out_last
);

    //-------------------------------------------------------------------------
    // Clip1
    //-------------------------------------------------------------------------
    localparam signed [11:0] CLIP1_MAX = (1 << `BIT_DEPTH) - 1;

    function automatic [`PIXEL_WIDTH-1:0] clip1;
        input signed [11:0] val;
        begin
            if      (val > CLIP1_MAX) clip1 = CLIP1_MAX[`PIXEL_WIDTH-1:0];
            else if (val < 12'sd0)    clip1 = {`PIXEL_WIDTH{1'b0}};
            else                      clip1 = val[`PIXEL_WIDTH-1:0];
        end
    endfunction

    //-------------------------------------------------------------------------
    // Stage 1: Compute band match
    //-------------------------------------------------------------------------
    assign in_ready = out_ready | ~out_valid;

    // Extract upper 5 bits to get the band index
    wire [4:0] band_idx = pixel_in[`BIT_DEPTH-1 : `BIT_DEPTH-5];
    
    // Compute distance from the starting band position
    // 5-bit arithmetic natively handles the wrap-around at 32
    wire [4:0] band_diff = band_idx - band_position;
    
    // Unpack offsets
    wire signed [4:0] offset_array [0:3];
    assign offset_array[0] = offset[4:0];
    assign offset_array[1] = offset[9:5];
    assign offset_array[2] = offset[14:10];
    assign offset_array[3] = offset[19:15];

    // If within the 4 bands, select the offset, else 0
    wire match = (band_diff < 5'd4);
    wire signed [4:0] sao_off = match ? offset_array[band_diff[1:0]] : 5'sd0;

    // Apply: p' = Clip1(p + offset)
    wire signed [11:0] sum = $signed({2'b0, pixel_in}) + $signed({{7{sao_off[4]}}, sao_off});
    wire [`PIXEL_WIDTH-1:0] pixel_filtered = clip1(sum);

    //-------------------------------------------------------------------------
    // Output register (1-cycle latency)
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid  <= 1'b0;
            pixel_out  <= {`PIXEL_WIDTH{1'b0}};
            out_last   <= 1'b0;
        end else if (in_ready) begin
            out_valid  <= in_valid;
            pixel_out  <= in_valid ? pixel_filtered : {`PIXEL_WIDTH{1'b0}};
            out_last   <= in_last;
        end
    end

endmodule