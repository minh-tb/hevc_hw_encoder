//=============================================================================
// sao_edge_offset.v
// SAO — Edge Offset Filter
//
// Mapped from HM source:
//   TLibCommon/TComSampleAdaptiveOffset.cpp
//   xProcessSaoBlockCtu()  — dispatches EO/BO per component
//   offsetBlock()          — applies EO offset to pixel
//
// HEVC spec: Section 8.7.3.2 (edge offset process)
//
// SAO EO Algorithm:
//   For each pixel p at position (x,y), compare to two neighbours
//   determined by edgeType (direction):
//
//   EdgeType 0: horizontal    neighbours = left(x-1,y),  right(x+1,y)
//   EdgeType 1: vertical      neighbours = above(x,y-1), below(x,y+1)
//   EdgeType 2: diagonal 135° neighbours = (x-1,y-1),   (x+1,y+1)
//   EdgeType 3: diagonal 45°  neighbours = (x+1,y-1),   (x-1,y+1)
//
//   Category:
//     edgeIdx = sign(p - n0) + sign(p - n1)
//       where sign(x) = 1 if x>0, -1 if x<0, 0 if x=0
//     edgeIdx + 2 maps to category:
//       cat 0 (edge_idx=-2): valley-deep   → offset[0]
//       cat 1 (edge_idx=-1): valley-shallow → offset[1]
//       cat 2 (edge_idx= 0): flat/ridge    → offset[2]=0 (always zero per spec)
//       cat 3 (edge_idx=+1): peak-shallow  → offset[3]
//       cat 4 (edge_idx=+2): peak-deep     → offset[4]
//
//   Output: p' = Clip1(p + saoOffset[category])
//
//   saoOffset[0..4]: signed offsets from SAO parameter decision
//     cat2 offset is always 0 (spec constraint)
//     cats 0,1 must be non-
//   SAOLcuBoundary    = 0  → use deblocked pixels (not raw recon) at boundary
//
// Interface:
//   Processes one pixel per cycle in streaming fashion
//   SAO parameters (edge_type, offsets) latched per CTU component from
//   the SAO parameter decision unit
//   Neighbours supplied by caller — this module only applies the formula
//
// Pipeline: 2 cycles (sign compute + offset apply)
//=============================================================================

`include "parameter_pkg.vh"

module sao_edge_offset (
    input  wire         clk,
    input  wire         rst_n,

    // SAO parameters for this CTU/component (latched for full CTU)
    input  wire [1:0]   edge_type,          // 0=horiz,1=vert,2=135°,3=45°
    input  wire [24:0]  offset,             // saoOffset[0..4] packed {off4, off3, off2, off1, off0}, each signed 5-bit

    // Pixel stream input
    input  wire         in_valid,
    output wire         in_ready,
    input  wire [`PIXEL_WIDTH-1:0] pixel_in,    // current pixel p
    input  wire [`PIXEL_WIDTH-1:0] neigh0,      // first neighbour n0
    input  wire [`PIXEL_WIDTH-1:0] neigh1,      // second neighbour n1
    input  wire         in_last,

    // Pixel stream output
    output reg          out_valid,
    input  wire         out_ready,
    output reg  [`PIXEL_WIDTH-1:0] pixel_out,
    output reg          out_last
);

    //-------------------------------------------------------------------------
    // Clip1 — 10-bit
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
    // Sign function (per HM signOf())
    // sign(a - b) = 1 if a>b, -1 if a<b, 0 if a==b
    //-------------------------------------------------------------------------
    function automatic signed [1:0] sign_diff;
        input [`PIXEL_WIDTH-1:0] a, b;
        begin
            if      (a > b) sign_diff =  2'sd1;
            else if (a < b) sign_diff = -2'sd1;
            else            sign_diff =  2'sd0;
        end
    endfunction

    //-------------------------------------------------------------------------
    // Stage 1: Compute edge index (combinational, registered)
    //-------------------------------------------------------------------------
    assign in_ready = out_ready | ~out_valid;

    wire signed [4:0] offset_array [0:4];
    assign offset_array[0] = offset[4:0];
    assign offset_array[1] = offset[9:5];
    assign offset_array[2] = offset[14:10];
    assign offset_array[3] = offset[19:15];
    assign offset_array[4] = offset[24:20];

    wire signed [1:0] s0 = sign_diff(pixel_in, neigh0);
    wire signed [1:0] s1 = sign_diff(pixel_in, neigh1);
    // edgeIdx = s0 + s1, range -2..+2
    wire signed [2:0] edge_idx  = $signed({s0[1], s0}) + $signed({s1[1], s1});
    // category = edge_idx + 2, range 0..4
    wire [2:0]        category  = edge_idx[2:0] + 3'd2;

    // Select offset for this category
    wire signed [4:0] sao_off   = offset_array[category];

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

    //-------------------------------------------------------------------------
    // Simulation checks
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && in_valid && in_ready) begin
            // Verify offset sign constraints (spec: cats 0,1 >= 0; cats 3,4 <= 0)
            if (offset_array[0] < 5'sd0 || offset_array[1] < 5'sd0)
                $display("WARN  [sao_eo] valley offsets should be non-negative: [0]=%0d [1]=%0d",
                         offset_array[0], offset_array[1]);
            if (offset_array[3] > 5'sd0 || offset_array[4] > 5'sd0)
                $display("WARN  [sao_eo] peak offsets should be non-positive: [3]=%0d [4]=%0d",
                         offset_array[3], offset_array[4]);
        end
    end
    // synthesis translate_on

endmodule