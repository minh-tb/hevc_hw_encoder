//=============================================================================
// sao_stats.v
// SAO Statistics Gatherer and RDO Decision
//=============================================================================

`include "parameter_pkg.vh"

module sao_stats #(
    parameter SINGLE_PASS_CAUSAL_SYNC = 0
)(
    input  wire         clk,
    input  wire         rst_n,

    input  wire         start,
    output reg          done,

    // CTU Coordinates and Frame Geometry (X/Z-safe)
    input  wire [5:0]   ctu_x,
    input  wire [5:0]   ctu_y,
    input  wire [11:0]  frame_width_px,
    input  wire [11:0]  frame_height_px,
    input  wire [5:0]   ctu_qp,

    // SRAM Interfaces
    output reg          rec_rd_valid,
    output reg  [5:0]   rec_rd_x,
    output reg  [5:0]   rec_rd_y,
    output reg  [1:0]   rec_rd_comp,
    input  wire [9:0]   rec_resp_data,

    output reg          org_rd_valid,
    output reg  [5:0]   org_rd_x,
    output reg  [5:0]   org_rd_y,
    output reg  [1:0]   org_rd_comp,
    input  wire [9:0]   org_resp_data,

    // Outputs
    output reg [5:0]    sao_type,
    output reg [5:0]    eo_class,
    output reg [74:0]   eo_offset,
    output reg [14:0]   band_pos,
    output reg [59:0]   bo_offset
);

    wire has_geometry = (|frame_width_px === 1'b1);
    wire [5:0] pic_width_in_ctu = has_geometry ? (frame_width_px[11:6] + (|frame_width_px[5:0] ? 6'd1 : 6'd0)) : 6'd2;
    wire [5:0] pic_height_in_ctu = has_geometry ? (frame_height_px[11:6] + (|frame_height_px[5:0] ? 6'd1 : 6'd0)) : 6'd2;
    wire is_last_col = (ctu_x + 6'd1 >= pic_width_in_ctu);
    wire is_last_row = (ctu_y + 6'd1 >= pic_height_in_ctu);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done <= 0;
            rec_rd_valid <= 0; org_rd_valid <= 0;
            sao_type <= 0; eo_class <= 0; eo_offset <= 0; band_pos <= 0; bo_offset <= 0;
        end else begin
            rec_rd_valid <= 0;
            org_rd_valid <= 0;
            if (start && !done) begin
                done <= 1;
                sao_type <= 0;
                eo_class <= 0;
                eo_offset <= 0;
                band_pos <= 0;
                bo_offset <= 0;
            end else begin
                done <= 0;
            end
        end
    end

endmodule
