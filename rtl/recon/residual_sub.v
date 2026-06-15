`timescale 1ns / 1ps

module residual_sub #(
    parameter PIXEL_WIDTH = 10,   // 10-bit HEVC profile
    parameter RESIDUAL_WIDTH = 11 // 11-bit signed for 10-bit differences
)(
    input  wire                        clk,
    input  wire                        rst_n,

    // Control Flag
    input  wire                        is_intra,

    // Original pixel interface (from input_buffer)
    input  wire                        orig_valid,
    input  wire [PIXEL_WIDTH-1:0]      orig_pixel,

    // Intra prediction interface
    input  wire                        intra_pred_valid,
    input  wire [PIXEL_WIDTH-1:0]      intra_pred_pixel,
    input  wire [5:0]                  intra_pred_x,
    input  wire [5:0]                  intra_pred_y,

    // Inter prediction interface (from mc_unit)
    input  wire                        inter_pred_valid,
    input  wire [PIXEL_WIDTH-1:0]      inter_pred_pixel,
    input  wire [5:0]                  inter_pred_x,
    input  wire [5:0]                  inter_pred_y,

    // Output to Transform (dct_top)
    output reg                         res_valid,
    output reg signed [RESIDUAL_WIDTH-1:0] residual,
    output reg  [5:0]                  res_x,
    output reg  [5:0]                  res_y
);

    wire                       active_pred_valid;
    wire [PIXEL_WIDTH-1:0]     active_pred_pixel;

    // Multiplex between Intra and Inter prediction paths
    assign active_pred_valid = is_intra ? intra_pred_valid : inter_pred_valid;
    assign active_pred_pixel = is_intra ? intra_pred_pixel : inter_pred_pixel;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            res_valid <= 1'b0;
            residual  <= {RESIDUAL_WIDTH{1'b0}};
            res_x     <= 6'd0;
            res_y     <= 6'd0;
        end else begin
            // Synchronization: Valid only when both original and prediction data are ready
            res_valid <= orig_valid & active_pred_valid;
            if (orig_valid && active_pred_valid) begin
                residual <= $signed({1'b0, orig_pixel}) - $signed({1'b0, active_pred_pixel});
                res_x    <= is_intra ? intra_pred_x : inter_pred_x;
                res_y    <= is_intra ? intra_pred_y : inter_pred_y;
            end
        end
    end

endmodule