//=============================================================================
// sao_stats.v
// SAO Statistics Gatherer and RDO Decision
//=============================================================================

`include "parameter_pkg.vh"

module sao_stats (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         start,
    output reg          done,

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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done <= 0;
            rec_rd_valid <= 0; org_rd_valid <= 0;
            sao_type <= 0; eo_class <= 0; eo_offset <= 0; band_pos <= 0; bo_offset <= 0;
        end else begin
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
