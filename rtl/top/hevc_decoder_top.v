`timescale 1ns / 1ps
//=============================================================================
// hevc_decoder_top.v
// Top-Level HEVC Main10 Random Access Decoder
//
// This module acts as the structural integration layer for the decoder 
// pipeline. It connects parsing (NAL/CABAC), reconstruction (IDCT/Prediction),
// in-loop filtering, and the Decoded Picture Buffer (DPB).
//=============================================================================

`include "parameter_pkg.vh"
`include "hevc_interfaces.vh"

module hevc_decoder_top (
    input  wire         clk,
    input  wire         rst_n,

    //-------------------------------------------------------------------------
    // Bitstream Input Interface
    //-------------------------------------------------------------------------
    input  wire         bs_valid,
    output wire         bs_ready,
    input  wire [7:0]   bs_byte,
    input  wire         bs_last,

    //-------------------------------------------------------------------------
    // YUV Output Interface (Decoded Display Order)
    //-------------------------------------------------------------------------
    output wire         out_valid,
    input  wire         out_ready,
    output wire [9:0]   out_pixel_y,
    output wire [9:0]   out_pixel_u,
    output wire [9:0]   out_pixel_v,
    output wire         out_frame_last,

    //-------------------------------------------------------------------------
    // AXI4 Master Interface (For DPB / Frame Store)
    //-------------------------------------------------------------------------
    output wire         axi_awvalid,
    input  wire         axi_awready,
    output wire [32:0]  axi_awaddr,
    output wire [7:0]   axi_awlen,
    output wire [2:0]   axi_awsize,
    output wire [1:0]   axi_awburst,
    output wire         axi_wvalid,
    input  wire         axi_wready,
    output wire [255:0] axi_wdata,
    output wire [31:0]  axi_wstrb,
    output wire         axi_wlast,
    input  wire         axi_bvalid,
    output wire         axi_bready,
    output wire         axi_arvalid,
    input  wire         axi_arready,
    output wire [32:0]  axi_araddr,
    output wire [7:0]   axi_arlen,
    output wire [2:0]   axi_arsize,
    output wire [1:0]   axi_arburst,
    input  wire         axi_rvalid,
    output wire         axi_rready,
    input  wire [255:0] axi_rdata,
    input  wire         axi_rlast
);

    //=========================================================================
    // Internal Wires & Connections
    //=========================================================================
    
    // NAL to CABAC
    wire        rbsp_valid;
    wire        rbsp_ready;
    wire [7:0]  rbsp_byte;
    wire        rbsp_last;
    
    // CABAC to Datapath
    wire [15:0] parsed_coeff;
    wire        parsed_coeff_valid;
    wire [2:0]  parsed_tu_size_log2;
    wire        parsed_is_intra;
    wire [5:0]  parsed_intra_mode;
    wire [1:0]  parsed_inter_dir;
    wire [11:0] parsed_mv_l0_x, parsed_mv_l0_y;
    wire [11:0] parsed_mv_l1_x, parsed_mv_l1_y;
    
    // IQ to IDCT
    wire        inv_quant_valid;
    wire signed [15:0] inv_quant_coeff;
    
    // IDCT to Recon
    wire        idct_valid;
    wire [16383:0] idct_data;
    
    // Prediction to Recon
    wire        pred_valid;
    wire [9:0]  pred_pixel;
    wire [5:0]  pred_x, pred_y;
    
    // Recon to Filters
    wire        recon_valid;
    wire [9:0]  recon_pixel;
    wire [5:0]  recon_x, recon_y;
    
    // Filters to DPB
    wire        filter_valid;
    wire [9:0]  filter_pixel;
    wire [11:0] filter_abs_x, filter_abs_y;
    
    //=========================================================================
    // 1. Bitstream Parsing
    //=========================================================================
    nal_parser u_nal_parser (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_valid   (bs_valid),
        .in_ready   (bs_ready),
        .in_byte    (bs_byte),
        .in_last    (bs_last),
        .out_valid  (rbsp_valid),
        .out_ready  (rbsp_ready),
        .out_byte   (rbsp_byte),
        .out_last   (rbsp_last)
    );
    
    cabac_dec_top u_cabac_dec (
        .clk              (clk),
        .rst_n            (rst_n),
        .rbsp_valid       (rbsp_valid),
        .rbsp_ready       (rbsp_ready),
        .rbsp_byte        (rbsp_byte),
        .rbsp_last        (rbsp_last),
        .slice_init       (1'b0),
        .slice_type       (2'd0),
        .slice_qp         (7'd32),
        
        // Output syntax
        .coeff_valid      (parsed_coeff_valid),
        .coeff_out        (parsed_coeff),
        .tu_size_log2     (parsed_tu_size_log2),
        .is_intra         (parsed_is_intra),
        .intra_mode       (parsed_intra_mode),
        .inter_dir        (parsed_inter_dir),
        .ref_idx_l0       (),
        .ref_idx_l1       (),
        .mvd_l0_x         (parsed_mv_l0_x),
        .mvd_l0_y         (parsed_mv_l0_y),
        .mvd_l1_x         (parsed_mv_l1_x),
        .mvd_l1_y         (parsed_mv_l1_y),
        .slice_done       ()
    );

    //=========================================================================
    // 2. Descaling & Inverse Transform (Reusing Encoder Modules)
    //=========================================================================
    inv_quant u_inv_quant (
        .clk              (clk),
        .rst_n            (rst_n),
        .qp               (6'd32), // Hardcoded for structural test
        .tu_comp          (2'd0),  // Default to Luma
        .tu_size_log2     (parsed_tu_size_log2),
        .in_valid         (parsed_coeff_valid),
        .in_ready         (),
        .in_level         (parsed_coeff),
        .in_scan_idx      (10'd0),
        .in_last          (1'b0),
        .out_valid        (inv_quant_valid),
        .out_ready        (1'b1),
        .out_coeff        (inv_quant_coeff),
        .out_scan_idx     (),
        .out_last         ()
    );

    // Flat scalar to 2D array mapping for IDCT
    wire [16383:0] iq_array;
    genvar gi, gj;
    generate
        for (gi = 0; gi < 32; gi = gi + 1) begin : gen_iq_row
            for (gj = 0; gj < 32; gj = gj + 1) begin : gen_iq_col
                assign iq_array[(gi*32+gj)*16 +: 16] = (gi == 0 && gj == 0) ? inv_quant_coeff : 16'd0;
            end
        end
    endgenerate

    dct_top u_idct_top (
        .clk              (clk),
        .rst_n            (rst_n),
        .fwd_inv_n        (1'b0), // Inverse Transform mode
        .tu_size_log2     (parsed_tu_size_log2),
        .in_valid         (inv_quant_valid),
        .in_ready         (),
        .in_data          (iq_array),
        .out_valid        (idct_valid),
        .out_ready        (1'b1),
        .out_data         (idct_data),
        .out_tu_size_log2 (),
        .out_fwd_inv_n    ()
    );

    //=========================================================================
    // 3. Prediction Generation
    //=========================================================================
    // PoC bypass: make pred_valid match idct_valid so recon_unit fires
    prediction_unit u_pred_unit (
        .clk              (clk),
        .rst_n            (rst_n),
        .is_intra         (parsed_is_intra),
        .intra_mode       (parsed_intra_mode),
        .inter_dir        (parsed_inter_dir),
        .mv_l0_x          (parsed_mv_l0_x),
        .mv_l0_y          (parsed_mv_l0_y),
        .mv_l1_x          (parsed_mv_l1_x),
        .mv_l1_y          (parsed_mv_l1_y),
        .pred_valid       (),
        .pred_pixel       (),
        .pred_x           (),
        .pred_y           ()
    );

    assign pred_valid = idct_valid;
    assign pred_pixel = 10'd512;
    assign pred_x = 6'd0;
    assign pred_y = 6'd0;

    //=========================================================================
    // 4. CTU Reconstruction
    //=========================================================================
    recon_unit u_recon_unit (
        .clk              (clk),
        .rst_n            (rst_n),
        .comp             (2'd0), 
        .pred_valid       (pred_valid),
        .pred_ready       (),
        .pred_pixel       (pred_pixel),
        .pred_x           (pred_x),
        .pred_y           (pred_y),
        .pred_last        (1'b0),
        .res_valid        (idct_valid),
        .res_ready        (),
        .res_coeff        (idct_data[15:0]),
        .res_x            (6'd0),
        .res_y            (6'd0),
        .res_last         (1'b0),
        .out_valid        (recon_valid),
        .out_ready        (1'b1),
        .out_pixel        (recon_pixel),
        .out_x            (recon_x),
        .out_y            (recon_y),
        .out_last         (),
        .out_comp         ()
    );

    //=========================================================================
    // 5. In-Loop Filters & Decoded Picture Buffer (DPB)
    //=========================================================================
    decoder_inloop_filters u_filters (
        .clk              (clk),
        .rst_n            (rst_n),
        .in_valid         (recon_valid),
        .in_pixel         (recon_pixel),
        .in_x             (recon_x),
        .in_y             (recon_y),
        .out_valid        (filter_valid),
        .out_pixel        (filter_pixel),
        .out_abs_x        (filter_abs_x),
        .out_abs_y        (filter_abs_y)
    );

    frame_store u_dpb (
        .clk              (clk),
        .rst_n            (rst_n),
        // Frame management (driven by decoder FSM in a real impl)
        .alloc_valid      (1'b0),
        .alloc_ready      (),
        .alloc_poc        (10'd0),
        .alloc_slot       (),
        .free_valid       (1'b0),
        .free_slot        (3'd0),
        .ref_l0           (),
        .ref_l1           (),
        .ref_l0_count     (),
        .ref_l1_count     (),
        
        // Write from Filters
        .wr_valid         (filter_valid),
        .wr_ready         (),
        .wr_pixel         (filter_pixel),
        .wr_x             (filter_abs_x),
        .wr_y             (filter_abs_y),
        .wr_comp          (2'd0),
        .wr_slot          (3'd0),
        .wr_last          (1'b0),
        
        .rd_req_valid     (1'b0),
        .rd_req_ready     (),
        .rd_slot          (3'd0),
        .rd_x             (13'd0),
        .rd_y             (13'd0),
        .rd_blk_w         (7'd0),
        .rd_blk_h         (7'd0),
        .rd_comp          (2'd0),
        .rd_resp_valid    (),
        .rd_resp_ready    (1'b1),
        .rd_resp_pixel    (),
        .rd_resp_last     (),
        
        // AXI4 Master
        .axi_awvalid      (axi_awvalid),
        .axi_awready      (axi_awready),
        .axi_awaddr       (axi_awaddr),
        .axi_awlen        (axi_awlen),
        .axi_awsize       (axi_awsize),
        .axi_awburst      (axi_awburst),
        .axi_wvalid       (axi_wvalid),
        .axi_wready       (axi_wready),
        .axi_wdata        (axi_wdata),
        .axi_wstrb        (axi_wstrb),
        .axi_wlast        (axi_wlast),
        .axi_bvalid       (axi_bvalid),
        .axi_bready       (axi_bready),
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

    // Connect Recon Output to Display Output
    assign out_valid = recon_valid;
    assign out_pixel_y = recon_pixel;
    assign out_pixel_u = 10'd0; // PoC
    assign out_pixel_v = 10'd0; // PoC
    assign out_frame_last = 1'b0;

endmodule
