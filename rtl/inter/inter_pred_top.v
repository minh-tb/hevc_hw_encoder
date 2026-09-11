`timescale 1ns / 1ps
`include "parameter_pkg.vh"

module inter_pred_top #(
    parameter PIXEL_WIDTH  = `PIXEL_WIDTH,
    parameter CU_COORD_W   = `FRAME_DIM_WIDTH,
    parameter MV_W         = `MV_TOTAL_BITS - `MV_FRAC_BITS,
    parameter MV_QP_W      = `MV_TOTAL_BITS,
    parameter AXI_DW       = 256,
    parameter AXI_AW       = 33,
    parameter PX_Y         = PIXEL_WIDTH * 16,
    parameter PX_C         = PIXEL_WIDTH * 4,
    parameter BLK_SIZE     = 4,
    parameter FRAME_W_Y    = 64,
    parameter FRAME_H_Y    = 64,
    parameter FRAME_W_C    = 32,
    parameter FRAME_H_C    = 32
)(
    input  wire                        clk,
    input  wire                        rst_n,

    // DPB reference slots
    input  wire [2:0]                  ref_slot_in,    // Default / L0 slot
    input  wire [2:0]                  ref_slot_l1,    // L1 slot for B-slices
    input  wire [1:0]                  inter_pred_idc, // 0=Pred_L0, 1=Pred_L1, 2=Pred_BI

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
    output wire signed [MV_QP_W-1:0]   best_mv_x,
    output wire signed [MV_QP_W-1:0]   best_mv_y,
    output wire [11:0]                 best_sad,
    
    // MC input
    input  wire                        mc_start,
    output wire                        mc_ready,
    input  wire signed [MV_QP_W-1:0]   mc_mv_x,        // L0 MV
    input  wire signed [MV_QP_W-1:0]   mc_mv_y,
    input  wire signed [MV_QP_W-1:0]   mc_mv_l1_x,     // L1 MV
    input  wire signed [MV_QP_W-1:0]   mc_mv_l1_y,
    
    // MC result
    output wire                        mc_done,
    output reg  [PX_Y-1:0]             mc_pred_y_flat,
    output reg  [PX_C-1:0]             mc_pred_cb_flat,
    output reg  [PX_C-1:0]             mc_pred_cr_flat,

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
    wire [2:0] mc_ref_req_slot;
    wire signed [11:0] mc_ref_req_x, mc_ref_req_y;
    
    wire ref_req_ready;
    wire ref_resp_valid;
    
    wire fme_ref_req_valid;
    wire signed [11:0] fme_ref_req_x, fme_ref_req_y;

    wire mc_ref_req_ready  = ref_req_ready;
    wire fme_ref_req_ready = ref_req_ready && !mc_ref_req_valid;
    wire tz_ref_req_ready  = ref_req_ready && !mc_ref_req_valid && !fme_ref_req_valid;

    wire [1:0] ref_req_comp = mc_ref_req_valid ? mc_ref_req_comp : 2'd0; // tz_search/fme only does Luma (0)
    reg  [2:0] sub_mc_slot;
    wire [2:0] ref_req_slot = mc_ref_req_valid ? mc_ref_req_slot : ref_slot_in; // From DPB ref_l0/ref_l1
    wire signed [11:0] ref_req_x = mc_ref_req_valid ? mc_ref_req_x : (fme_ref_req_valid ? fme_ref_req_x : tz_ref_req_x);
    wire signed [11:0] ref_req_y = mc_ref_req_valid ? mc_ref_req_y : (fme_ref_req_valid ? fme_ref_req_y : tz_ref_req_y);
    wire ref_req_valid_in = mc_ref_req_valid | fme_ref_req_valid | tz_ref_req_valid;

    wire [1439:0] ref_resp_y_flat; // 12x12
    wire [249:0]  ref_resp_cb_flat, ref_resp_cr_flat;

    // =========================================================================
    // Response Routing State (Client Tracking)
    // =========================================================================
    reg [1:0] active_client; // 0=TZ, 1=FME, 2=MC
    wire tz_done;
    wire fme_done;
    wire signed [MV_W-1:0] tz_best_mv_x;
    wire signed [MV_W-1:0] tz_best_mv_y;
    wire [11:0] tz_best_sad;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_client <= 2'd0;
        end else if (ref_req_valid_in && ref_req_ready) begin
            if (mc_ref_req_valid)       active_client <= 2'd2;
            else if (fme_ref_req_valid) active_client <= 2'd1;
            else                        active_client <= 2'd0;
        end
    end

    wire [PIXEL_WIDTH*16-1:0] tz_ref_data_4x4;
    genvar r;
    generate
        for (r = 0; r < 4; r = r + 1) begin : ext_tz
            assign tz_ref_data_4x4[PIXEL_WIDTH*4*r +: PIXEL_WIDTH*4] = 
                   ref_resp_y_flat[PIXEL_WIDTH*12*r +: PIXEL_WIDTH*4]; // 12x12 width
        end
    endgenerate

    ref_frame_buffer #(
        .FRAME_W_Y(FRAME_W_Y),
        .FRAME_H_Y(FRAME_H_Y),
        .FRAME_W_C(FRAME_W_C),
        .FRAME_H_C(FRAME_H_C),
        .LUMA_SAMPLES(FRAME_W_Y * FRAME_H_Y),
        .CHROMA_SAMPLES(FRAME_W_C * FRAME_H_C),
        .LUMA_WORDS(FRAME_W_Y * FRAME_H_Y / 2),
        .CHROMA_WORDS(FRAME_W_C * FRAME_H_C / 2),
        .FRAME_WORDS(FRAME_W_Y * FRAME_H_Y / 2 + FRAME_W_C * FRAME_H_C),
        .CB_OFFSET(FRAME_W_Y * FRAME_H_Y * 2),
        .CR_OFFSET(FRAME_W_Y * FRAME_H_Y * 2 + FRAME_W_C * FRAME_H_C * 2),
        .SLOT_STRIDE((FRAME_W_Y * FRAME_H_Y / 2 + FRAME_W_C * FRAME_H_C) * 4),
        .BLK_EXT_Y(12) // Override for FME
    ) u_ref_frame_buffer (
        .clk              (clk),
        .rst_n            (rst_n),
        .ref_req_valid    (ref_req_valid_in),
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
    tz_search #(
        .PIXEL_WIDTH      (PIXEL_WIDTH),
        .MV_W             (MV_W),
        .CU_COORD_W       (CU_COORD_W)
    ) u_tz_search (
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
        .ref_req_ready    (tz_ref_req_ready),
        .ref_resp_valid   (ref_resp_valid && (active_client == 2'd0)), // Route response to TZ
        .ref_resp_data    (tz_ref_data_4x4), // TZ Search uses 4x4 flat
        
        .result_valid     (tz_done),
        .best_mv_x        (tz_best_mv_x),
        .best_mv_y        (tz_best_mv_y),
        .best_sad         (tz_best_sad)
    );

    // =========================================================================
    // FME Search (Fractional Motion Estimation)
    // =========================================================================
    fme_search #(
        .PIXEL_WIDTH      (PIXEL_WIDTH),
        .CU_COORD_W       (CU_COORD_W),
        .MV_W             (MV_W),
        .BEST_SAD_W       (12),
        .MV_TOTAL_BITS    (MV_QP_W)
    ) u_fme_search (
        .clk              (clk),
        .rst_n            (rst_n),
        .fme_start        (tz_done),
        .fme_done         (fme_done),
        .cu_x             (cu_x),
        .cu_y             (cu_y),
        .cu_orig_flat     (cu_orig_flat),
        .tz_best_mv_x     (tz_best_mv_x),
        .tz_best_mv_y     (tz_best_mv_y),
        .tz_best_sad      (tz_best_sad),
        
        .ref_req_valid    (fme_ref_req_valid),
        .ref_req_x        (fme_ref_req_x),
        .ref_req_y        (fme_ref_req_y),
        .ref_req_ready    (fme_ref_req_ready),
        .ref_resp_valid   (ref_resp_valid && (active_client == 2'd1)),
        .ref_resp_y_flat  (ref_resp_y_flat),
        
        .fme_mv_x         (best_mv_x),
        .fme_mv_y         (best_mv_y),
        .fme_sad          (best_sad)
    );
    
    assign search_done = fme_done;

    // =========================================================================
    // MC Unit (Motion Compensation with Bi-Prediction Support)
    // =========================================================================
    wire [1209:0] mc_ref_resp_y_flat; // 11x11
    generate
        for (r = 0; r < 11; r = r + 1) begin : ext_mc
            assign mc_ref_resp_y_flat[PIXEL_WIDTH*11*r +: PIXEL_WIDTH*11] = 
                   ref_resp_y_flat[PIXEL_WIDTH*12*r +: PIXEL_WIDTH*11];
        end
    endgenerate

    // Bi-prediction Sequencer
    localparam [1:0]
        MC_S_IDLE = 2'd0,
        MC_S_L0   = 2'd1,
        MC_S_L1   = 2'd2,
        MC_S_DONE = 2'd3;

    reg [1:0] mc_state;
    reg       sub_mc_start;
    wire      sub_mc_ready, sub_mc_done;
    reg signed [MV_QP_W-1:0] sub_mc_mv_x, sub_mc_mv_y;
    wire [PX_Y-1:0] sub_pred_y;
    wire [PX_C-1:0] sub_pred_cb, sub_pred_cr;

    reg [PX_Y-1:0] l0_pred_y;
    reg [PX_C-1:0] l0_pred_cb, l0_pred_cr;
    reg            mc_done_r;

    assign mc_done  = mc_done_r;
    assign mc_ready = (mc_state == MC_S_IDLE);

    mc_unit #(
        .PIXEL_WIDTH      (PIXEL_WIDTH),
        .BLK_SIZE         (BLK_SIZE),
        .MV_QP_W          (MV_QP_W),
        .CU_COORD_W       (CU_COORD_W)
    ) u_mc_unit (
        .clk              (clk),
        .rst_n            (rst_n),
        .mc_start         (sub_mc_start),
        .mc_ready         (sub_mc_ready),
        .mc_ref_slot      (sub_mc_slot),
        .mc_cu_x          (cu_x),
        .mc_cu_y          (cu_y),
        .mc_mv_x          (sub_mc_mv_x),
        .mc_mv_y          (sub_mc_mv_y),
        
        .ref_req_valid    (mc_ref_req_valid),
        .ref_req_comp     (mc_ref_req_comp),
        .ref_req_slot     (mc_ref_req_slot),
        .ref_req_x        (mc_ref_req_x),
        .ref_req_y        (mc_ref_req_y),
        .ref_req_ready    (mc_ref_req_ready),
        .ref_resp_valid   (ref_resp_valid && (active_client == 2'd2)), // Route response to MC
        .ref_resp_y_flat  (mc_ref_resp_y_flat),
        .ref_resp_cb_flat (ref_resp_cb_flat),
        .ref_resp_cr_flat (ref_resp_cr_flat),
        
        .mc_done          (sub_mc_done),
        .pred_y_flat      (sub_pred_y),
        .pred_cb_flat     (sub_pred_cb),
        .pred_cr_flat     (sub_pred_cr)
    );

    integer pi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mc_state       <= MC_S_IDLE;
            sub_mc_start   <= 1'b0;
            sub_mc_slot    <= 3'd0;
            sub_mc_mv_x    <= 0;
            sub_mc_mv_y    <= 0;
            mc_done_r      <= 1'b0;
            mc_pred_y_flat <= 0;
            mc_pred_cb_flat<= 0;
            mc_pred_cr_flat<= 0;
            l0_pred_y      <= 0;
            l0_pred_cb     <= 0;
            l0_pred_cr     <= 0;
        end else begin
            case (mc_state)
                MC_S_IDLE: begin
                    mc_done_r <= 1'b0;
                    if (mc_start) begin
                        if (inter_pred_idc == 2'd1) begin // Pred_L1
                            sub_mc_start <= 1'b1;
                            sub_mc_slot  <= ref_slot_l1;
                            sub_mc_mv_x  <= mc_mv_l1_x;
                            sub_mc_mv_y  <= mc_mv_l1_y;
                            mc_state     <= MC_S_L1;
                        end else begin // Pred_L0 or Pred_BI (start with L0)
                            sub_mc_start <= 1'b1;
                            sub_mc_slot  <= ref_slot_in;
                            sub_mc_mv_x  <= mc_mv_x;
                            sub_mc_mv_y  <= mc_mv_y;
                            mc_state     <= MC_S_L0;
                        end
                    end
                end

                MC_S_L0: begin
                    sub_mc_start <= 1'b0;
                    if (sub_mc_done) begin
                        if (inter_pred_idc == 2'd2) begin // Pred_BI -> Proceed to L1
                            l0_pred_y    <= sub_pred_y;
                            l0_pred_cb   <= sub_pred_cb;
                            l0_pred_cr   <= sub_pred_cr;
                            sub_mc_start <= 1'b1;
                            sub_mc_slot  <= ref_slot_l1;
                            sub_mc_mv_x  <= mc_mv_l1_x;
                            sub_mc_mv_y  <= mc_mv_l1_y;
                            mc_state     <= MC_S_L1;
                        end else begin // Uni-pred L0 done
                            mc_pred_y_flat  <= sub_pred_y;
                            mc_pred_cb_flat <= sub_pred_cb;
                            mc_pred_cr_flat <= sub_pred_cr;
                            mc_done_r       <= 1'b1;
                            mc_state        <= MC_S_IDLE;
                        end
                    end
                end

                MC_S_L1: begin
                    sub_mc_start <= 1'b0;
                    if (sub_mc_done) begin
                        if (inter_pred_idc == 2'd2) begin // Pred_BI: Blend L0 + L1
                            for (pi = 0; pi < 16; pi = pi + 1) begin
                                mc_pred_y_flat[pi*PIXEL_WIDTH +: PIXEL_WIDTH] <= 
                                    (l0_pred_y[pi*PIXEL_WIDTH +: PIXEL_WIDTH] + sub_pred_y[pi*PIXEL_WIDTH +: PIXEL_WIDTH] + 1'b1) >> 1;
                            end
                            for (pi = 0; pi < 4; pi = pi + 1) begin
                                mc_pred_cb_flat[pi*PIXEL_WIDTH +: PIXEL_WIDTH] <= 
                                    (l0_pred_cb[pi*PIXEL_WIDTH +: PIXEL_WIDTH] + sub_pred_cb[pi*PIXEL_WIDTH +: PIXEL_WIDTH] + 1'b1) >> 1;
                                mc_pred_cr_flat[pi*PIXEL_WIDTH +: PIXEL_WIDTH] <= 
                                    (l0_pred_cr[pi*PIXEL_WIDTH +: PIXEL_WIDTH] + sub_pred_cr[pi*PIXEL_WIDTH +: PIXEL_WIDTH] + 1'b1) >> 1;
                            end
                        end else begin // Uni-pred L1
                            mc_pred_y_flat  <= sub_pred_y;
                            mc_pred_cb_flat <= sub_pred_cb;
                            mc_pred_cr_flat <= sub_pred_cr;
                        end
                        mc_done_r <= 1'b1;
                        mc_state  <= MC_S_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
