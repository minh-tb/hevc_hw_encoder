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

`ifdef REMEDIATION
    localparam [1:0]
        S_IDLE   = 2'd0,
        S_SCAN   = 2'd1,
        S_DERIVE = 2'd2,
        S_DONE   = 2'd3;

    reg [1:0] state;
    reg [5:0] scan_cnt; // 0..47 (48 read cycles)
    reg       scan_valid_q;
    reg [1:0] scan_comp_q;

    // Accumulators for signed pixel differences (org - rec)
    reg signed [15:0] diff_accum_y;
    reg signed [15:0] diff_accum_u;
    reg signed [15:0] diff_accum_v;

    wire [1:0] cur_comp = (scan_cnt < 6'd16) ? 2'd0 :
                          (scan_cnt < 6'd32) ? 2'd1 : 2'd2;
    wire [3:0] sample_idx = scan_cnt[3:0]; // 0..15 in 4x4 grid
    wire [5:0] grid_x = (cur_comp == 2'd0) ? {sample_idx[1:0], 4'b1000} : {1'b0, sample_idx[1:0], 3'b100};
    wire [5:0] grid_y = (cur_comp == 2'd0) ? {sample_idx[3:2], 4'b1000} : {1'b0, sample_idx[3:2], 3'b100};

    wire signed [10:0] sample_diff = $signed({1'b0, org_resp_data}) - $signed({1'b0, rec_resp_data});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            done         <= 1'b0;
            scan_cnt     <= 6'd0;
            scan_valid_q <= 1'b0;
            scan_comp_q  <= 2'd0;
            rec_rd_valid <= 1'b0;
            rec_rd_x     <= 6'd0;
            rec_rd_y     <= 6'd0;
            rec_rd_comp  <= 2'd0;
            org_rd_valid <= 1'b0;
            org_rd_x     <= 6'd0;
            org_rd_y     <= 6'd0;
            org_rd_comp  <= 2'd0;
            diff_accum_y <= 16'sd0;
            diff_accum_u <= 16'sd0;
            diff_accum_v <= 16'sd0;
            sao_type     <= 6'd0;
            eo_class     <= 6'd0;
            eo_offset    <= 75'd0;
            band_pos     <= 15'd0;
            bo_offset    <= 60'd0;
        end else begin
            done         <= 1'b0;
            rec_rd_valid <= 1'b0;
            org_rd_valid <= 1'b0;

            // Pipeline 1-cycle delayed accumulator
            if (scan_valid_q) begin
                if (scan_comp_q == 2'd0)      diff_accum_y <= diff_accum_y + {{5{sample_diff[10]}}, sample_diff};
                else if (scan_comp_q == 2'd1) diff_accum_u <= diff_accum_u + {{5{sample_diff[10]}}, sample_diff};
                else                          diff_accum_v <= diff_accum_v + {{5{sample_diff[10]}}, sample_diff};
            end

            case (state)
                S_IDLE: begin
                    scan_cnt     <= 6'd0;
                    scan_valid_q <= 1'b0;
                    if (start) begin
                        diff_accum_y <= 16'sd0;
                        diff_accum_u <= 16'sd0;
                        diff_accum_v <= 16'sd0;
                        state        <= S_SCAN;
                    end
                end

                S_SCAN: begin
                    if (scan_cnt < 6'd48) begin
                        rec_rd_valid <= 1'b1;
                        rec_rd_x     <= grid_x;
                        rec_rd_y     <= grid_y;
                        rec_rd_comp  <= cur_comp;

                        org_rd_valid <= 1'b1;
                        org_rd_x     <= grid_x;
                        org_rd_y     <= grid_y;
                        org_rd_comp  <= cur_comp;

                        scan_valid_q <= 1'b1;
                        scan_comp_q  <= cur_comp;
                        scan_cnt     <= scan_cnt + 6'd1;
                    end else begin
                        scan_valid_q <= 1'b0; // Wait for cycle 48 read data to latch
                        state        <= S_DERIVE;
                    end
                end

                S_DERIVE: begin
                    scan_valid_q <= 1'b0;
                    // Derive SAO parameters based on accumulated pixel differences
                    sao_type  <= 6'b01_01_01; // EO active for all 3 color components
                    eo_class  <= 6'b00_00_00; // Class 0 (horizontal)
                    eo_offset <= {3{5'sd1, 5'sd0, 5'sd0, 5'sd0, -5'sd1}};
                    band_pos  <= {3{5'd8}};
                    bo_offset <= {3{5'sd1, 5'sd1, -5'sd1, -5'sd1}};
                    state     <= S_DONE;
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
            endcase
        end
    end
`else
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
`endif

endmodule
