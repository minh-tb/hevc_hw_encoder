//=============================================================================
// inter_prediction.v
// Inter Prediction — Top-Level Wrapper for Datapath Integration
//
// Integrates all inter sub-modules into a single block:
//   - inter_pred_top      : TZ Search (Integer ME), MC Unit, Ref Frame Buffer
//   - mvp_predictor       : Spatial AMVP / Merge candidate generation
//   - mv_buffer_manager   : TMVP caching and collocated MV DDR flushing
//
// To simplify functional testing, this module exposes 3 separate AXI4 master
// interfaces. In a full SoC, an interconnect would arbitrate these.
//=============================================================================

`include "parameter_pkg.vh"
`include "hevc_interfaces.vh"

module inter_prediction (
    input  wire                                 clk,
    input  wire                                 rst_n,

    //=========================================================================
    // PORT A: CU / CTU Context (from ctu_partitioner / mode_decision)
    //=========================================================================
    input  wire                                 valid,
    input  wire [5:0]                           cu_x,
    input  wire [5:0]                           cu_y,
    input  wire [6:0]                           cu_size,
    input  wire                                 pred_mode,
    input  wire                                 ctu_start,
    input  wire                                 ctu_done,
    input  wire [`CTU_ADDR_WIDTH-1:0]           ctu_addr,
    input  wire [2:0]                           target_slot,
    input  wire [32:0]                          base_mv_addr,
    input  wire [32:0]                          col_base_mv_addr,

    //=========================================================================
    // PORT B: Neighbor Data (from Neighbor Buffer)
    //=========================================================================
    input  wire [4:0]                           nbr_inter,
    input  wire [(`MV_TOTAL_BITS-`MV_FRAC_BITS)*5-1:0] nbr_mv_x_flat,
    input  wire [(`MV_TOTAL_BITS-`MV_FRAC_BITS)*5-1:0] nbr_mv_y_flat,
    input  wire [19:0]                          nbr_ref_flat,   // 4 bits * 5
    
    //=========================================================================
    // PORT C: MVP / Merge Candidates (to Mode Decision)
    //=========================================================================
    input  wire [3:0]                           target_ref_idx,
    output wire                                 mvp_valid,
    output wire [(`MV_TOTAL_BITS-`MV_FRAC_BITS)*2-1:0] amvp_mv_x_flat,
    output wire [(`MV_TOTAL_BITS-`MV_FRAC_BITS)*2-1:0] amvp_mv_y_flat,
    output wire [4:0]                           merge_valid_bus,
    output wire [(`MV_TOTAL_BITS-`MV_FRAC_BITS)*5-1:0] merge_mv_x_flat,
    output wire [(`MV_TOTAL_BITS-`MV_FRAC_BITS)*5-1:0] merge_mv_y_flat,
    output wire [19:0]                          merge_ref_flat,

    //=========================================================================
    // PORT D: TMVP Outputs
    //=========================================================================
    output wire                                 col_prefetch_done,
    input  wire [3:0]                           col_lookup_idx,
    output wire [63:0]                          col_lookup_data,

    //=========================================================================
    // PORT E: Motion Estimation (from/to Mode Decision)
    //=========================================================================
    input  wire                                 search_start,
    output wire                                 search_ready,
    input  wire [`PIXEL_WIDTH*16-1:0]           cu_orig_flat,
    input  wire signed [`MV_TOTAL_BITS-1:0]     search_mvp_x,
    input  wire signed [`MV_TOTAL_BITS-1:0]     search_mvp_y,
    output wire                                 search_done,
    output wire signed [`MV_TOTAL_BITS-1:0]     best_mv_x,
    output wire signed [`MV_TOTAL_BITS-1:0]     best_mv_y,
    output wire [11:0]                          best_sad,

    //=========================================================================
    // PORT F: Motion Compensation (from Mode Decision / to Pred Mux)
    //=========================================================================
    input  wire                                 mc_start,
    output wire                                 mc_ready,
    input  wire [2:0]                           mc_ref_slot,
    input  wire signed [`MV_TOTAL_BITS-1:0]     mc_mv_x,
    input  wire signed [`MV_TOTAL_BITS-1:0]     mc_mv_y,
    output wire                                 mc_done,
    output wire [`PIXEL_WIDTH*16-1:0]           pred_y_flat,
    output wire [`PIXEL_WIDTH*4-1:0]            pred_cb_flat,
    output wire [`PIXEL_WIDTH*4-1:0]            pred_cr_flat,

    //=========================================================================
    // PORT G: AXI 1 - Ref Frame Read (Pixels)
    //=========================================================================
    output wire                                 axi_ref_arvalid,
    input  wire                                 axi_ref_arready,
    output wire [32:0]                          axi_ref_araddr,
    output wire [7:0]                           axi_ref_arlen,
    output wire [2:0]                           axi_ref_arsize,
    output wire [1:0]                           axi_ref_arburst,
    input  wire                                 axi_ref_rvalid,
    output wire                                 axi_ref_rready,
    input  wire [255:0]                         axi_ref_rdata,
    input  wire                                 axi_ref_rlast,

    //=========================================================================
    // PORT H: AXI 2 - MV Cache Read (TMVP Prefetch)
    //=========================================================================
    output wire                                 axi_mv_arvalid,
    input  wire                                 axi_mv_arready,
    output wire [32:0]                          axi_mv_araddr,
    output wire [7:0]                           axi_mv_arlen,
    input  wire                                 axi_mv_rvalid,
    output wire                                 axi_mv_rready,
    input  wire [255:0]                         axi_mv_rdata,
    input  wire                                 axi_mv_rlast,

    //=========================================================================
    // PORT I: AXI 3 - MV Cache Write (TMVP Flush)
    //=========================================================================
    output wire                                 axi_mv_awvalid,
    input  wire                                 axi_mv_awready,
    output wire [32:0]                          axi_mv_awaddr,
    output wire [7:0]                           axi_mv_awlen,
    output wire                                 axi_mv_wvalid,
    input  wire                                 axi_mv_wready,
    output wire [255:0]                         axi_mv_wdata,
    output wire                                 axi_mv_wlast,
    input  wire                                 axi_mv_bvalid
);

    //=========================================================================
    // 1. MVP / Merge Predictor
    //=========================================================================
    mvp_predictor #(
        .MV_W      (`MV_TOTAL_BITS - `MV_FRAC_BITS),
        .RIF_W     (4),
        .N_MERGE   (5),
        .N_NBR     (5)
    ) u_mvp_predictor (
        .clk             (clk),
        .rst_n           (rst_n),
        .valid_in        (valid),             // from CU_INFO_BUS
        .target_ref_idx  (target_ref_idx),
        .nbr_inter       (nbr_inter),
        .nbr_mv_x_flat   (nbr_mv_x_flat),
        .nbr_mv_y_flat   (nbr_mv_y_flat),
        .nbr_ref_flat    (nbr_ref_flat),
        .valid_out       (mvp_valid),
        .amvp_mv_x_flat  (amvp_mv_x_flat),
        .amvp_mv_y_flat  (amvp_mv_y_flat),
        .merge_valid     (merge_valid_bus),
        .merge_mv_x_flat (merge_mv_x_flat),
        .merge_mv_y_flat (merge_mv_y_flat),
        .merge_ref_flat  (merge_ref_flat)
    );

    //=========================================================================
    // 2. MV Buffer Manager (TMVP)
    //=========================================================================
    mv_buffer_manager #(
        .MV_W      (`MV_TOTAL_BITS - `MV_FRAC_BITS),
        .AXI_DW    (256)
    ) u_mv_buffer_manager (
        .clk               (clk),
        .rst_n             (rst_n),
        .cu_valid          (valid),           // from CU_INFO_BUS
        .cu_x              (cu_x),
        .cu_y              (cu_y),
        .cu_size           (cu_size),
        .is_intra          (pred_mode),       // PRED_INTRA=1
        .inter_mv_x        (mc_mv_x),
        .inter_mv_y        (mc_mv_y),
        .ref_idx_l0        (mc_ref_slot),
        .ref_idx_l1        (3'd0),            // uni-prediction only
        
        .ctu_done          (ctu_done),
        .ctu_addr          ({ {16-`CTU_ADDR_WIDTH{1'b0}}, ctu_addr }),
        .target_slot       (target_slot),
        .base_mv_addr      (base_mv_addr),
        
        // MV AXI Write
        .flush_req         (), // unused, grants immediately
        .flush_grant       (1'b1),
        .axi_awvalid       (axi_mv_awvalid),
        .axi_awready       (axi_mv_awready),
        .axi_awaddr        (axi_mv_awaddr),
        .axi_awlen         (axi_mv_awlen),
        .axi_wvalid        (axi_mv_wvalid),
        .axi_wready        (axi_mv_wready),
        .axi_wdata         (axi_mv_wdata),
        .axi_wlast         (axi_mv_wlast),
        .axi_bvalid        (axi_mv_bvalid),
        
        // TMVP Prefetch
        .ctu_start         (ctu_start),
        .col_base_mv_addr  (col_base_mv_addr),
        .col_prefetch_done (col_prefetch_done),
        .col_lookup_idx    (col_lookup_idx),
        .col_lookup_data   (col_lookup_data),
        
        // MV AXI Read
        .prefetch_req      (), // unused, grants immediately
        .prefetch_grant    (1'b1),
        .axi_arvalid       (axi_mv_arvalid),
        .axi_arready       (axi_mv_arready),
        .axi_araddr        (axi_mv_araddr),
        .axi_arlen         (axi_mv_arlen),
        .axi_rvalid        (axi_mv_rvalid),
        .axi_rready        (axi_mv_rready),
        .axi_rdata         (axi_mv_rdata),
        .axi_rlast         (axi_mv_rlast)
    );

    //=========================================================================
    // 3. Inter Prediction Top (ME / MC / Ref Buffer)
    //=========================================================================
    // Resize CU coordinates to fit FRAME_DIM_WIDTH
    wire [`FRAME_DIM_WIDTH-1:0] ext_cu_x = { {`FRAME_DIM_WIDTH-6{1'b0}}, cu_x };
    wire [`FRAME_DIM_WIDTH-1:0] ext_cu_y = { {`FRAME_DIM_WIDTH-6{1'b0}}, cu_y };

    inter_pred_top #(
        .PIXEL_WIDTH       (`PIXEL_WIDTH),
        .CU_COORD_W        (`FRAME_DIM_WIDTH),
        .MV_W              (`MV_TOTAL_BITS - `MV_FRAC_BITS),
        .MV_QP_W           (`MV_TOTAL_BITS),
        .AXI_DW            (256),
        .AXI_AW            (33),
        .FRAME_W_Y         (3840),
        .FRAME_H_Y         (2160),
        .FRAME_W_C         (1920),
        .FRAME_H_C         (1080)
    ) u_inter_pred_top (
        .clk               (clk),
        .rst_n             (rst_n),
        .ref_slot_in       (mc_ref_slot),
        
        // Search
        .search_start      (search_start),
        .search_ready      (search_ready),
        .cu_orig_flat      (cu_orig_flat),
        .cu_x              (ext_cu_x),
        .cu_y              (ext_cu_y),
        .mvp_x             (search_mvp_x[`MV_TOTAL_BITS-1:`MV_FRAC_BITS]), // Convert qpel to int-pel
        .mvp_y             (search_mvp_y[`MV_TOTAL_BITS-1:`MV_FRAC_BITS]),
        .search_done       (search_done),
        .best_mv_x         (best_mv_x),
        .best_mv_y         (best_mv_y),
        .best_sad          (best_sad),
        
        // MC
        .mc_start          (mc_start),
        .mc_ready          (mc_ready),
        .mc_mv_x           (mc_mv_x),
        .mc_mv_y           (mc_mv_y),
        .mc_done           (mc_done),
        .mc_pred_y_flat    (pred_y_flat),
        .mc_pred_cb_flat   (pred_cb_flat),
        .mc_pred_cr_flat   (pred_cr_flat),
        
        // Ref Buffer AXI Read
        .axi_arvalid       (axi_ref_arvalid),
        .axi_arready       (axi_ref_arready),
        .axi_araddr        (axi_ref_araddr),
        .axi_arlen         (axi_ref_arlen),
        .axi_arsize        (axi_ref_arsize),
        .axi_arburst       (axi_ref_arburst),
        .axi_rvalid        (axi_ref_rvalid),
        .axi_rready        (axi_ref_rready),
        .axi_rdata         (axi_ref_rdata),
        .axi_rlast         (axi_ref_rlast)
    );

endmodule
