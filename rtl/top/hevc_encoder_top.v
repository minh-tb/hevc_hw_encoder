`timescale 1ns / 1ps
//=============================================================================
// hevc_encoder_top.v
// Top-Level Integration for HEVC Hardware Encoder
//
// Wires all subsystems together based on the port connection map.
//=============================================================================

`include "parameter_pkg.vh"
`include "hevc_interfaces.vh"


module hevc_encoder_top (
    input  wire         clk,
    input  wire         rst_n,

    //=========================================================================
    // Host Control
    //=========================================================================
    input  wire         encode_start,
    input  wire [15:0]  total_frames,
    output wire         encode_done,

    //=========================================================================
    // Input Video Stream (YUV 4:2:0 10-bit)
    //=========================================================================
    input  wire         in_valid,
    output wire         in_ready,
    input  wire [9:0]   in_pixel_y,
    input  wire [9:0]   in_pixel_u,
    input  wire [9:0]   in_pixel_v,

    //=========================================================================
    // Output Bitstream (Annex B Byte Stream)
    //=========================================================================
    output wire         out_valid,
    input  wire         out_ready,
    output wire [7:0]   out_byte,

    //=========================================================================
    // External Memory Interface (AXI4 to DRAM for Ref Frames)
    // Write Address Channel
    output wire         axi_awvalid,
    input  wire         axi_awready,
    output wire [32:0]  axi_awaddr,
    output wire [7:0]   axi_awlen,
    output wire [2:0]   axi_awsize,
    output wire [1:0]   axi_awburst,
    // Write Data Channel
    output wire         axi_wvalid,
    input  wire         axi_wready,
    output wire [255:0] axi_wdata,
    output wire [31:0]  axi_wstrb,
    output wire         axi_wlast,
    // Write Response
    input  wire         axi_bvalid,
    output wire         axi_bready,
    // Read Address Channel
    output wire         axi_arvalid,
    input  wire         axi_arready,
    output wire [32:0]  axi_araddr,
    output wire [7:0]   axi_arlen,
    output wire [2:0]   axi_arsize,
    output wire [1:0]   axi_arburst,
    // Read Data Channel
    input  wire         axi_rvalid,
    output wire         axi_rready,
    input  wire [255:0] axi_rdata,
    input  wire         axi_rlast
);

    localparam SLICE_B = 2'd0;
    localparam SLICE_P = 2'd1;
    localparam SLICE_I = 2'd2;

    //=========================================================================
    // INTERNAL INTERCONNECT WIRES
    //=========================================================================

    //-------------------------------------------------------------------------
    // 1. Top-Level Control (GOP & Slice)
    //-------------------------------------------------------------------------
    wire        gop_frame_start;
    wire [9:0]  gop_frame_poc;
    wire [1:0]  gop_frame_slice_type;
    wire [2:0]  gop_temporal_id;
    wire [5:0]  gop_nal_type;
    wire        gop_frame_done;

    wire        alloc_valid;
    wire        alloc_ready;
    wire [9:0]  alloc_poc;
    wire [2:0]  alloc_slot;

    wire        free_valid;
    wire [2:0]  free_slot;

    wire [14:0] ref_l0;
    wire [14:0] ref_l1;
    wire [2:0]  ref_l0_count;
    wire [2:0]  ref_l1_count;

    wire        ctu_frame_start;
    wire        ctu_frame_done;
    
    wire        nal_start;
    wire [5:0]  nal_type;
    wire [2:0]  nal_temporal_id;
    wire        nal_end;

    wire        rbsp_valid;
    wire        rbsp_ready;
    wire [7:0]  rbsp_byte;
    wire        rbsp_last;

    //-------------------------------------------------------------------------
    // 2. Partitioning Pipeline (Raster -> Partitioner -> Splitter)
    //-------------------------------------------------------------------------
    wire        ctu_valid;
    wire        ctu_ready;
    wire [15:0] ctu_addr;
    wire [9:0]  ctu_x;
    wire [9:0]  ctu_y;
    wire [9:0]  ctu_poc;
    wire [5:0]  ctu_qp;
    wire [1:0]  ctu_slice_type;

    wire        cu_valid;
    wire        cu_ready;
    wire [5:0]  cu_x;
    wire [5:0]  cu_y;
    wire [6:0]  cu_size;
    wire [2:0]  cu_depth;
    wire [15:0] cu_ctu_addr;

    wire        split_valid;
    wire        split_flag;
    wire        split_ready;

    wire        pu_valid;
    wire [5:0]  pu_x;
    wire [5:0]  pu_y;
    wire        tu_ready_signal; // Explicit declaration

    wire        tu_valid;
    wire [5:0]  tu_x;
    wire [5:0]  tu_y;
    wire [2:0]  tu_size_log2;
    wire        tu_is_last_in_cu;
    wire [1:0]  tu_comp;

    //-------------------------------------------------------------------------
    // 3. Prediction & Mode Decision
    //-------------------------------------------------------------------------
    wire        tz_search_valid;
    wire [9:0]  tz_best_mv_x;
    wire [9:0]  tz_best_mv_y;

    wire        mc_start;
    wire        mc_done;
    wire [9:0]  mc_mv_x;
    wire [9:0]  mc_mv_y;
    wire [159:0] mc_pred_y_flat;

    wire        intra_pred_valid;
    wire [9:0]  intra_pred_pixel;
    wire [9:0]  intra_pred_x;
    wire [9:0]  intra_pred_y;

    wire        amvp_mv_x_flat;
    wire        amvp_mv_y_flat;

    // Forward declarations
    wire [5:0]  intra_out_x;
    wire [5:0]  intra_out_y;
    wire        intra_out_last;
    wire [9:0]  inter_out_x;
    wire [9:0]  inter_out_y;
    wire        inter_out_last;
    wire        inter_pred_valid;
    wire [9:0]  inter_pred_pixel;
    wire        cabac_coeff_done;
    wire        cabac_cu_done;
    wire        master_cu_ready;
    // FSM States for CABAC
    localparam CABAC_IDLE             = 3'd0;
    localparam CABAC_WAIT_CU_DONE     = 3'd1;
    localparam CABAC_WAIT_PRED        = 3'd2;
    localparam CABAC_WAIT_PRED_DONE   = 3'd7;
    localparam CABAC_WAIT_COEFF       = 3'd3;
    localparam CABAC_TRM_CTU          = 3'd4;
    localparam CABAC_WAIT_COEFF_DONE  = 3'd5;
    localparam CABAC_TRM_SLICE        = 3'd6;
    localparam CABAC_FLUSH            = 3'd7;
    
    reg [2:0] cabac_state;
    wire cabac_ctx_init_busy;
    wire cabac_cu_ready = (cabac_state == CABAC_IDLE) && !cabac_ctx_init_busy;

    wire        cabac_pred_done;
    wire        cabac_enc_busy;

    //-------------------------------------------------------------------------
    // 4. Transform & Quantization
    //-------------------------------------------------------------------------
    wire        dct_in_valid;
    wire signed [15:0] dct_in_data [0:31][0:31];

    wire        dct_out_valid;
    wire signed [15:0] dct_out_data [0:31][0:31];
    wire [2:0]  dct_out_tu_size_log2;

    wire        quant_out_valid;
    wire [15:0] quant_out_level;
    wire [9:0]  quant_out_scan_idx;
    wire        quant_out_last;
    wire        quant_out_cbf;

    wire        inv_quant_out_valid;
    wire [15:0] inv_quant_out_coeff;

    wire        idct_out_valid;
    wire signed [15:0] idct_out_data [0:31][0:31];
    wire [9:0]  idct_out_x;
    wire [9:0]  idct_out_y;

    //-------------------------------------------------------------------------
    // 5. Residual Subtractor & Reconstruction
    //-------------------------------------------------------------------------
    wire        orig_valid;
    wire [9:0]  orig_pixel;
    wire        pred_valid;
    wire [9:0]  pred_pixel;
    wire [9:0]  pred_x;
    wire [9:0]  pred_y;

    wire [15:0] residual_data;
    
    wire        recon_out_valid;
    wire [9:0]  recon_out_pixel;
    wire [9:0]  recon_out_x;
    wire [9:0]  recon_out_y;
    wire [1:0]  recon_out_comp;

    //-------------------------------------------------------------------------
    // 6. Memory & Frame Store
    //-------------------------------------------------------------------------
    wire        cache_valid;
    wire [9:0]  cache_pixel;
    wire [9:0]  cache_x;
    wire [9:0]  cache_y;
    wire [1:0]  cache_comp;

    wire        ref_req_valid;
    wire [9:0]  ref_req_x;
    wire [9:0]  ref_req_y;
    wire [1:0]  ref_req_comp;
    wire        ref_resp_valid;
    wire [9:0]  ref_resp_data;

    // Memory Arbiter Signals
    wire         fs_arvalid;
    wire         fs_arready;
    wire [32:0]  fs_araddr;
    wire [7:0]   fs_arlen;
    wire [2:0]   fs_arsize;
    wire [1:0]   fs_arburst;
    wire         fs_rvalid;
    wire         fs_rready;
    wire [255:0] fs_rdata;
    wire         fs_rlast;

    //-------------------------------------------------------------------------
    // 7. In-Loop Filters (Deblock & SAO)
    //-------------------------------------------------------------------------
    wire        deblock_pix_rd_valid;
    wire [9:0]  deblock_pix_rd_x;
    wire [9:0]  deblock_pix_rd_y;
    wire        deblock_pix_wr_valid;
    wire [9:0]  deblock_pix_wr_data;
    wire [9:0]  deblock_pix_wr_x;
    wire [9:0]  deblock_pix_wr_y;
    wire        deblock_ctu_done;

    wire        sao_pix_rd_valid;
    wire [9:0]  sao_pix_rd_x;
    wire [9:0]  sao_pix_rd_y;
    wire        sao_pix_wr_valid;
    wire [9:0]  sao_pix_wr_data;
    wire [9:0]  sao_pix_wr_x;
    wire [9:0]  sao_pix_wr_y;

    //-------------------------------------------------------------------------
    // 8. Entropy & Output
    //-------------------------------------------------------------------------
    wire        cabac_out_valid;
    wire [7:0]  cabac_out_byte;
    wire        cabac_out_last_au;

    wire        fifo_rd_valid;
    wire [7:0]  fifo_rd_byte;
    wire        fifo_rd_last_au;


    //=========================================================================
    // INSTANTIATIONS
    //=========================================================================

    //-------------------------------------------------------------------------
    // Top-Level Control
    //-------------------------------------------------------------------------
    gop_controller u_gop_controller (
        .clk              (clk),
        .rst_n            (rst_n),
        .encode_start     (encode_start),
        .total_frames     (total_frames),
        .encode_done      (encode_done),
        .frame_start      (gop_frame_start),
        .frame_done       (gop_frame_done),
        .frame_poc        (gop_frame_poc),
        .frame_slice_type (gop_frame_slice_type),
        .temporal_id      (gop_temporal_id),
        .nal_type         (gop_nal_type),
        .alloc_valid      (alloc_valid),
        .alloc_ready      (alloc_ready),
        .alloc_poc        (alloc_poc),
        .alloc_slot       (alloc_slot),
        .free_valid       (free_valid),
        .free_slot        (free_slot),
        .ref_l0           (ref_l0),
        .ref_l1           (ref_l1),
        .ref_l0_count     (ref_l0_count),
        .ref_l1_count     (ref_l1_count)
    );

    wire cabac_flush_done;
    slice_controller u_slice_controller (
        .clk              (clk),
        .rst_n            (rst_n),
        .frame_start      (gop_frame_start),
        .frame_poc        (gop_frame_poc),
        .frame_slice_type (gop_frame_slice_type),
        .temporal_id      (gop_temporal_id),
        .nal_type         (gop_nal_type),
        .frame_done       (gop_frame_done),
        .ctu_frame_start  (ctu_frame_start),
        .ctu_frame_done   (cabac_flush_done),
        .nal_start        (nal_start),
        .out_nal_type     (nal_type),
        .out_temporal_id  (nal_temporal_id),
        .nal_end          (nal_end),
        .rbsp_valid       (rbsp_valid),
        .rbsp_ready       (rbsp_ready),
        .rbsp_byte        (rbsp_byte),
        .rbsp_last        (rbsp_last)
    );

    //-------------------------------------------------------------------------
    // Partitioning
    //-------------------------------------------------------------------------
    wire is_last_ctu;
    wire md_mode_valid;
    ctu_raster_scan #(
        .FRAME_WIDTH(64),
        .FRAME_HEIGHT(64)
    ) u_ctu_raster_scan (
        .clk              (clk),
        .rst_n            (rst_n),
        .frame_start      (ctu_frame_start),
        .frame_poc        (gop_frame_poc),
        .frame_slice_type (gop_frame_slice_type),
        .ctu_valid        (ctu_valid),
        .ctu_ready        (ctu_ready),
        .ctu_addr         (ctu_addr),
        .ctu_x            (ctu_x),
        .ctu_y            (ctu_y),
        .poc              (ctu_poc),
        .slice_type       (ctu_slice_type),
        .qp               (ctu_qp),
        .frame_width_px   (),
        .frame_height_px  (),
        .is_first_in_row  (),
        .is_last_in_row   (),
        .is_last_ctu      (is_last_ctu),
        .frame_active     (ctu_frame_active),
        .frame_done       (ctu_frame_done)
    );

    // Moved cabac_cu_ready down after cabac_state declaration
    wire pu_cu_splitter_cu_ready;
    wire leaf_cu_start = split_ready && (!split_flag || cu_depth == 2'd3);
    wire node_split_start = split_ready && split_flag && cu_depth < 2'd3;

    reg md_result_latched;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            md_result_latched <= 1'b0;
        end else begin
            if (master_cu_ready) md_result_latched <= 1'b0;
            else if (md_mode_valid) md_result_latched <= 1'b1;
        end
    end

    assign master_cu_ready = leaf_cu_start ? (pu_cu_splitter_cu_ready && cabac_cu_ready && (md_mode_valid || md_result_latched))
                                           : (pu_cu_splitter_cu_ready && cabac_cu_ready);
    wire trigger_cu = leaf_cu_start && master_cu_ready;

    ctu_partitioner u_ctu_partitioner (
        .clk              (clk),
        .rst_n            (rst_n),
        .ctu_valid        (ctu_valid),
        .ctu_ready        (ctu_ready),
        .cu_valid         (cu_valid),
        .cu_ready         (master_cu_ready), // Stalls until CABAC and splitter are ready
        .cu_x             (cu_x),
        .cu_y             (cu_y),
        .cu_size          (cu_size),
        .cu_depth         (cu_depth[1:0]),
        .cu_is_last_in_ctu(cu_is_last_in_ctu),
        .split_valid      (split_valid),
        .split_flag       (split_flag),
        .split_ready      (split_ready)
    );


    pu_cu_splitter u_pu_cu_splitter (
        .clk              (clk),
        .rst_n            (rst_n),
        .cu_valid         (trigger_cu), // Starts perfectly in sync with CABAC
        .cu_ready         (pu_cu_splitter_cu_ready),
        .cu_x             (cu_x[5:0]),
        .cu_y             (cu_y[5:0]),
        .cu_size          (cu_size),
        .cu_depth         (cu_depth[1:0]),
        .part_mode        (3'd0), // 2Nx2N
        .skip_flag        (1'b0),
        .pu_valid         (pu_valid),
        .pu_ready         (1'b1),
        .pu_x             (pu_x),
        .pu_y             (pu_y),
        .tu_split_fb_valid(1'b1),
        .tu_split_fb_flag (1'b0),
        .tu_split_fb_ready(),
        .tu_valid         (tu_valid),
        .tu_ready         (tu_ready_signal),
        .tu_x             (tu_x),
        .tu_y             (tu_y),
        .tu_size_log2     (tu_size_log2),
        .tu_comp          (tu_comp),
        .tu_is_last_in_cu (tu_is_last_in_cu)
    );

    wire        search_done;
    wire [9:0]  search_best_mv_x;
    wire [9:0]  search_best_mv_y;
    wire [11:0] search_best_sad;
    
    wire        md_best_is_intra;
    wire [5:0]  md_best_intra_mode;
    wire [11:0] md_best_inter_mv_x;
    wire [11:0] md_best_inter_mv_y;

    mode_decision u_mode_decision (
        .clk              (clk),
        .rst_n            (rst_n),
        .split_valid      (split_valid),
        .split_flag       (split_flag),
        .split_ready      (split_ready),
        .pu_valid         (cu_valid),
        .pu_size          (cu_size), // 7 bit
        .pu_depth         (cu_depth[1:0]),
        .slice_type       (ctu_slice_type),
        .qp               (ctu_qp),
        .poc              (ctu_poc),
        .intra_cost_valid (eval_intra_start), // loopback for structural
        .intra_rd_cost    ((ctu_slice_type == 2'd2) ? 32'd1000 : 32'h0FFFFFFF), // SLICE_I = 2'd2
        .intra_best_mode  (6'd0),
        .inter_cost_valid (search_done),      // From tz_search
        .inter_rd_cost    ({20'd0, search_best_sad}),
        .inter_best_mv_x  ({{2{search_best_mv_x[9]}}, search_best_mv_x}), // sign ext 10->12
        .inter_best_mv_y  ({{2{search_best_mv_y[9]}}, search_best_mv_y}), // sign ext 10->12
        .rate_cost_valid  (1'b0),
        .est_bit_rate     (32'd0),
        .eval_intra_start (eval_intra_start),
        .eval_inter_start (eval_inter_start),
        .mode_valid       (md_mode_valid),
        .best_rd_cost     (),
        .best_is_intra    (md_best_is_intra),
        .best_intra_mode  (md_best_intra_mode),
        .best_inter_mv_x  (md_best_inter_mv_x),
        .best_inter_mv_y  (md_best_inter_mv_y)
    );

    //-------------------------------------------------------------------------
    // Input Buffer & Subtractor
    //-------------------------------------------------------------------------
    // Stubbing input_buffer and residual_sub as they represent data path logic
    // which may be defined in modules not fully written yet, but mapped.
    // For now, tying them together functionally to complete the chain.

    //-------------------------------------------------------------------------
    // Input CTU Buffer for Inter Prediction (Original Pixels)
    //-------------------------------------------------------------------------
    // To make tz_search and residual structurally correct, we need access to the 
    // full original 64x64 block.
    reg [9:0] orig_y_ram [0:4095];
    reg [9:0] orig_u_ram [0:4095];
    reg [9:0] orig_v_ram [0:4095];
    reg [11:0] orig_write_ptr;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) orig_write_ptr <= 12'd0;
        else if (in_valid && in_ready) begin
            orig_y_ram[orig_write_ptr] <= in_pixel_y;
            orig_u_ram[orig_write_ptr] <= in_pixel_u;
            orig_v_ram[orig_write_ptr] <= in_pixel_v;
            orig_write_ptr <= orig_write_ptr + 12'd1;
        end else if (ctu_frame_done) begin
            orig_write_ptr <= 12'd0;
        end
    end

    assign orig_valid = in_valid;
    wire [5:0] active_pred_x = md_best_is_intra ? intra_out_x : inter_out_x[5:0];
    wire [5:0] active_pred_y = md_best_is_intra ? intra_out_y : inter_out_y[5:0];
    wire       active_pred_last = md_best_is_intra ? intra_out_last : inter_out_last;
    
    // TU Sequencer Registers
    reg         inter_p2s_active;
    reg [4:0]   inter_p2s_idx;
    reg         intra_ref_active;
    reg [6:0]   intra_ref_idx; // 0 to 64
    reg         tu_can_start;
    reg [5:0]   reg_tu_x;
    reg [5:0]   reg_tu_y;
    reg [2:0]   reg_tu_size_log2;
    reg [1:0]   reg_tu_comp;
    reg         reg_tu_is_last_in_cu;

    // FIX: Synchronous SRAM read for orig_ram to prevent combinational synthesis failure
    reg [9:0] orig_pixel_q;
    reg       pred_valid_q;
    reg [9:0] pred_pixel_q;
    reg [5:0] active_pred_x_q;
    reg [5:0] active_pred_y_q;
    reg       active_pred_last_q;
    reg       md_best_is_intra_q;

    always @(posedge clk) begin
        if (reg_tu_comp == 2'd0)
            orig_pixel_q <= orig_y_ram[{active_pred_y[5:0], active_pred_x[5:0]}];
        else if (reg_tu_comp == 2'd1)
            orig_pixel_q <= orig_u_ram[{active_pred_y[5:0], active_pred_x[5:0]}];
        else
            orig_pixel_q <= orig_v_ram[{active_pred_y[5:0], active_pred_x[5:0]}];
            
        pred_valid_q <= pred_valid;
        pred_pixel_q <= pred_pixel;
        active_pred_x_q <= active_pred_x;
        active_pred_y_q <= active_pred_y;
        active_pred_last_q <= active_pred_last;
        md_best_is_intra_q <= md_best_is_intra;
    end
    assign in_ready   = 1'b1;


    //-------------------------------------------------------------------------
    // 2D Residual Subtractor & Buffer
    //-------------------------------------------------------------------------
    // We must collect streaming predictions, subtract original pixels,
    // and pack them into a 32x32 array for the DCT module.
    wire        res_sub_valid;
    wire signed [10:0] res_sub_data; 
    wire [5:0]  res_sub_x;
    wire [5:0]  res_sub_y;

    residual_sub u_residual_sub (
        .clk              (clk),
        .rst_n            (rst_n),
        .is_intra         (md_best_is_intra_q),
        .orig_valid       (pred_valid_q),
        .orig_pixel       (orig_pixel_q),
        .intra_pred_valid (pred_valid_q && md_best_is_intra_q),
        .intra_pred_pixel (pred_pixel_q),
        .intra_pred_x     (active_pred_x_q),
        .intra_pred_y     (active_pred_y_q),
        .inter_pred_valid (pred_valid_q && !md_best_is_intra_q),
        .inter_pred_pixel (pred_pixel_q),
        .inter_pred_x     (active_pred_x_q),
        .inter_pred_y     (active_pred_y_q),
        .res_valid        (res_sub_valid),
        .residual         (res_sub_data),
        .res_x            (res_sub_x),
        .res_y            (res_sub_y)
    );

    reg signed [15:0] residual_buffer [0:31][0:31];
    reg               dct_start;
    
    integer r_i, r_j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dct_start <= 1'b0;
            for (r_i = 0; r_i < 32; r_i = r_i + 1) begin
                for (r_j = 0; r_j < 32; r_j = r_j + 1) begin
                    residual_buffer[r_i][r_j] <= 16'd0;
                end
            end
        end else begin
            if (res_sub_valid) begin
                residual_buffer[res_sub_y[4:0]][res_sub_x[4:0]] <= $signed(res_sub_data);
            end
            
            // Trigger DCT pipeline when the TU prediction block finishes
            dct_start <= (pred_valid_q && active_pred_last_q);
        end
    end

    assign dct_in_valid = dct_start;
    
    wire [16383:0] dct_in_data_flat;
    wire [16383:0] dct_out_data_flat;

    genvar gi, gj;
    generate
        for (gi = 0; gi < 32; gi = gi + 1) begin : gen_dct_in_row
            for (gj = 0; gj < 32; gj = gj + 1) begin : gen_dct_in_col
                assign dct_in_data[gi][gj] = residual_buffer[gi][gj];
                assign dct_in_data_flat[(gi*32+gj)*16 +: 16] = dct_in_data[gi][gj];
                assign dct_out_data[gi][gj] = dct_out_data_flat[(gi*32+gj)*16 +: 16];
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // Prediction Pipeline
    //-------------------------------------------------------------------------

    //-------------------------------------------------------------------------
    // Prediction Pipeline multiplexer
    //-------------------------------------------------------------------------
    assign pred_valid = md_best_is_intra ? intra_pred_valid : inter_pred_valid;
    assign pred_pixel = md_best_is_intra ? intra_pred_pixel : inter_pred_pixel;

    // Trigger mc_unit right after mode_decision asserts mode_valid and best is Inter
    assign mc_start = md_mode_valid && !md_best_is_intra;
    //-------------------------------------------------------------------------
    // TU Sequencer & Neighbor Buffer for Intra Prediction
    //-------------------------------------------------------------------------
    reg [9:0] recon_ram [0:4095]; // 64x64 CTU recon buffer
    
    always @(posedge clk) begin
        if (recon_out_valid) begin
            recon_ram[{recon_out_y[5:0], recon_out_x[5:0]}] <= recon_out_pixel;
        end
    end

    wire [6:0] intra_ref_max = (7'd1 << (reg_tu_size_log2 + 1)); // 2N
    wire [6:0] intra_ref_half = (7'd1 << reg_tu_size_log2);      // N

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            intra_ref_active <= 0;
            intra_ref_idx <= 0;
            tu_can_start <= 1'b1;
            reg_tu_x <= 0;
            reg_tu_y <= 0;
            reg_tu_size_log2 <= 0;
            reg_tu_comp <= 0;
            reg_tu_is_last_in_cu <= 0;
        end else begin
            if (tu_valid && tu_ready_signal) begin
                tu_can_start <= 1'b0;
                reg_tu_x <= tu_x;
                reg_tu_y <= tu_y;
                reg_tu_size_log2 <= tu_size_log2;
                reg_tu_comp <= tu_comp;
                reg_tu_is_last_in_cu <= tu_is_last_in_cu;
                if (md_best_is_intra) begin
                    intra_ref_active <= 1'b1;
                    intra_ref_idx <= 7'd0;
                end
            end else if (intra_ref_active) begin
                if (intra_ref_idx == intra_ref_max) begin
                    intra_ref_active <= 1'b0;
                end else begin
                    intra_ref_idx <= intra_ref_idx + 1;
                end
            end else if (inter_p2s_active) begin
                if (inter_p2s_idx == 5'd15) begin
                    tu_can_start <= 1'b1;
                end
            end else if (cabac_coeff_done || (cabac_cu_done && !md_best_is_intra)) begin
                tu_can_start <= 1'b1;
            end
        end
    end
    
    assign tu_ready_signal = tu_can_start && !intra_ref_active && !inter_p2s_active;
    
    // FIX: Synchronous SRAM read for recon_ram to prevent combinational synthesis failure
    reg [11:0] recon_rd_addr;
    always @(*) begin
        if (intra_ref_idx == 0) // Top-Left
            recon_rd_addr = {(reg_tu_y[5:0]-6'd1), (reg_tu_x[5:0]-6'd1)};
        else if (intra_ref_idx >= 1 && intra_ref_idx <= intra_ref_half) // Top
            recon_rd_addr = {(reg_tu_y[5:0]-6'd1), (reg_tu_x[5:0] + intra_ref_idx[5:0] - 6'd1)};
        else // Left
            recon_rd_addr = {(reg_tu_y[5:0] + intra_ref_idx[5:0] - intra_ref_half[5:0] - 6'd1), (reg_tu_x[5:0]-6'd1)};
    end

    wire recon_rd_valid = (intra_ref_idx == 0 && reg_tu_x > 0 && reg_tu_y > 0) ||
                          (intra_ref_idx >= 1 && intra_ref_idx <= intra_ref_half && reg_tu_y > 0) ||
                          (intra_ref_idx > intra_ref_half && reg_tu_x > 0);

    reg recon_rd_valid_q;
    reg [9:0] recon_ram_q;
    reg        intra_ref_active_q;
    reg [6:0]  intra_ref_idx_q;
    reg        intra_ref_last_q;

    always @(posedge clk) begin
        recon_ram_q <= recon_ram[recon_rd_addr];
        recon_rd_valid_q <= recon_rd_valid;
        intra_ref_active_q <= intra_ref_active;
        intra_ref_idx_q    <= intra_ref_idx;
        intra_ref_last_q   <= (intra_ref_idx == intra_ref_max);
    end
    
    wire [9:0] intra_ref_sample = recon_rd_valid_q ? recon_ram_q : 10'd512;

    //-------------------------------------------------------------------------
    // Inter Prediction Modules
    //-------------------------------------------------------------------------
    // For now we use the top-left (or (0,0)) as MVP.
    // MVP in integer-pel units
    wire signed [9:0] mvp_x = 10'd0;
    wire signed [9:0] mvp_y = 10'd0;
    
    // MC uses quarter-pel units (best_inter_mv_x/y from mode_decision * 4)
    // FIX: md_best_inter_mv is already quarter-pel. Sign-extend 12-bit to 14-bit without shifting.
    wire signed [13:0] mc_mv_x_qp = {{2{md_best_inter_mv_x[11]}}, md_best_inter_mv_x};
    wire signed [13:0] mc_mv_y_qp = {{2{md_best_inter_mv_y[11]}}, md_best_inter_mv_y};

    
    // AXI read channels for Inter Pred (to Arbiter)
    wire         ip_arvalid;
    wire         ip_arready;
    wire [32:0]  ip_araddr;
    wire [7:0]   ip_arlen;
    wire [2:0]   ip_arsize;
    wire [1:0]   ip_arburst;
    wire         ip_rvalid;
    wire         ip_rready;
    wire [255:0] ip_rdata;
    wire         ip_rlast;


    // Fetch 4x4 block for TZ search based on pu_x and pu_y
    wire [159:0] search_orig_flat;
    genvar sy, sx;
    generate
        for (sy = 0; sy < 4; sy = sy + 1) begin : gen_s_y
            for (sx = 0; sx < 4; sx = sx + 1) begin : gen_s_x
                assign search_orig_flat[(sy*4+sx)*10 +: 10] = orig_y_ram[{pu_y[5:0] + sy[5:0], pu_x[5:0] + sx[5:0]}];
            end
        end
    endgenerate

    wire [39:0] mc_pred_cb_flat;
    wire [39:0] mc_pred_cr_flat;

    inter_pred_top u_inter_pred (
        .clk              (clk),
        .rst_n            (rst_n),
        .search_start     (eval_inter_start),
        .search_ready     (),
        .cu_orig_flat     (search_orig_flat),
        .cu_x             ({6'd0, pu_x}),
        .cu_y             ({6'd0, pu_y}),
        .mvp_x            (mvp_x),
        .mvp_y            (mvp_y),
        .search_done      (search_done),
        .best_mv_x        (search_best_mv_x),
        .best_mv_y        (search_best_mv_y),
        .best_sad         (search_best_sad),
        
        .mc_start         (mc_start),
        .mc_ready         (),
        .mc_mv_x          (mc_mv_x_qp),
        .mc_mv_y          (mc_mv_y_qp),
        .mc_done          (mc_done),
        .mc_pred_y_flat   (mc_pred_y_flat),
        .mc_pred_cb_flat  (mc_pred_cb_flat),
        .mc_pred_cr_flat  (mc_pred_cr_flat),
        
        .axi_arvalid      (ip_arvalid),
        .axi_arready      (ip_arready),
        .axi_araddr       (ip_araddr),
        .axi_arlen        (ip_arlen),
        .axi_arsize       (ip_arsize),
        .axi_arburst      (ip_arburst),
        .axi_rvalid       (ip_rvalid),
        .axi_rready       (ip_rready),
        .axi_rdata        (ip_rdata),
        .axi_rlast        (ip_rlast)
    );

    // inter_pred_valid, inter_pred_pixel moved to top

    wire [159:0] active_mc_flat = (reg_tu_comp == 2'd0) ? mc_pred_y_flat :
                                  (reg_tu_comp == 2'd1) ? {120'd0, mc_pred_cb_flat} :
                                                          {120'd0, mc_pred_cr_flat};

    // P2S Sequencer dynamically maps Y, Cb, Cr flats from mc_unit to current TU processing sequence
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inter_p2s_active <= 0;
            inter_p2s_idx <= 0;
        end else begin
            if (tu_valid && tu_ready_signal && !md_best_is_intra) begin
                inter_p2s_active <= 1'b1;
                inter_p2s_idx <= 0;
            end else if (inter_p2s_active) begin
                if (inter_p2s_idx == 5'd15) begin
                    inter_p2s_active <= 1'b0;
                end else begin
                    inter_p2s_idx <= inter_p2s_idx + 1;
                end
            end
        end
    end

    assign inter_pred_valid = inter_p2s_active;
    
    reg [9:0] inter_pred_pixel_mux;
    always @(*) begin
        case (inter_p2s_idx[3:0])
            4'd0:  inter_pred_pixel_mux = active_mc_flat[9:0];
            4'd1:  inter_pred_pixel_mux = active_mc_flat[19:10];
            4'd2:  inter_pred_pixel_mux = active_mc_flat[29:20];
            4'd3:  inter_pred_pixel_mux = active_mc_flat[39:30];
            4'd4:  inter_pred_pixel_mux = active_mc_flat[49:40];
            4'd5:  inter_pred_pixel_mux = active_mc_flat[59:50];
            4'd6:  inter_pred_pixel_mux = active_mc_flat[69:60];
            4'd7:  inter_pred_pixel_mux = active_mc_flat[79:70];
            4'd8:  inter_pred_pixel_mux = active_mc_flat[89:80];
            4'd9:  inter_pred_pixel_mux = active_mc_flat[99:90];
            4'd10: inter_pred_pixel_mux = active_mc_flat[109:100];
            4'd11: inter_pred_pixel_mux = active_mc_flat[119:110];
            4'd12: inter_pred_pixel_mux = active_mc_flat[129:120];
            4'd13: inter_pred_pixel_mux = active_mc_flat[139:130];
            4'd14: inter_pred_pixel_mux = active_mc_flat[149:140];
            4'd15: inter_pred_pixel_mux = active_mc_flat[159:150];
        endcase
    end
    assign inter_pred_pixel = inter_pred_pixel_mux;
    assign inter_out_x = {4'd0, reg_tu_x} + {8'd0, inter_p2s_idx[1:0]};
    assign inter_out_y = {4'd0, reg_tu_y} + {8'd0, inter_p2s_idx[3:2]};
    assign inter_out_last = (inter_p2s_idx == 5'd15);

    wire        intra_out_valid;
    wire [9:0]  intra_out_pixel;
    // intra_out_x, etc moved to top
    wire        intra_out_ready;

    intra_pred_top u_intra_pred (
        .clk              (clk),
        .rst_n            (rst_n),
        .pu_size_log2     (reg_tu_size_log2),
        .intra_mode       (md_best_intra_mode), // Derived from Mode Decision
        .is_luma          (reg_tu_comp == 2'd0),
        
        .ref_valid        (intra_ref_active_q),
        .ref_ready        (),
        .ref_sample       (intra_ref_sample),
        .ref_idx          ({1'b0, intra_ref_idx_q}),
        .ref_last         (intra_ref_last_q),
        
        .out_valid        (intra_out_valid),
        .out_ready        (intra_out_ready),
        .out_pixel        (intra_out_pixel),
        .out_x            (intra_out_x),
        .out_y            (intra_out_y),
        .out_last         (intra_out_last)
    );

    assign intra_pred_valid = intra_out_valid;
    assign intra_pred_pixel = intra_out_pixel;

    //-------------------------------------------------------------------------
    // Transform & Quantization
    //-------------------------------------------------------------------------
    dct_top u_dct_top (
        .clk              (clk),
        .rst_n            (rst_n),
        .fwd_inv_n        (1'b1), // Forward DCT
        .tu_size_log2     (reg_tu_size_log2),
        .in_valid         (dct_in_valid),
        .in_ready         (),
        .in_data          (dct_in_data_flat),
        .out_valid        (dct_out_valid),
        .out_ready        (1'b1),
        .out_data         (dct_out_data_flat),
        .out_tu_size_log2 (dct_out_tu_size_log2),
        .out_fwd_inv_n    ()
    );

    //-------------------------------------------------------------------------
      // Parallel to Serial (P2S) Scanner via address_generator
      //-------------------------------------------------------------------------
      reg        p2s_active;
      reg  [9:0] p2s_idx;
      reg  [9:0] p2s_max;
      reg signed [15:0] p2s_coeff;
      
      wire [4:0] p2s_x, p2s_y;
      
      // Determine scan mode: 0=Diag (default). Future: Intra mode mapping
      wire [1:0] scan_mode = 2'd0; 
      
      address_generator u_addr_gen (
          .tu_size_log2 (dct_out_tu_size_log2),
          .scan_mode    (scan_mode),
          .scan_idx     (p2s_idx + 10'd1), // Look ahead 1 cycle for synchronous read
          .addr_x       (p2s_x),
          .addr_y       (p2s_y)
      );
  
      always @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
              p2s_active <= 0;
              p2s_idx <= 0;
              p2s_max <= 0;
              p2s_coeff <= 0;
          end else begin
              if (dct_out_valid) begin
                  p2s_active <= 1'b1;
                  p2s_idx <= 10'd0;
                  p2s_max <= (10'd1 << (dct_out_tu_size_log2 * 2)) - 10'd1;
                  p2s_coeff <= dct_out_data[0][0];
              end else if (p2s_active) begin
                  if (p2s_idx == p2s_max) begin
                      p2s_active <= 1'b0;
                  end else begin
                      p2s_idx <= p2s_idx + 10'd1;
                      p2s_coeff <= dct_out_data[p2s_y][p2s_x];
                  end
              end
          end
      end
    fwd_quant u_fwd_quant (
        .clk              (clk),
        .rst_n            (rst_n),
        .qp               (ctu_qp),
        .tu_size_log2     (dct_out_tu_size_log2),
        .is_intra         (ctu_slice_type == SLICE_I),
        .in_valid         (p2s_active),
        .in_ready         (),
        .in_coeff         (p2s_coeff), 
        .in_scan_idx      (p2s_idx),
        .in_last          (p2s_idx == p2s_max),
        .out_valid        (quant_out_valid),
        .out_ready        (1'b1),
        .out_level        (quant_out_level),
        .out_scan_idx     (quant_out_scan_idx),
        .out_last         (quant_out_last),
        .out_cbf          (quant_out_cbf)
    );

    //-------------------------------------------------------------------------
    // Reconstruction Loop
    //-------------------------------------------------------------------------
    wire [9:0] inv_quant_out_scan_idx;
    wire       inv_quant_out_last;

    inv_quant u_inv_quant (
        .clk              (clk),
        .rst_n            (rst_n),
        .qp               (ctu_qp),
        .tu_comp          (reg_tu_comp),
        .tu_size_log2     (dct_out_tu_size_log2),
        .in_valid         (quant_out_valid),
        .in_ready         (),
        .in_level         (quant_out_level),
        .in_scan_idx      (quant_out_scan_idx),
        .in_last          (quant_out_last),
        .out_valid        (inv_quant_out_valid),
        .out_ready        (1'b1),
        .out_coeff        (inv_quant_out_coeff),
        .out_scan_idx     (inv_quant_out_scan_idx),
        .out_last         (inv_quant_out_last)
    );

    //-------------------------------------------------------------------------
    // Serial to Parallel (S2P) Diagonal Scanner (4x4)
    //-------------------------------------------------------------------------
    reg signed [15:0] s2p_buffer [0:31][0:31];
    reg               idct_start;
    
    wire [4:0] s2p_x, s2p_y;
    address_generator u_s2p_addr_gen (
        .tu_size_log2 (dct_out_tu_size_log2),
        .scan_mode    (2'd0), // Diag
        .scan_idx     (inv_quant_out_scan_idx),
        .addr_x       (s2p_x),
        .addr_y       (s2p_y)
    );

    integer s_i, s_j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idct_start <= 1'b0;
            for (s_i = 0; s_i < 32; s_i = s_i + 1) begin
                for (s_j = 0; s_j < 32; s_j = s_j + 1) begin
                    s2p_buffer[s_i][s_j] <= 16'd0;
                end
            end
        end else begin
            if (inv_quant_out_valid) begin
                s2p_buffer[s2p_y][s2p_x] <= inv_quant_out_coeff;
            end
            
            // Trigger IDCT pipeline when the last coefficient is placed
            idct_start <= inv_quant_out_valid && inv_quant_out_last;
        end
    end

    wire [16383:0] idct_in_data_flat;
    wire [16383:0] idct_out_data_flat;

    wire signed [15:0] idct_in_data [0:31][0:31];
    generate
        for (gi = 0; gi < 32; gi = gi + 1) begin : gen_idct_in_row
            for (gj = 0; gj < 32; gj = gj + 1) begin : gen_idct_in_col
                assign idct_in_data[gi][gj] = s2p_buffer[gi][gj];
                assign idct_in_data_flat[(gi*32+gj)*16 +: 16] = idct_in_data[gi][gj];
                assign idct_out_data[gi][gj] = idct_out_data_flat[(gi*32+gj)*16 +: 16];
            end
        end
    endgenerate

    wire [2:0] idct_out_tu_size_log2;

    dct_top u_idct_top (
        .clk              (clk),
        .rst_n            (rst_n),
        .fwd_inv_n        (1'b0), // Inverse DCT
        .tu_size_log2     (dct_out_tu_size_log2),
        .in_valid         (idct_start),
        .in_ready         (),
        .in_data          (idct_in_data_flat),
        .out_valid        (idct_out_valid),
        .out_ready        (1'b1),
        .out_data         (idct_out_data_flat),
        .out_tu_size_log2 (idct_out_tu_size_log2),
        .out_fwd_inv_n    ()
    );
    //-------------------------------------------------------------------------
    // Parallel to Serial (P2S) Raster Scanner for Recon
    //-------------------------------------------------------------------------
    reg        idct_p2s_active;
    reg [9:0]  idct_p2s_idx;
    reg [9:0]  idct_p2s_max;
    reg [2:0]  idct_p2s_log2;
    reg signed [15:0] idct_p2s_coeff;
    
    wire [4:0] idct_p2s_x = (idct_p2s_log2 == 2) ? idct_p2s_idx[1:0] :
                            (idct_p2s_log2 == 3) ? idct_p2s_idx[2:0] :
                            (idct_p2s_log2 == 4) ? idct_p2s_idx[3:0] :
                            idct_p2s_idx[4:0];

    wire [4:0] idct_p2s_y = (idct_p2s_log2 == 2) ? idct_p2s_idx[3:2] :
                            (idct_p2s_log2 == 3) ? idct_p2s_idx[5:3] :
                            (idct_p2s_log2 == 4) ? idct_p2s_idx[7:4] :
                            idct_p2s_idx[9:5];

    wire [9:0] idct_p2s_idx_next = idct_p2s_idx + 1;
    wire [4:0] idct_p2s_x_next = (idct_p2s_log2 == 2) ? idct_p2s_idx_next[1:0] :
                                 (idct_p2s_log2 == 3) ? idct_p2s_idx_next[2:0] :
                                 (idct_p2s_log2 == 4) ? idct_p2s_idx_next[3:0] :
                                 idct_p2s_idx_next[4:0];
    wire [4:0] idct_p2s_y_next = (idct_p2s_log2 == 2) ? idct_p2s_idx_next[3:2] :
                                 (idct_p2s_log2 == 3) ? idct_p2s_idx_next[5:3] :
                                 (idct_p2s_log2 == 4) ? idct_p2s_idx_next[7:4] :
                                 idct_p2s_idx_next[9:5];

    wire       idct_p2s_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idct_p2s_active <= 0;
            idct_p2s_idx <= 0;
            idct_p2s_max <= 0;
            idct_p2s_log2 <= 0;
            idct_p2s_coeff <= 0;
        end else begin
            if (idct_out_valid) begin // Triggered when IDCT finishes
                idct_p2s_active <= 1'b1;
                idct_p2s_idx <= 10'd0;
                idct_p2s_max <= (10'd1 << (idct_out_tu_size_log2 * 2)) - 10'd1;
                idct_p2s_log2 <= idct_out_tu_size_log2;
                idct_p2s_coeff <= idct_out_data[0][0];
            end else if (idct_p2s_active && idct_p2s_ready) begin
                if (idct_p2s_idx == idct_p2s_max) begin
                    idct_p2s_active <= 1'b0;
                end else begin
                    idct_p2s_idx <= idct_p2s_idx + 10'd1;
                    idct_p2s_coeff <= idct_out_data[idct_p2s_y_next][idct_p2s_x_next];
                end
            end
        end
    end

    recon_unit u_recon_unit (
        .clk              (clk),
        .rst_n            (rst_n),
        .comp             (reg_tu_comp), // Fixed: Automatically routes reconstruction to active color plane
        .pred_valid       (pred_valid),
        .pred_ready       (intra_out_ready),
        .pred_pixel       (pred_pixel),
        .pred_x           (active_pred_x[5:0]), // Use active multiplexed coordinates (Inter & Intra safe)
        .pred_y           (active_pred_y[5:0]),
        .pred_last        (active_pred_last),
        
        .res_valid        (idct_p2s_active),
        .res_ready        (idct_p2s_ready),
        .res_coeff        (idct_p2s_coeff),
        .res_x_pu         (tu_x[5:0] + {1'b0, idct_p2s_x} - pu_x[5:0]),
        .res_y_pu         (tu_y[5:0] + {1'b0, idct_p2s_y} - pu_y[5:0]),
        .res_x_ctu        (tu_x + {1'b0, idct_p2s_x}),
        .res_y_ctu        (tu_y + {1'b0, idct_p2s_y}),
        .res_last         (idct_p2s_idx == idct_p2s_max),
        
        .out_valid        (recon_out_valid),
        .out_ready        (1'b1),
        .out_pixel        (recon_out_pixel),
        .out_x            (recon_out_x[5:0]),
        .out_y            (recon_out_y[5:0]),
        .out_last         (),
        .out_comp         (recon_out_comp)
    );

    //-------------------------------------------------------------------------
    // In-loop Filters & Memory Management
    //-------------------------------------------------------------------------
    wire        filter_out_valid;
    wire [9:0]  filter_out_pixel;
    wire [11:0] filter_out_x;
    wire [11:0] filter_out_y;
    
    // Delay CTU coordinates and comp to match the 1-cycle latency of the filter PoC
    reg [9:0] filter_ctu_x_delay;
    reg [9:0] filter_ctu_y_delay;
    reg [1:0] filter_comp_delay;
    always @(posedge clk) begin
        filter_ctu_x_delay <= ctu_x;
        filter_ctu_y_delay <= ctu_y;
        filter_comp_delay  <= recon_out_comp;
    end

    decoder_inloop_filters u_inloop_filters (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_valid   (recon_out_valid),
        .in_pixel   (recon_out_pixel),
        .in_x       (recon_out_x[5:0]),
        .in_y       (recon_out_y[5:0]),
        .out_valid  (filter_out_valid),
        .out_pixel  (filter_out_pixel),
        .out_abs_x  (filter_out_x),
        .out_abs_y  (filter_out_y)
    );

    // Frame coordinates translator (combining delayed CTU coords with Filter output)
    wire [11:0] frame_wr_x = {2'd0, filter_ctu_x_delay} + filter_out_x;
    wire [11:0] frame_wr_y = {2'd0, filter_ctu_y_delay} + filter_out_y;

    frame_store u_frame_store (
        .clk              (clk),
        .rst_n            (rst_n),
        .alloc_valid      (alloc_valid),
        .alloc_ready      (alloc_ready),
        .alloc_poc        (alloc_poc),
        .alloc_slot       (alloc_slot),
        .free_valid       (free_valid),
        .free_slot        (free_slot),
        .ref_l0           (ref_l0),
        .ref_l1           (ref_l1),
        .ref_l0_count     (ref_l0_count),
        .ref_l1_count     (ref_l1_count),
        
        .wr_valid         (filter_out_valid),
        .wr_ready         (),
        .wr_pixel         (filter_out_pixel),
        .wr_x             (frame_wr_x),
        .wr_y             (frame_wr_y),
        .wr_comp          (filter_comp_delay),
        .wr_slot          (3'd0),
        .wr_last          (ctu_frame_done),
        
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

        .cache_valid      (),
        .cache_pixel      (),
        .cache_x          (),
        .cache_y          (),
        .cache_comp       (),

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
        .axi_arvalid      (fs_arvalid),
        .axi_arready      (fs_arready),
        .axi_araddr       (fs_araddr),
        .axi_arlen        (fs_arlen),
        .axi_arsize       (fs_arsize),
        .axi_arburst      (fs_arburst),
        .axi_rvalid       (fs_rvalid),
        .axi_rready       (fs_rready),
        .axi_rdata        (fs_rdata),
        .axi_rlast        (fs_rlast)
    );

    // fs_arvalid etc moved to top
    axi_read_arbiter u_axi_read_arbiter (
        .clk              (clk),
        .rst_n            (rst_n),
        .p0_arvalid       (ip_arvalid),
        .p0_arready       (ip_arready),
        .p0_araddr        (ip_araddr),
        .p0_arlen         (ip_arlen),
        .p0_arsize        (ip_arsize),
        .p0_arburst       (ip_arburst),
        .p0_rvalid        (ip_rvalid),
        .p0_rready        (ip_rready),
        .p0_rdata         (ip_rdata),
        .p0_rlast         (ip_rlast),
        
        .p1_arvalid       (fs_arvalid),
        .p1_arready       (fs_arready),
        .p1_araddr        (fs_araddr),
        .p1_arlen         (fs_arlen),
        .p1_arsize        (fs_arsize),
        .p1_arburst       (fs_arburst),
        .p1_rvalid        (fs_rvalid),
        .p1_rready        (fs_rready),
        .p1_rdata         (fs_rdata),
        .p1_rlast         (fs_rlast),
        
        .m_arvalid        (axi_arvalid),
        .m_arready        (axi_arready),
        .m_araddr         (axi_araddr),
        .m_arlen          (axi_arlen),
        .m_arsize         (axi_arsize),
        .m_arburst        (axi_arburst),
        .m_rvalid         (axi_rvalid),
        .m_rready         (axi_rready),
        .m_rdata          (axi_rdata),
        .m_rlast          (axi_rlast)
    );

    //-------------------------------------------------------------------------
    // Entropy & Output
    //-------------------------------------------------------------------------
    //-------------------------------------------------------------------------
    // CABAC Sequencer & Coefficient Buffer (4x4)
    //-------------------------------------------------------------------------
    reg [255:0] coeff_flat_buf;
    reg         cabac_coeff_ready;
    reg         cu_cbf_latched;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cabac_coeff_ready <= 1'b0;
            coeff_flat_buf <= 256'd0;
            cu_cbf_latched <= 1'b0;
        end else begin
            if (quant_out_valid) begin
                case (quant_out_scan_idx[3:0])
                    4'd0:  coeff_flat_buf[15:0]    <= quant_out_level;
                    4'd1:  coeff_flat_buf[31:16]   <= quant_out_level;
                    4'd2:  coeff_flat_buf[47:32]   <= quant_out_level;
                    4'd3:  coeff_flat_buf[63:48]   <= quant_out_level;
                    4'd4:  coeff_flat_buf[79:64]   <= quant_out_level;
                    4'd5:  coeff_flat_buf[95:80]   <= quant_out_level;
                    4'd6:  coeff_flat_buf[111:96]  <= quant_out_level;
                    4'd7:  coeff_flat_buf[127:112] <= quant_out_level;
                    4'd8:  coeff_flat_buf[143:128] <= quant_out_level;
                    4'd9:  coeff_flat_buf[159:144] <= quant_out_level;
                    4'd10: coeff_flat_buf[175:160] <= quant_out_level;
                    4'd11: coeff_flat_buf[191:176] <= quant_out_level;
                    4'd12: coeff_flat_buf[207:192] <= quant_out_level;
                    4'd13: coeff_flat_buf[223:208] <= quant_out_level;
                    4'd14: coeff_flat_buf[239:224] <= quant_out_level;
                    4'd15: coeff_flat_buf[255:240] <= quant_out_level;
                endcase
            end
            
            if (trigger_cu) begin
                cabac_coeff_ready <= 1'b0; // Clear flag on new CU to prevent hazards from skipped blocks
                cu_cbf_latched <= 1'b0;
            end else if (cabac_state == CABAC_WAIT_COEFF_DONE) begin
                cabac_coeff_ready <= 1'b0;
                cu_cbf_latched <= quant_out_valid ? quant_out_cbf : 1'b0; // Clear for next TU, but preserve if next TU starts
            end else if (quant_out_valid) begin
                cu_cbf_latched <= cu_cbf_latched | quant_out_cbf;
            end
            
            if (quant_out_valid && quant_out_last) begin
                cabac_coeff_ready <= 1'b1;
                $display("Time=%0t: [HEVC_TOP] quant_out_valid && quant_out_last fired! Setting cabac_coeff_ready=1", $time);
            end
        end
    end

    // HEVC uses skip_flag=1 exclusively for Merge mode with no residual. 
    // Since TZ Search uses AMVP, we should encode skip_flag=0 and let CABAC 
    // dynamically evaluate the latched CBF at the TU level.
    wire current_cu_skip = 1'b0; 

    // =========================================================================
    // CABAC Engine FSM
    // Orchestrates CU/Prediction/Coeff coding
    // =========================================================================
    wire wire_cu_req = (cabac_state == CABAC_IDLE) && trigger_cu;
    wire wire_pred_req = (cabac_state == CABAC_WAIT_PRED);
    wire wire_coeff_req = (cabac_state == CABAC_WAIT_COEFF) && cabac_coeff_ready;

    reg cabac_cu_is_last_in_ctu;
    reg cabac_is_last_ctu;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cabac_cu_is_last_in_ctu <= 1'b0;
            cabac_is_last_ctu <= 1'b0;
        end else if (trigger_cu) begin
            cabac_cu_is_last_in_ctu <= cu_is_last_in_ctu;
            cabac_is_last_ctu <= is_last_ctu;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cabac_state <= CABAC_IDLE;
        end else begin
            case (cabac_state)
                CABAC_IDLE: begin
                    if (trigger_cu) begin
                        $display("Time=%0t: [HEVC_TOP] cabac_state: CABAC_IDLE -> CABAC_WAIT_CU_DONE", $time);
                        cabac_state <= CABAC_WAIT_CU_DONE; // Transition directly, wire handles the strobe
                    end
                end
                CABAC_WAIT_CU_DONE: begin
                    if (cabac_cu_done) begin
                    if (current_cu_skip) begin
                        if (cabac_cu_is_last_in_ctu && !cabac_is_last_ctu) cabac_state <= CABAC_TRM_CTU;
                        else cabac_state <= CABAC_IDLE;
                    end else begin
                        $display("Time=%0t: [HEVC_TOP] cabac_state: CABAC_WAIT_CU_DONE -> CABAC_WAIT_PRED", $time);
                        cabac_state <= CABAC_WAIT_PRED;
                    end
                    end
                end
                CABAC_WAIT_PRED: begin
                    $display("Time=%0t: [HEVC_TOP] cabac_state: CABAC_WAIT_PRED -> CABAC_WAIT_PRED_DONE", $time);
                    cabac_state <= CABAC_WAIT_PRED_DONE;
                end
                CABAC_WAIT_PRED_DONE: begin
                    if (cabac_pred_done) begin
                        $display("Time=%0t: [HEVC_TOP] cabac_state: CABAC_WAIT_PRED_DONE -> CABAC_WAIT_COEFF", $time);
                        cabac_state <= CABAC_WAIT_COEFF;
                    end
                end
                CABAC_WAIT_COEFF: begin
                    if (cabac_coeff_ready) begin
                        $display("Time=%0t: [HEVC_TOP] cabac_coeff_ready=1! CABAC_WAIT_COEFF -> CABAC_WAIT_COEFF_DONE", $time);
                        cabac_state <= CABAC_WAIT_COEFF_DONE; // Transition directly
                    end
                end
                CABAC_WAIT_COEFF_DONE: begin
                    if (cabac_coeff_done) begin
                    if (!reg_tu_is_last_in_cu) begin
                        cabac_state <= CABAC_WAIT_COEFF;
                    end else begin
                        if (cabac_cu_is_last_in_ctu && !cabac_is_last_ctu) cabac_state <= CABAC_TRM_CTU;
                        else cabac_state <= CABAC_IDLE;
                    end
                    end
                end
                CABAC_TRM_CTU: begin
                    if (!cabac_enc_busy) begin
                        cabac_state <= CABAC_IDLE;
                    end
                end
            endcase
        end
    end
    
    //-------------------------------------------------------------------------
    // CABAC Flush Timer
    // Wait for the pipeline to empty before flushing CABAC
    //-------------------------------------------------------------------------
    reg [1:0] cabac_flush_state;
    reg [7:0] cabac_idle_timer;
    reg       cabac_has_started;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cabac_flush_state <= 2'd0;
            cabac_idle_timer <= 8'd0;
            cabac_has_started <= 1'b0;
        end else begin
            if (gop_frame_start) begin
                cabac_flush_state <= 2'd0;
                cabac_idle_timer <= 8'd0;
                cabac_has_started <= 1'b0;
            end else begin

                if (ctu_frame_done) begin
                    if (cabac_flush_state == 2'd0)
                        cabac_flush_state <= 2'd1;
                end
                
                if (cabac_state != CABAC_IDLE) begin
                    cabac_has_started <= 1'b1;
                end

                if (!cabac_has_started || cabac_state != CABAC_IDLE || cabac_enc_busy) begin
                    cabac_idle_timer <= 8'd0;
                end else if (cabac_flush_state == 2'd1 || cabac_flush_state == 2'd2) begin
                    if (cabac_idle_timer < 8'd100) begin
                        cabac_idle_timer <= cabac_idle_timer + 8'd1;
                    end
                end

                if (cabac_flush_state == 2'd1 && cabac_idle_timer == 8'd99) begin
                    cabac_flush_state <= 2'd2;
                    cabac_idle_timer <= 8'd0;
                end else if (cabac_flush_state == 2'd2 && cabac_idle_timer == 8'd99) begin
                    cabac_flush_state <= 2'd3;
                    cabac_idle_timer <= 8'd0;
                end
            end
        end
    end

    wire frame_trm_pulse   = (cabac_flush_state == 2'd1 && cabac_idle_timer == 8'd99);
    wire ctu_trm_pulse     = (cabac_state == CABAC_TRM_CTU && !cabac_enc_busy);
    wire top_trm_req       = frame_trm_pulse || ctu_trm_pulse;
    wire top_trm_bin_val   = frame_trm_pulse; // 1 for end of slice, 0 for non-final CTU
    
    wire cabac_flush_pulse = (cabac_flush_state == 2'd2 && cabac_idle_timer == 8'd99);

    // synthesis translate_off
    always @(posedge clk) begin
        if (top_trm_req)       $display("Time=%0t: [HEVC_TOP] cabac_trm_pulse fired! bin=%b", $time, top_trm_bin_val);
        if (cabac_flush_pulse) $display("Time=%0t: [HEVC_TOP] cabac_flush_pulse fired!", $time);
    end
    // synthesis translate_on
    cabac_enc_top #(
        .CTX_ID_W(8)
    ) u_cabac_enc_top (
        .ctx_init_busy    (cabac_ctx_init_busy),
        .clk              (clk),
        .rst_n            (rst_n),
        .qp_in            (7'd32),
        .slice_init       (gop_frame_start),
        .slice_type       (gop_frame_slice_type),
        
        .cu_req           (wire_cu_req),
        .cu_done          (cabac_cu_done),
        .cu_is_split      (1'b0),
        .slice_is_intra   (ctu_slice_type == SLICE_I),
        .cu_skip          (current_cu_skip),
        .cu_depth         (2'd0),
        .cu_part_mode     (2'd0),
        .cu_merge         (1'b0),
        .cu_merge_idx     (3'd0),
        .cu_skip_ctx      (2'd0),
        .cu_pred_intra    (md_best_is_intra),
        .cu_cbf           (cu_cbf_latched),

        // Prediction syntax
        .pred_req         (wire_pred_req),
        .pred_done        (cabac_pred_done),
        .slice_is_b       (ctu_slice_type == SLICE_B),
        .inter_dir        (2'd1), // 1=L0, 2=L1, 3=Bi
        .ref_idx_l0       (3'd0),
        .mvp_flag_l0      (1'b0),
        // FIX: Calculate true MVD (MV - MVP) and remove erroneous 2'b00 shift
        .mvd_l0_x         (md_best_inter_mv_x - {{2{mvp_x[9]}}, mvp_x}),
        .mvd_l0_y         (md_best_inter_mv_y - {{2{mvp_y[9]}}, mvp_y}),
        .ref_idx_l1       (3'd0),
        .mvp_flag_l1      (1'b0),
        .mvd_l1_x         (12'd0),
        .mvd_l1_y         (12'd0),

        // Coeff syntax
        .coeff_req        (wire_coeff_req),
        .coeff_done       (cabac_coeff_done),
        .coeff_comp       (reg_tu_comp),
        .coeff_is_intra   (md_best_is_intra),
        .coeff_flat       (coeff_flat_buf),

        // Flush
        .trm_req          (top_trm_req),
        .trm_bin_val      (top_trm_bin_val),
        .flush_req        (cabac_flush_pulse),
        .flush_done       (cabac_flush_done),

        .byte_valid       (cabac_out_valid),
        .byte_out         (cabac_out_byte),
        .byte_ready       (rbsp_ready),

        .enc_busy         (cabac_enc_busy)
    );

    // Write slice payload (CABAC) to output stream
    // Or slice header (from slice_controller) to output stream.
    // nal_writer handles multiplexing RBSP from CABAC vs Header!
    nal_writer u_nal_writer (
        .clk              (clk),
        .rst_n            (rst_n),
        .nal_start        (nal_start),
        .nal_type         (nal_type),
        .temporal_id      (nal_temporal_id),
        .nal_end          (nal_end),
        .rbsp_valid       (rbsp_valid | cabac_out_valid),
        .rbsp_ready       (rbsp_ready),
        .rbsp_byte        (rbsp_valid ? rbsp_byte : cabac_out_byte),
        .rbsp_last        (rbsp_last),
        .out_valid        (out_valid),
        .out_ready        (out_ready),
        .out_byte         (out_byte),
        .out_last_in_nal  (),
        .nal_byte_count   (),
        .total_nal_count  ()
    );

endmodule
