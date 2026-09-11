`timescale 1ns / 1ps
//=============================================================================
// prediction_unit.v
// Prediction Unit (Intra + Inter Mux)
//
// Instantiates intra_pred_top and mc_unit, and routes their output
// to the reconstruction unit.
//=============================================================================

`include "parameter_pkg.vh"

module prediction_unit (
    input  wire         clk,
    input  wire         rst_n,

    // Control from parser
    input  wire         is_intra,
    input  wire [5:0]   intra_mode,
    input  wire [1:0]   inter_dir,
    input  wire signed [11:0] mv_l0_x,
    input  wire signed [11:0] mv_l0_y,
    input  wire signed [11:0] mv_l1_x,
    input  wire signed [11:0] mv_l1_y,

    // Output to Recon Unit
    output reg          pred_valid,
    output reg [`PIXEL_WIDTH-1:0] pred_pixel,
    output reg [5:0]    pred_x,
    output reg [5:0]    pred_y
);

    // =========================================================================
    // Intra Prediction
    // =========================================================================
    wire        intra_out_valid;
    wire [`PIXEL_WIDTH-1:0] intra_out_pixel;
    wire [5:0]  intra_out_x;
    wire [5:0]  intra_out_y;

    intra_pred_top u_intra (
        .clk(clk),
        .rst_n(rst_n),
        .pu_size_log2(3'd2), // 4x4
        .intra_mode(intra_mode),
        .is_luma(1'b1),
        
        .ref_valid(1'b0), // Tied off for structural PoC
        .ref_ready(),
        .ref_sample(10'd0),
        .ref_idx(8'd0),
        .ref_last(1'b0),
        
        .out_valid(intra_out_valid),
        .out_ready(1'b1),
        .out_pixel(intra_out_pixel),
        .out_x(intra_out_x),
        .out_y(intra_out_y),
        .out_last()
    );

    // =========================================================================
    // Inter Prediction
    // =========================================================================
    wire        mc_done;
    wire [159:0] pred_y_flat;

    mc_unit u_mc (
        .clk(clk),
        .rst_n(rst_n),
        .mc_start(1'b0), // Tied off for structural PoC
        .mc_ready(),
        .mc_ref_slot(3'd0),
        .mc_cu_x(12'd0),
        .mc_cu_y(12'd0),
        .mc_mv_x({mv_l0_x, 2'd0}), // convert to qpel
        .mc_mv_y({mv_l0_y, 2'd0}),
        
        .ref_req_valid(),
        .ref_req_comp(),
        .ref_req_slot(),
        .ref_req_x(),
        .ref_req_y(),
        .ref_resp_valid(1'b0),
        .ref_resp_y_flat(1210'd0),
        .ref_resp_cb_flat(250'd0),
        .ref_resp_cr_flat(250'd0),
        
        .mc_done(mc_done),
        .pred_y_flat(pred_y_flat),
        .pred_cb_flat(),
        .pred_cr_flat()
    );

    // =========================================================================
    // Simple PoC Mux & Pixel Streamer
    // =========================================================================
    // For the PoC, we just pass 0s to keep the pipeline moving if it's inter.
    // If it's intra, we pass the intra output (which will also be 0s since ref is tied).
    // This allows the structural integration to be proven.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pred_valid <= 1'b0;
            pred_pixel <= {`PIXEL_WIDTH{1'b0}};
            pred_x <= 6'd0;
            pred_y <= 6'd0;
        end else begin
            if (is_intra) begin
                pred_valid <= intra_out_valid;
                pred_pixel <= intra_out_pixel;
                pred_x <= intra_out_x;
                pred_y <= intra_out_y;
            end else begin
                // Just dummy valid out for Inter PoC
                pred_valid <= 1'b0; 
            end
        end
    end

endmodule
