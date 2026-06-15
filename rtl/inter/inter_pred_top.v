`timescale 1ns / 1ps
`include "parameter_pkg.vh"

module inter_pred_top #(
    parameter PIXEL_WIDTH  = `PIXEL_WIDTH,
    parameter CU_COORD_W   = 12,
    parameter MV_W         = 10,
    parameter MV_QP_W      = 14,
    parameter AXI_DW       = 256,
    parameter AXI_AW       = 33,
    parameter PX_Y         = PIXEL_WIDTH * 16,
    parameter PX_C         = PIXEL_WIDTH * 4
)(
    input  wire                        clk,
    input  wire                        rst_n,

    // Search input
    input  wire                        search_start,
    output wire                        search_ready,
    input  wire [PIXEL_WIDTH*16-1:0]   cu_orig_flat,
    input  wire [CU_COORD_W-1:0]       cu_x,
    input  wire [CU_COORD_W-1:0]       cu_y,
    input  wire signed [MV_W-1:0]      mvp_x,
    input  wire signed [MV_W-1:0]      mvp_y,
    
    // Search result
    output wire                        search_done,
    output wire signed [MV_W-1:0]      best_mv_x,
    output wire signed [MV_W-1:0]      best_mv_y,
    output wire [11:0]                 best_sad,
    
    // MC input
    input  wire                        mc_start,
    output wire                        mc_ready,
    input  wire signed [MV_QP_W-1:0]   mc_mv_x,
    input  wire signed [MV_QP_W-1:0]   mc_mv_y,
    
    // MC result
    output wire                        mc_done,
    output wire [PX_Y-1:0]             mc_pred_y_flat,
    output wire [PX_C-1:0]             mc_pred_cb_flat,
    output wire [PX_C-1:0]             mc_pred_cr_flat,

    // AXI Read Channel for ref_frame_buffer
    output wire                        axi_arvalid,
    input  wire                        axi_arready,
    output wire [AXI_AW-1:0]           axi_araddr,
    output wire [7:0]                  axi_arlen,
    output wire [2:0]                  axi_arsize,
    output wire [1:0]                  axi_arburst,
    input  wire                        axi_rvalid,
    output wire                        axi_rready,
    input  wire [AXI_DW-1:0]           axi_rdata,
    input  wire                        axi_rlast
);

    // =========================================================================
    // Ref Frame Buffer Request Multiplexer
    // =========================================================================
    wire tz_ref_req_valid;
    wire signed [11:0] tz_ref_req_x, tz_ref_req_y;
    
    wire mc_ref_req_valid;
    wire [1:0] mc_ref_req_comp;
    wire signed [11:0] mc_ref_req_x, mc_ref_req_y;
    
    wire ref_req_ready;
    wire ref_resp_valid;
    
    // Since tz_search and mc_unit run sequentially, we just OR them (only one is active)
    wire ref_req_valid = tz_ref_req_valid || mc_ref_req_valid;
    wire [1:0] ref_req_comp = mc_ref_req_valid ? mc_ref_req_comp : 2'd0; // tz_search only does Luma (0)
    wire [2:0] ref_req_slot = 3'd0; // Hardcoded slot 0 for now
    wire signed [11:0] ref_req_x = mc_ref_req_valid ? mc_ref_req_x : tz_ref_req_x;
    wire signed [11:0] ref_req_y = mc_ref_req_valid ? mc_ref_req_y : tz_ref_req_y;

    wire [1209:0] ref_resp_y_flat; // max ext flat
    wire [249:0]  ref_resp_cb_flat, ref_resp_cr_flat;

    // =========================================================================
    // Response Routing State
    // =========================================================================
    reg mc_active;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) mc_active <= 1'b0;
        else if (mc_start) mc_active <= 1'b1;
        else if (mc_done)  mc_active <= 1'b0;
    end

    wire [PIXEL_WIDTH*16-1:0] tz_ref_data_4x4;
    genvar r;
    generate
        for (r = 0; r < 4; r = r + 1) begin : ext_tz
            assign tz_ref_data_4x4[PIXEL_WIDTH*4*r +: PIXEL_WIDTH*4] = 
                   ref_resp_y_flat[PIXEL_WIDTH*11*r +: PIXEL_WIDTH*4];
        end
    endgenerate

    ref_frame_buffer u_ref_frame_buffer (
        .clk              (clk),
        .rst_n            (rst_n),
        .ref_req_valid    (ref_req_valid),
        .ref_req_ready    (ref_req_ready),
        .ref_req_comp     (ref_req_comp),
        .ref_req_slot     (ref_req_slot),
        .ref_req_x        (ref_req_x[11:0]),
        .ref_req_y        (ref_req_y[11:0]),
        
        .ref_resp_valid   (ref_resp_valid),
        .ref_resp_y_flat  (ref_resp_y_flat),
        .ref_resp_cb_flat (ref_resp_cb_flat),
        .ref_resp_cr_flat (ref_resp_cr_flat),
        
        .axi_arvalid      (axi_arvalid),
        .axi_arready      (axi_arready),
        .axi_araddr       (axi_araddr),
        .axi_arlen        (axi_arlen),
        .axi_arsize       (axi_arsize),
        .axi_arburst      (axi_arburst),
        .axi_rvalid       (axi_rvalid),
        .axi_rready       (axi_rready),
        .axi_rdata        (axi_rdata),
        .axi_rlast        (axi_rlast)
    );

    // =========================================================================
    // TZ Search (Motion Estimation)
    // =========================================================================
    tz_search u_tz_search (
        .clk              (clk),
        .rst_n            (rst_n),
        .search_valid     (search_start),
        .search_ready     (search_ready),
        .cu_orig_flat     (cu_orig_flat),
        .cu_x             (cu_x),
        .cu_y             (cu_y),
        .mvp_x            (mvp_x),
        .mvp_y            (mvp_y),
        
        .ref_req_valid    (tz_ref_req_valid),
        .ref_req_x        (tz_ref_req_x),
        .ref_req_y        (tz_ref_req_y),
        .ref_req_ready    (ref_req_ready),
        .ref_resp_valid   (ref_resp_valid && !mc_active), // Route response to TZ
        .ref_resp_data    (tz_ref_data_4x4), // TZ Search uses 4x4 flat
        
        .result_valid     (search_done),
        .best_mv_x        (best_mv_x),
        .best_mv_y        (best_mv_y),
        .best_sad         (best_sad)
    );

    // =========================================================================
    // MC Unit (Motion Compensation)
    // =========================================================================
    mc_unit u_mc_unit (
        .clk              (clk),
        .rst_n            (rst_n),
        .mc_start         (mc_start),
        .mc_ready         (mc_ready),
        .mc_ref_slot      (3'd0),
        .mc_cu_x          (cu_x),
        .mc_cu_y          (cu_y),
        .mc_mv_x          (mc_mv_x),
        .mc_mv_y          (mc_mv_y),
        
        .ref_req_valid    (mc_ref_req_valid),
        .ref_req_comp     (mc_ref_req_comp),
        .ref_req_slot     (),
        .ref_req_x        (mc_ref_req_x),
        .ref_req_y        (mc_ref_req_y),
        .ref_req_ready    (ref_req_ready),
        .ref_resp_valid   (ref_resp_valid && mc_active), // Route response to MC
        .ref_resp_y_flat  (ref_resp_y_flat),
        .ref_resp_cb_flat (ref_resp_cb_flat),
        .ref_resp_cr_flat (ref_resp_cr_flat),
        
        .mc_done          (mc_done),
        .pred_y_flat      (mc_pred_y_flat),
        .pred_cb_flat     (mc_pred_cb_flat),
        .pred_cr_flat     (mc_pred_cr_flat)
    );

endmodule
