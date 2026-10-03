`timescale 1ns / 1ps
//=============================================================================
// hevc_encoder_top.v
// Top-Level Integration for HEVC Hardware Encoder
//
// Wires all subsystems together based on the port connection map.
//=============================================================================

`include "parameter_pkg.vh"
`include "hevc_interfaces.vh"


module hevc_encoder_top #(
    parameter FRAME_WIDTH         = `DEFAULT_FRAME_WIDTH,
    parameter FRAME_HEIGHT        = `DEFAULT_FRAME_HEIGHT,
    parameter GOP_STRUCTURE       = `DEFAULT_GOP_STRUCTURE,  // 0: IPP, 1: IPBB (Low-Delay B), 2: Hierarchical B
    parameter [5:0]  BASE_QP      = `QP_DEFAULT,
    parameter        RC_ENABLE    = `RATE_CONTROL,
    parameter [15:0] TARGET_BITRATE_KBPS = `TARGET_BITRATE_DEFAULT
)(
    input  wire         clk,
    input  wire         rst_n,

    //=========================================================================
    // Host Control
    //=========================================================================
    input  wire         encode_start,
    input  wire [15:0]  total_frames,
    output wire         encode_done,

    //=========================================================================
    // Input Video Stream (YUV 4:2:0)
    //=========================================================================
    input  wire         in_valid,
    output wire         in_ready,
    input  wire [`PIXEL_WIDTH-1:0] in_pixel_y,
    input  wire [`PIXEL_WIDTH-1:0] in_pixel_u,
    input  wire [`PIXEL_WIDTH-1:0] in_pixel_v,

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
    // Defensive Elaboration Guards & Sanity Checks
    //=========================================================================
    initial begin
        // --- Tier 1 Range Validation ---
        if (BASE_QP > 6'd51) begin
            $fatal(1, "[CONFIG ERROR] BASE_QP (%0d) out of range [0..51]!", BASE_QP);
        end
        if (`PIXEL_WIDTH != 8 && `PIXEL_WIDTH != 10) begin
            $fatal(1, "[CONFIG ERROR] PIXEL_WIDTH (%0d) unsupported! Must be 8 or 10.", `PIXEL_WIDTH);
        end

        // --- Tier 2 Invariant Locks ---
        if (`CTU_SIZE != 64) begin
            $fatal(1, "[HARDWARE VIOLATION] CTU_SIZE is fixed to 64. Changing to %0d requires rebuilding partitioners, line buffers, and deblock SRAMs!", `CTU_SIZE);
        end
        if (`NUM_INTRA_MODES != 35) begin
            $fatal(1, "[SPEC VIOLATION] NUM_INTRA_MODES must be 35 per HEVC Clause 8.4.2.");
        end

        // --- Tier 3 ROM Enumeration Guard ---
        if (FRAME_WIDTH != 64 && FRAME_WIDTH != 128 && FRAME_WIDTH != 256 && FRAME_WIDTH != 1920 && FRAME_WIDTH != 3840) begin
            $fatal(1, "[ROM MISSING] FRAME_WIDTH %0d requires generating a corresponding SPS/VPS ROM in param_set_writer.v!", FRAME_WIDTH);
        end
        if (FRAME_HEIGHT != 64 && FRAME_HEIGHT != 128 && FRAME_HEIGHT != 256 && FRAME_HEIGHT != 1080 && FRAME_HEIGHT != 1088 && FRAME_HEIGHT != 2160) begin
            $fatal(1, "[ROM MISSING] FRAME_HEIGHT %0d requires generating a corresponding SPS/VPS ROM in param_set_writer.v!", FRAME_HEIGHT);
        end
    end

    //=========================================================================
    // INTERNAL INTERCONNECT WIRES
    //=========================================================================
    reg               idct_start;
    reg               idct_start_pre;
    reg               idct_active;

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

    // Latch the allocated slot at handshake time for stable write addressing
    reg [2:0]   latched_wr_slot;
    always @(posedge clk) begin
        if (!rst_n)
            latched_wr_slot <= 3'd0;
        else if (alloc_valid && alloc_ready)
            latched_wr_slot <= alloc_slot;
    end

    wire [14:0] ref_l0;
    wire [14:0] ref_l1;
    wire [2:0]  ref_l0_count;
    wire [2:0]  ref_l1_count;
    
    wire [`FRAME_DIM_WIDTH-1:0] frame_width_px;
    wire [`FRAME_DIM_WIDTH-1:0] frame_height_px;

    wire        ctu_frame_start;
    wire        ctu_frame_done;
    wire        ctu_frame_active;
    wire        cu_is_last_in_ctu;

    // Forward declaration — actual logic is after cabac_flush_done and filter_out_valid are declared
    wire sync_frame_done_pulse;

    
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
    wire        inloop_ctu_done;
    wire        ctu_valid;
    wire        ctu_partitioner_accepted;
    wire        ctu_ready = inloop_ctu_done;
    wire [`CTU_ADDR_WIDTH-1:0]  ctu_addr;
    wire [`CTU_COORD_WIDTH-1:0] ctu_x;
    wire [`CTU_COORD_WIDTH-1:0] ctu_y;
    wire [9:0]  ctu_poc;
    wire [5:0]  ctu_qp;
    wire [1:0]  ctu_slice_type;

    wire        cu_valid;
    wire        cu_ready;
    wire [5:0]  cu_x;
    wire [5:0]  cu_y;
    wire [6:0]  cu_size;
    wire [1:0]  cu_depth;
    wire [`CTU_ADDR_WIDTH-1:0] cu_ctu_addr;

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
    wire [`PIXEL_WIDTH-1:0] intra_pred_pixel;
    wire [9:0]  intra_pred_x;
    wire [9:0]  intra_pred_y;

    wire [19:0] amvp_mv_x_flat = 20'd0;
    wire [19:0] amvp_mv_y_flat = 20'd0;

    // Forward declarations
    wire [5:0]  intra_out_x;
    wire [5:0]  intra_out_y;
    wire        intra_out_last;
    wire [9:0]  inter_out_x;
    wire [9:0]  inter_out_y;
    wire        inter_out_last;
    wire        inter_pred_valid;
    wire [`PIXEL_WIDTH-1:0] inter_pred_pixel;
    wire        cabac_coeff_done;
    wire        cabac_cu_done;
    wire        master_cu_ready;
    // FSM States for CABAC
    localparam [3:0] CABAC_IDLE             = 4'd0;
    localparam [3:0] CABAC_WAIT_CU_DONE     = 4'd1;
    localparam [3:0] CABAC_WAIT_PRED        = 4'd2;
    localparam [3:0] CABAC_WAIT_PRED_DONE   = 4'd3;
    localparam [3:0] CABAC_WAIT_COEFF       = 4'd4;
    localparam [3:0] CABAC_TRM_CTU          = 4'd5;
    localparam [3:0] CABAC_WAIT_COEFF_DONE  = 4'd6;
    localparam [3:0] CABAC_TRM_SLICE        = 4'd7;
    localparam [3:0] CABAC_FLUSH            = 4'd8;
    
    reg [3:0] cabac_state;
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
    reg  signed [15:0] dct_out_hold [0:31][0:31]; // Latched copy for P2S scanner
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
    reg  signed [15:0] idct_out_hold [0:31][0:31]; // Latched copy for recon P2S scanner
    wire [9:0]  idct_out_x;
    wire [9:0]  idct_out_y;

    //-------------------------------------------------------------------------
    // 5. Residual Subtractor & Reconstruction
    //-------------------------------------------------------------------------
    wire        orig_valid;
    wire [`PIXEL_WIDTH-1:0] orig_pixel;
    wire        pred_valid;
    wire [`PIXEL_WIDTH-1:0] pred_pixel;
    wire [9:0]  pred_x;
    wire [9:0]  pred_y;

    wire [15:0] residual_data; // Debug: driven after idct_p2s_coeff is declared
    
    wire        recon_out_valid;
    wire [`PIXEL_WIDTH-1:0] recon_out_pixel;
    wire [5:0]  recon_out_x;
    wire [5:0]  recon_out_y;
    wire [1:0]  recon_out_comp;

    //-------------------------------------------------------------------------
    // 6. Memory & Frame Store
    //-------------------------------------------------------------------------
    wire        cache_valid;
    wire [`PIXEL_WIDTH-1:0] cache_pixel;
    wire [9:0]  cache_x;
    wire [9:0]  cache_y;
    wire [1:0]  cache_comp;

    wire        ref_req_valid;
    wire [9:0]  ref_req_x;
    wire [9:0]  ref_req_y;
    wire [1:0]  ref_req_comp;
    wire        ref_resp_valid;
    wire [`PIXEL_WIDTH-1:0] ref_resp_data;

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
    wire [`PIXEL_WIDTH-1:0] deblock_pix_wr_data;
    wire [9:0]  deblock_pix_wr_x;
    wire [9:0]  deblock_pix_wr_y;
    wire        deblock_ctu_done;

    wire        sao_pix_rd_valid;
    wire [9:0]  sao_pix_rd_x;
    wire [9:0]  sao_pix_rd_y;
    wire        sao_pix_wr_valid;
    wire [`PIXEL_WIDTH-1:0] sao_pix_wr_data;
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
    gop_controller #(
        .GOP_STRUCTURE    (GOP_STRUCTURE)
    ) u_gop_controller (
        .clk              (clk),
        .rst_n            (rst_n),
        .encode_start     (encode_start),
        .total_frames     (total_frames),
        .encode_done      (encode_done),
        .frame_start      (gop_frame_start),
        .frame_done       (sync_frame_done_pulse),
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
    wire slice_frame_done;
    wire [5:0]        rc_frame_qp;
    wire signed [6:0] rc_slice_qp_delta;
    wire [15:0]       rc_vbv_fullness;

    slice_controller #(
        .FRAME_WIDTH      (FRAME_WIDTH),
        .FRAME_HEIGHT     (FRAME_HEIGHT)
    ) u_slice_controller (
        .clk              (clk),
        .rst_n            (rst_n),
        .frame_start      (gop_frame_start),
        .frame_poc        (gop_frame_poc),
        .frame_slice_type (gop_frame_slice_type),
        .frame_qp         (rc_frame_qp),
        .temporal_id      (gop_temporal_id),
        .nal_type         (gop_nal_type),
        .frame_done       (slice_frame_done),
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
    // Rate Control Subsystem (CBR / VBV / Frame QP Adapter)
    //-------------------------------------------------------------------------
    reg [31:0] frame_bit_counter;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_bit_counter <= 32'd0;
        end else begin
            if (gop_frame_start) begin
                frame_bit_counter <= 32'd0;
            end else if (out_valid && out_ready) begin
                frame_bit_counter <= frame_bit_counter + 32'd8;
            end
        end
    end

    rate_controller u_rate_controller (
        .clk                 (clk),
        .rst_n               (rst_n),
        .rc_enable           (RC_ENABLE),
        .frame_start         (gop_frame_start),
        .frame_done          (sync_frame_done_pulse),
        .slice_type          (gop_frame_slice_type),
        .actual_frame_bits   (frame_bit_counter),
        .target_bitrate_kbps (TARGET_BITRATE_KBPS),
        .fps                 (8'd30),
        .base_qp             (BASE_QP),
        .frame_qp            (rc_frame_qp),
        .slice_qp_delta      (rc_slice_qp_delta),
        .vbv_fullness_pct    (rc_vbv_fullness)
    );

    //-------------------------------------------------------------------------
    // Partitioning
    //-------------------------------------------------------------------------
    wire is_last_ctu;
    wire md_mode_valid;
    // Forward declarations for deferred frame start (defined below with ctu_pixels_ready)
    reg frame_start_pending;
    reg deferred_frame_start;
    // Forward declarations for P2S scanners (defined below in DCT/IDCT P2S sections)
    reg p2s_active;
    reg idct_p2s_active;
    ctu_raster_scan #(
        .FRAME_WIDTH      (FRAME_WIDTH),
        .FRAME_HEIGHT     (FRAME_HEIGHT)
    ) u_ctu_raster_scan (
        .clk              (clk),
        .rst_n            (rst_n),
        .frame_start      (deferred_frame_start),
        .frame_poc        (gop_frame_poc),
        .frame_slice_type (gop_frame_slice_type),
        .frame_qp_in      (rc_frame_qp),
        .ctu_valid        (ctu_valid),
        .ctu_ready        (ctu_ready),
        .ctu_addr         (ctu_addr),
        .ctu_x            (ctu_x),
        .ctu_y            (ctu_y),
        .poc              (ctu_poc),
        .slice_type       (ctu_slice_type),
        .qp               (ctu_qp),
        .frame_width_px   (frame_width_px),
        .frame_height_px  (frame_height_px),
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
                           : node_split_start ? (cabac_cu_ready)
                           : 1'b0;
    wire trigger_cu = (leaf_cu_start || node_split_start) && master_cu_ready;
    wire trigger_leaf_cu = leaf_cu_start && master_cu_ready;

    // synthesis translate_off
    always @(posedge clk) begin
        if (trigger_cu)
            $display("Time=%0t: [TRIGGER_CU] leaf=%b node_split=%b cu_depth=%0d split_flag=%b cabac_ready=%b master_cu_ready=%b",
                     $time, leaf_cu_start, node_split_start, cu_depth, split_flag, cabac_cu_ready, master_cu_ready);
        if (split_ready && !trigger_cu)
            $display("Time=%0t: [SPLIT_READY_BLOCKED] leaf=%b node_split=%b cu_depth=%0d split_flag=%b cabac_ready=%b cabac_state=%0d",
                     $time, leaf_cu_start, node_split_start, cu_depth, split_flag, cabac_cu_ready, cabac_state);
    end
    // synthesis translate_on

    wire        md_best_is_intra;
    wire [5:0]  md_best_intra_mode;
    wire        md_best_skip_flag;
    wire        md_best_merge_flag;
    wire [2:0]  md_best_merge_idx;
    wire [11:0] md_best_inter_mv_x;
    wire [11:0] md_best_inter_mv_y;

    reg         md_latched_is_intra;
    reg [5:0]   md_latched_intra_mode;
    reg         md_latched_skip_flag;
    reg         md_latched_merge_flag;
    reg [2:0]   md_latched_merge_idx;
    reg [11:0]  md_latched_inter_mv_x;
    reg [11:0]  md_latched_inter_mv_y;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            md_latched_is_intra   <= 1'b1;
            md_latched_intra_mode <= 6'd0;
            md_latched_skip_flag  <= 1'b0;
            md_latched_merge_flag <= 1'b0;
            md_latched_merge_idx  <= 3'd0;
            md_latched_inter_mv_x <= 12'd0;
            md_latched_inter_mv_y <= 12'd0;
        end else if (md_mode_valid) begin
            md_latched_is_intra   <= md_best_is_intra;
            md_latched_intra_mode <= md_best_intra_mode;
            md_latched_skip_flag  <= md_best_skip_flag;
            md_latched_merge_flag <= md_best_merge_flag;
            md_latched_merge_idx  <= md_best_merge_idx;
            md_latched_inter_mv_x <= md_best_inter_mv_x;
            md_latched_inter_mv_y <= md_best_inter_mv_y;
        end
    end

    reg         latched_cu_is_split;
    reg [1:0]   latched_cu_depth;
    reg [1:0]   latched_cu_split_ctx;
    reg         latched_cu_is_intra;
    reg [5:0]   latched_cu_intra_mode;
    reg         latched_cu_skip;
    reg         latched_cu_merge;
    reg [2:0]   latched_cu_merge_idx;
    reg [11:0]  latched_cu_mv_x;
    reg [11:0]  latched_cu_mv_y;
    reg [5:0]   latched_cu_ctu_x;
    reg [5:0]   latched_cu_ctu_y;
    
    // Forward declaration of cu_split_ctx (derived below from ctu_depth_map)
    wire [1:0]  cu_split_ctx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            latched_cu_is_split   <= 1'b0;
            latched_cu_depth      <= 2'd0;
            latched_cu_split_ctx  <= 2'd0;
            latched_cu_is_intra   <= 1'b1;
            latched_cu_intra_mode <= 6'd0;
            latched_cu_skip       <= 1'b0;
            latched_cu_merge      <= 1'b0;
            latched_cu_merge_idx  <= 3'd0;
            latched_cu_mv_x       <= 12'd0;
            latched_cu_mv_y       <= 12'd0;
            latched_cu_ctu_x      <= 6'd0;
            latched_cu_ctu_y      <= 6'd0;
        end else if (trigger_cu) begin
            latched_cu_is_split   <= node_split_start;
            latched_cu_depth      <= cu_depth[1:0];
            latched_cu_split_ctx  <= cu_split_ctx;
            latched_cu_is_intra   <= md_best_is_intra;
            latched_cu_intra_mode <= md_best_intra_mode;
            latched_cu_skip       <= md_best_skip_flag;
            latched_cu_merge      <= md_best_merge_flag;
            latched_cu_merge_idx  <= md_best_merge_idx;
            latched_cu_mv_x       <= md_best_inter_mv_x;
            latched_cu_mv_y       <= md_best_inter_mv_y;
            latched_cu_ctu_x      <= ctu_x;
            latched_cu_ctu_y      <= ctu_y;
        end
    end

    reg  ctu_pixels_ready;
    wire inloop_ready;
    wire ctu_partitioner_ready;
    reg  ctu_partitioner_ready_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ctu_partitioner_ready_d <= 1'b1;
        else ctu_partitioner_ready_d <= ctu_partitioner_ready;
    end
    wire ctu_done_pulse = ctu_partitioner_ready && !ctu_partitioner_ready_d;
    reg  ctu_buffer_free;

    wire        cu_is_last_ctu;
    ctu_partitioner u_ctu_partitioner (
        .clk              (clk),
        .rst_n            (rst_n),
        .ctu_valid        (ctu_valid && ctu_pixels_ready),
        .ctu_ready        (ctu_partitioner_ready),
        .ctu_accepted     (ctu_partitioner_accepted),
        .ctu_is_last      (is_last_ctu),
        .cu_valid         (cu_valid),
        .cu_ready         (master_cu_ready), // Stalls until CABAC and splitter are ready
        .cu_x             (cu_x),
        .cu_y             (cu_y),
        .cu_size          (cu_size),
        .cu_depth         (cu_depth[1:0]),
        .cu_is_last_in_ctu(cu_is_last_in_ctu),
        .cu_is_last_ctu   (cu_is_last_ctu),
        .split_valid      (split_valid),
        .split_flag       (split_flag),
        .split_ready      (split_ready)
    );


    pu_cu_splitter u_pu_cu_splitter (
        .clk              (clk),
        .rst_n            (rst_n),
        .cu_valid         (trigger_leaf_cu), // Starts perfectly in sync with CABAC (leaf CUs only)
        .cu_ready         (pu_cu_splitter_cu_ready),
        .cu_x             (cu_x[5:0]),
        .cu_y             (cu_y[5:0]),
        .cu_size          (cu_size),
        .cu_depth         (cu_depth[1:0]),
        .part_mode        (3'd0), // 2Nx2N
        .skip_flag        (latched_cu_skip), // Feed skip decision to splitter
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
    wire [11:0] search_best_mv_x;
    wire [11:0] search_best_mv_y;
    wire [11:0] search_best_sad;
    
    wire [31:0] md_best_rd_cost;
    
    // Provide single zero-MV merge candidate (candidate 0) for P-slice merge/skip
    wire [4:0]  merge_valid_bus = 5'b00001;  // 1 valid candidate
    wire [49:0] merge_mv_x_flat = 50'd0;
    wire [49:0] merge_mv_y_flat = 50'd0;

    // Forward declarations for TU sequencer registers used in map update
    reg [5:0]   reg_tu_x;
    reg [5:0]   reg_tu_y;
    reg [1:0]   reg_tu_comp;

    // ---- CU map update generation for deblocking filter ----
    reg         map_update_valid_r;
    reg         map_update_cbf_only_r;
    reg [5:0]   map_update_x_r, map_update_y_r;
    reg [6:0]   map_update_size_r;
    reg [1:0]   map_update_comp_r;
    reg         map_update_pred_mode_r;
    reg         map_update_cbf_r;
    reg [5:0]   map_update_qp_r;
    reg [15:0]  map_update_mvx_r, map_update_mvy_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            map_update_valid_r     <= 1'b0;
            map_update_cbf_only_r  <= 1'b0;
            map_update_comp_r      <= 2'd0;
            map_update_cbf_r       <= 1'b0;
            map_update_x_r         <= 6'd0;
            map_update_y_r         <= 6'd0;
            map_update_size_r      <= 7'd0;
            map_update_pred_mode_r <= 1'b0;
            map_update_qp_r        <= 6'd0;
            map_update_mvx_r       <= 16'd0;
            map_update_mvy_r       <= 16'd0;
        end else begin
            map_update_valid_r <= 1'b0;
            if (md_mode_valid) begin
                map_update_valid_r     <= 1'b1;
                map_update_cbf_only_r  <= 1'b0;
                map_update_x_r         <= cu_x;
                map_update_y_r         <= cu_y;
                map_update_size_r      <= cu_size;
                map_update_comp_r      <= 2'd0;
                map_update_pred_mode_r <= md_best_is_intra;
                map_update_qp_r        <= ctu_qp;
                map_update_mvx_r       <= {{4{md_best_inter_mv_x[11]}}, md_best_inter_mv_x};
                map_update_mvy_r       <= {{4{md_best_inter_mv_y[11]}}, md_best_inter_mv_y};
                map_update_cbf_r       <= 1'b0;
            end else if (quant_out_valid && quant_out_last) begin
                map_update_valid_r     <= 1'b1;
                map_update_cbf_only_r  <= 1'b1;
                map_update_x_r         <= reg_tu_x;
                map_update_y_r         <= reg_tu_y;
                map_update_size_r      <= {4'd0, 3'd1} << dct_out_tu_size_log2;
                map_update_comp_r      <= reg_tu_comp;
                map_update_pred_mode_r <= latched_cu_is_intra;
                map_update_qp_r        <= ctu_qp;
                map_update_mvx_r       <= {{4{latched_cu_mv_x[11]}}, latched_cu_mv_x};
                map_update_mvy_r       <= {{4{latched_cu_mv_y[11]}}, latched_cu_mv_y};
                map_update_cbf_r       <= quant_out_cbf;
            end
        end
    end

    // Forward declarations for RMD outputs (used in mode_decision ports)
    wire        rmd_done;
    wire [5:0]  rmd_best_mode;
    wire [31:0] rmd_best_cost;
    wire        eval_intra_start;
    wire        eval_inter_start;

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
        .intra_cost_valid (rmd_done),
        .intra_rd_cost    (rmd_best_cost),
        .intra_best_mode  (rmd_best_mode),
        .inter_cost_valid (search_done),      // From tz_search
        // Scale 4x4 SAD to 64x64 CU area: multiply by (64/4)^2 = 256 = <<8
        .inter_rd_cost    ({12'd0, search_best_sad, 8'd0}),
        .inter_best_mv_x  (search_best_mv_x), // FME outputs 12-bit quarter-pel directly
        .inter_best_mv_y  (search_best_mv_y),
        
        .merge_cand_valid     (merge_valid_bus),
        .merge_cand_mv_x_flat (merge_mv_x_flat),
        .merge_cand_mv_y_flat (merge_mv_y_flat),
        
        .rate_cost_valid  (1'b0),
        .est_bit_rate     (32'd0),
        .eval_intra_start (eval_intra_start),
        .eval_inter_start (eval_inter_start),
        .mode_valid       (md_mode_valid),
        .best_rd_cost     (md_best_rd_cost),
        .best_is_intra    (md_best_is_intra),
        .best_intra_mode  (md_best_intra_mode),
        .best_inter_mv_x  (md_best_inter_mv_x),
        .best_inter_mv_y  (md_best_inter_mv_y),
        .best_merge_flag  (md_best_merge_flag),
        .best_merge_idx   (md_best_merge_idx),
        .best_skip_flag   (md_best_skip_flag)
    );

    //-------------------------------------------------------------------------
    // Intra Rough Mode Decision (RMD)
    //-------------------------------------------------------------------------
    wire [11:0] rmd_orig_rd_addr;
    wire        rmd_active;

    // Convert cu_size (pixel width: 8/16/32/64) to log2, capped at 5
    // Latched on cu_valid since cu_size goes X after cu_valid deasserts
    reg [2:0] rmd_pu_size_log2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rmd_pu_size_log2 <= 3'd5;
        end else if (cu_valid) begin
            case (cu_size)
                7'd8:    rmd_pu_size_log2 <= 3'd3;
                7'd16:   rmd_pu_size_log2 <= 3'd4;
                7'd32:   rmd_pu_size_log2 <= 3'd5;
                7'd64:   rmd_pu_size_log2 <= 3'd5; // cap at 5 (32x32 max TU)
                default: rmd_pu_size_log2 <= 3'd3;
            endcase
        end
    end

    // intra_rmd instance placed after ref sample pipeline declarations (see below)

    //-------------------------------------------------------------------------
    // Input Buffer & Subtractor
    //-------------------------------------------------------------------------
    // Input data path: Original pixels are stored in SRAMs and subtracted
    // from predicted pixels to produce residuals for transform/quantization.

    //-------------------------------------------------------------------------
    // Input CTU Buffer for Inter Prediction (Original Pixels)
    //-------------------------------------------------------------------------
    // To make tz_search and residual structurally correct, we need access to the 
    // full original 64x64 block for Luma and 32x32 for Chroma.
`ifdef SYNTHESIS
    (* ramstyle = "M10K, no_rw_check" *) reg [`PIXEL_WIDTH-1:0] orig_y_ram     [0:`CTU_LUMA_SAMPLES-1];
    (* ramstyle = "M10K, no_rw_check" *) reg [`PIXEL_WIDTH-1:0] orig_y_ram_rmd [0:`CTU_LUMA_SAMPLES-1];
    (* ramstyle = "M10K, no_rw_check" *) reg [`PIXEL_WIDTH-1:0] orig_u_ram     [0:`CTU_CB_SAMPLES-1];
    (* ramstyle = "M10K, no_rw_check" *) reg [`PIXEL_WIDTH-1:0] orig_v_ram     [0:`CTU_CR_SAMPLES-1];
    reg [11:0] orig_write_ptr;

    // Synchronous read from orig_y_ram_rmd for RMD (1-cycle latency)
    reg [`PIXEL_WIDTH-1:0] rmd_orig_data;
    always @(posedge clk) begin
        rmd_orig_data <= orig_y_ram_rmd[rmd_orig_rd_addr];
    end
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) orig_write_ptr <= 12'd0;
        else if (in_valid && in_ready) begin
            orig_y_ram[orig_write_ptr]     <= in_pixel_y;
            orig_y_ram_rmd[orig_write_ptr] <= in_pixel_y;
            orig_u_ram[{orig_write_ptr[11:7], orig_write_ptr[5:1]}] <= in_pixel_u;
            orig_v_ram[{orig_write_ptr[11:7], orig_write_ptr[5:1]}] <= in_pixel_v;
            orig_write_ptr <= orig_write_ptr + 12'd1;
        end else if (ctu_done_pulse || ctu_frame_done) begin
            orig_write_ptr <= 12'd0;
        end
    end
`else
    reg [`PIXEL_WIDTH-1:0] orig_y_ram [0:`CTU_LUMA_SAMPLES-1];
    reg [`PIXEL_WIDTH-1:0] orig_u_ram [0:`CTU_CB_SAMPLES-1];
    reg [`PIXEL_WIDTH-1:0] orig_v_ram [0:`CTU_CR_SAMPLES-1];
    reg [11:0] orig_write_ptr;

    // Synchronous read from orig_y_ram for RMD (1-cycle latency)
    reg [`PIXEL_WIDTH-1:0] rmd_orig_data;
    always @(posedge clk) begin
        rmd_orig_data <= orig_y_ram[rmd_orig_rd_addr];
    end
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) orig_write_ptr <= 12'd0;
        else if (in_valid && in_ready) begin
            orig_y_ram[orig_write_ptr] <= in_pixel_y;
            orig_u_ram[{orig_write_ptr[11:7], orig_write_ptr[5:1]}] <= in_pixel_u;
            orig_v_ram[{orig_write_ptr[11:7], orig_write_ptr[5:1]}] <= in_pixel_v;
            orig_write_ptr <= orig_write_ptr + 12'd1;
        end else if (ctu_done_pulse || ctu_frame_done) begin
            orig_write_ptr <= 12'd0;
        end
    end
`endif

    // Gate: CTU processing can only begin after all pixels are loaded
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ctu_pixels_ready <= 1'b0;
        else if (ctu_partitioner_accepted || ctu_done_pulse || ctu_frame_done) ctu_pixels_ready <= 1'b0;
        else if (in_valid && in_ready && orig_write_ptr == 12'd4095) ctu_pixels_ready <= 1'b1;
    end

    // Track when single-CTU buffer is occupied vs free for next CTU loading
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctu_buffer_free <= 1'b1;
        end else if (ctu_frame_start) begin
            ctu_buffer_free <= 1'b1;
        end else begin
            if (in_valid && in_ready && orig_write_ptr == 12'd4095)
                ctu_buffer_free <= 1'b0;
            if (inloop_ctu_done)
                ctu_buffer_free <= 1'b1;
        end
    end

    // Deferred frame start: hold the start pulse until pixels are loaded
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_start_pending <= 1'b0;
            deferred_frame_start <= 1'b0;
        end else begin
            deferred_frame_start <= 1'b0; // default: single-cycle pulse
            if (ctu_frame_start)
                frame_start_pending <= 1'b1;
            if (frame_start_pending && ctu_pixels_ready) begin
                deferred_frame_start <= 1'b1;
                frame_start_pending <= 1'b0;
            end
        end
    end

    assign orig_valid = in_valid;
    wire [5:0] active_pred_x = latched_cu_is_intra ? intra_out_x : inter_out_x[5:0];
    wire [5:0] active_pred_y = latched_cu_is_intra ? intra_out_y : inter_out_y[5:0];
    wire       active_pred_last = latched_cu_is_intra ? intra_out_last : inter_out_last;
    
    // TU Sequencer Registers
    reg         inter_p2s_active;
    reg [9:0]   inter_p2s_idx;
    reg         intra_ref_active;
    reg [7:0]   intra_ref_idx; // 0 to 4N (max 128)
    reg         tu_can_start;
    reg         mc_data_ready;
    reg [2:0]   reg_tu_size_log2;
    reg         reg_tu_is_last_in_cu;
    reg [5:0]   reg_pu_x;
    reg [5:0]   reg_pu_y;

    // FIX: Synchronous SRAM read for orig_ram to prevent combinational synthesis failure
    reg [9:0] orig_pixel_q;
    reg       pred_valid_q;
    reg [9:0] pred_pixel_q;
    reg [5:0] active_pred_x_q;
    reg [5:0] active_pred_y_q;
    reg       active_pred_last_q;
    reg       md_best_is_intra_q;

    // CTU-relative address for orig RAM: TU position + prediction coordinate
    wire [5:0] orig_res_rd_x = reg_tu_x + active_pred_x[5:0];
    wire [5:0] orig_res_rd_y = reg_tu_y + active_pred_y[5:0];

`ifdef SYNTHESIS
    reg [9:0] orig_y_data_q, orig_u_data_q, orig_v_data_q;
    always @(posedge clk) begin
        orig_y_data_q <= orig_y_ram[{orig_res_rd_y[5:0], orig_res_rd_x[5:0]}];
        orig_u_data_q <= orig_u_ram[{orig_res_rd_y[4:0], orig_res_rd_x[4:0]}];
        orig_v_data_q <= orig_v_ram[{orig_res_rd_y[4:0], orig_res_rd_x[4:0]}];
        orig_pixel_q  <= (reg_tu_comp == 2'd0) ? orig_y_data_q :
                         (reg_tu_comp == 2'd1) ? orig_u_data_q :
                                                 orig_v_data_q;
    end
`else
    always @(posedge clk) begin
        if (reg_tu_comp == 2'd0)
            orig_pixel_q <= orig_y_ram[{orig_res_rd_y[5:0], orig_res_rd_x[5:0]}];
        else if (reg_tu_comp == 2'd1)
            orig_pixel_q <= orig_u_ram[{orig_res_rd_y[4:0], orig_res_rd_x[4:0]}];
        else
            orig_pixel_q <= orig_v_ram[{orig_res_rd_y[4:0], orig_res_rd_x[4:0]}];
    end
`endif

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pred_valid_q       <= 1'b0;
            pred_pixel_q       <= 10'd0;
            active_pred_x_q    <= 6'd0;
            active_pred_y_q    <= 6'd0;
            active_pred_last_q <= 1'b0;
            md_best_is_intra_q <= 1'b1;
        end else begin
            pred_valid_q       <= pred_valid;
            pred_pixel_q       <= pred_pixel;
            active_pred_x_q    <= active_pred_x;
            active_pred_y_q    <= active_pred_y;
            active_pred_last_q <= active_pred_last;
            md_best_is_intra_q <= latched_cu_is_intra;
        end
    end
    // Accept input pixels when CTU input buffer is ready for a new 64x64 block and previous CTU is fully done
    assign in_ready   = (frame_start_pending || ctu_frame_active) && (ctu_partitioner_ready && !ctu_pixels_ready && ctu_buffer_free);


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
    reg               dct_start_pre;
    
`ifndef SYNTHESIS
    integer r_i, r_j;
`endif
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dct_start_pre <= 1'b0;
            dct_start <= 1'b0;
`ifndef SYNTHESIS
            for (r_i = 0; r_i < 32; r_i = r_i + 1) begin
                for (r_j = 0; r_j < 32; r_j = r_j + 1) begin
                    residual_buffer[r_i][r_j] <= 16'd0;
                end
            end
`endif
        end else begin
            if (res_sub_valid) begin
                residual_buffer[res_sub_y[4:0]][res_sub_x[4:0]] <= $signed(res_sub_data);
            end
            
            dct_start_pre <= (pred_valid_q && active_pred_last_q);
            dct_start     <= dct_start_pre;
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (dct_start) begin
            $display("Time=%0t: [HEVC_TOP] DCT START! tu=(%0d,%0d), comp=%0d, size=%0d, res[0][0]=%0d, res[0][31]=%0d, res[31][0]=%0d, res[31][31]=%0d, res_mean_approx=%0d",
                     $time, reg_tu_x, reg_tu_y, reg_tu_comp, reg_tu_size_log2,
                     $signed(residual_buffer[0][0]), $signed(residual_buffer[0][31]),
                     $signed(residual_buffer[31][0]), $signed(residual_buffer[31][31]),
                     ($signed(residual_buffer[0][0]) + $signed(residual_buffer[0][31]) + $signed(residual_buffer[31][0]) + $signed(residual_buffer[31][31])) / 4);
        end
    end
    // synthesis translate_on

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
    assign pred_valid = latched_cu_is_intra ? intra_pred_valid : inter_pred_valid;
    assign pred_pixel = latched_cu_is_intra ? intra_pred_pixel : inter_pred_pixel;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) mc_data_ready <= 1'b0;
        else if (mc_start) mc_data_ready <= 1'b0;
        else if (mc_done)  mc_data_ready <= 1'b1;
    end
    
    // Trigger mc_unit right after mode_decision asserts mode_valid and best is Inter
    assign mc_start = md_mode_valid && !md_best_is_intra;
    //-------------------------------------------------------------------------
    // TU Sequencer & Neighbor Buffer for Intra Prediction
    //-------------------------------------------------------------------------
`ifdef SYNTHESIS
    (* ramstyle = "M10K, no_rw_check" *) reg [`PIXEL_WIDTH-1:0] recon_y_ram [0:`CTU_LUMA_SAMPLES-1]; // CTU Luma recon buffer
    (* ramstyle = "M10K, no_rw_check" *) reg [`PIXEL_WIDTH-1:0] recon_u_ram [0:`CTU_CB_SAMPLES-1];   // CTU Chroma U recon buffer
    (* ramstyle = "M10K, no_rw_check" *) reg [`PIXEL_WIDTH-1:0] recon_v_ram [0:`CTU_CR_SAMPLES-1];   // CTU Chroma V recon buffer
`else
    reg [`PIXEL_WIDTH-1:0] recon_y_ram [0:`CTU_LUMA_SAMPLES-1]; // CTU Luma recon buffer
    reg [`PIXEL_WIDTH-1:0] recon_u_ram [0:`CTU_CB_SAMPLES-1];   // CTU Chroma U recon buffer
    reg [`PIXEL_WIDTH-1:0] recon_v_ram [0:`CTU_CR_SAMPLES-1];   // CTU Chroma V recon buffer

    integer sim_recon_i;
    initial begin
        for (sim_recon_i = 0; sim_recon_i < `CTU_LUMA_SAMPLES; sim_recon_i = sim_recon_i + 1)
            recon_y_ram[sim_recon_i] = `MID_GRAY_SAMPLE;
        for (sim_recon_i = 0; sim_recon_i < `CTU_CB_SAMPLES; sim_recon_i = sim_recon_i + 1) begin
            recon_u_ram[sim_recon_i] = `MID_GRAY_SAMPLE;
            recon_v_ram[sim_recon_i] = `MID_GRAY_SAMPLE;
        end
    end
    always @(posedge clk) begin
        if (sync_frame_done_pulse || !rst_n) begin
            for (sim_recon_i = 0; sim_recon_i < `CTU_LUMA_SAMPLES; sim_recon_i = sim_recon_i + 1)
                recon_y_ram[sim_recon_i] <= `MID_GRAY_SAMPLE;
            for (sim_recon_i = 0; sim_recon_i < `CTU_CB_SAMPLES; sim_recon_i = sim_recon_i + 1) begin
                recon_u_ram[sim_recon_i] <= `MID_GRAY_SAMPLE;
                recon_v_ram[sim_recon_i] <= `MID_GRAY_SAMPLE;
            end
        end
    end
`endif
    
    // CTU Neighbor Line & Column Buffers for Inter-CTU Intra Prediction
    reg [`PIXEL_WIDTH-1:0] line_buf_y  [0:FRAME_WIDTH-1];
    reg [`PIXEL_WIDTH-1:0] line_buf_u  [0:(FRAME_WIDTH/2)-1];
    reg [`PIXEL_WIDTH-1:0] line_buf_v  [0:(FRAME_WIDTH/2)-1];

    reg [`PIXEL_WIDTH-1:0] col_buf_y   [0:`CTU_SIZE-1];
    reg [`PIXEL_WIDTH-1:0] col_buf_u   [0:(`CTU_SIZE/2)-1];
    reg [`PIXEL_WIDTH-1:0] col_buf_v   [0:(`CTU_SIZE/2)-1];

    reg [5:0] recon_ctu_x;
    reg [5:0] recon_ctu_y;

    wire [11:0] abs_recon_x     = {6'd0, recon_ctu_x, 6'd0} + {6'd0, recon_out_x[5:0]};
    wire [11:0] abs_recon_x_chr = {7'd0, recon_ctu_x, 5'd0} + {7'd0, recon_out_x[4:0]};
    wire [11:0] abs_recon_y     = {6'd0, recon_ctu_y, 6'd0} + {6'd0, recon_out_y[5:0]};

    integer l_i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (l_i = 0; l_i < FRAME_WIDTH; l_i = l_i + 1) line_buf_y[l_i] <= `MID_GRAY_SAMPLE;
            for (l_i = 0; l_i < (FRAME_WIDTH/2); l_i = l_i + 1) begin
                line_buf_u[l_i] <= `MID_GRAY_SAMPLE;
                line_buf_v[l_i] <= `MID_GRAY_SAMPLE;
            end
            for (l_i = 0; l_i < `CTU_SIZE; l_i = l_i + 1) col_buf_y[l_i] <= `MID_GRAY_SAMPLE;
            for (l_i = 0; l_i < (`CTU_SIZE/2); l_i = l_i + 1) begin
                col_buf_u[l_i] <= `MID_GRAY_SAMPLE;
                col_buf_v[l_i] <= `MID_GRAY_SAMPLE;
            end
        end else if (sync_frame_done_pulse) begin
            for (l_i = 0; l_i < FRAME_WIDTH; l_i = l_i + 1) line_buf_y[l_i] <= `MID_GRAY_SAMPLE;
            for (l_i = 0; l_i < (FRAME_WIDTH/2); l_i = l_i + 1) begin
                line_buf_u[l_i] <= `MID_GRAY_SAMPLE;
                line_buf_v[l_i] <= `MID_GRAY_SAMPLE;
            end
            for (l_i = 0; l_i < `CTU_SIZE; l_i = l_i + 1) col_buf_y[l_i] <= `MID_GRAY_SAMPLE;
            for (l_i = 0; l_i < (`CTU_SIZE/2); l_i = l_i + 1) begin
                col_buf_u[l_i] <= `MID_GRAY_SAMPLE;
                col_buf_v[l_i] <= `MID_GRAY_SAMPLE;
            end
        end else if (recon_out_valid) begin
            if (recon_out_comp == 2'd0) begin
                recon_y_ram[{recon_out_y[5:0], recon_out_x[5:0]}] <= recon_out_pixel;
                if (recon_out_y[5:0] == 6'd63) line_buf_y[abs_recon_x] <= recon_out_pixel;
                if (recon_out_x[5:0] == 6'd63) col_buf_y[recon_out_y[5:0]] <= recon_out_pixel;
            end else if (recon_out_comp == 2'd1) begin
                recon_u_ram[{recon_out_y[4:0], recon_out_x[4:0]}] <= recon_out_pixel;
                if (recon_out_y[4:0] == 5'd31) line_buf_u[abs_recon_x_chr] <= recon_out_pixel;
                if (recon_out_x[4:0] == 5'd31) col_buf_u[recon_out_y[4:0]] <= recon_out_pixel;
            end else if (recon_out_comp == 2'd2) begin
                recon_v_ram[{recon_out_y[4:0], recon_out_x[4:0]}] <= recon_out_pixel;
                if (recon_out_y[4:0] == 5'd31) line_buf_v[abs_recon_x_chr] <= recon_out_pixel;
                if (recon_out_x[4:0] == 5'd31) col_buf_v[recon_out_y[4:0]] <= recon_out_pixel;
            end
        end
    end

    // HEVC ref sample layout: 4N+1 samples = corner(1) + top(2N) + left(2N)
    // ref_sample_filter expects all 4N+1 samples before producing filtered output
    wire [7:0] intra_ref_max = (8'd1 << (reg_tu_size_log2 + 2)); // 4N
    wire [7:0] intra_ref_half = (8'd1 << (reg_tu_size_log2 + 1)); // 2N (boundary between top and left)

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
            reg_pu_x <= 0;
            reg_pu_y <= 0;
            recon_ctu_x <= 0;
            recon_ctu_y <= 0;
        end else begin
            if (tu_valid && tu_ready_signal) begin
                tu_can_start <= 1'b0;
                reg_tu_x <= tu_x;
                reg_tu_y <= tu_y;
                reg_tu_size_log2 <= tu_size_log2;
                reg_tu_comp <= tu_comp;
                reg_tu_is_last_in_cu <= tu_is_last_in_cu;
                reg_pu_x <= pu_x;
                reg_pu_y <= pu_y;
                recon_ctu_x <= latched_cu_ctu_x;
                recon_ctu_y <= latched_cu_ctu_y;
                if (latched_cu_is_intra) begin
                    intra_ref_active <= 1'b1;
                    intra_ref_idx <= 8'd0;
                end
            end else if (intra_ref_active) begin
                if (intra_ref_idx == intra_ref_max) begin
                    intra_ref_active <= 1'b0;
                end else begin
                    intra_ref_idx <= intra_ref_idx + 1;
                end
            end else if (cabac_coeff_done) begin
                tu_can_start <= 1'b1;
            end
        end
    end
    
    assign tu_ready_signal = tu_can_start && !inter_p2s_active && !intra_ref_active && !p2s_active && !idct_p2s_active &&
                             !idct_active && !idct_start && !idct_start_pre &&
                             (latched_cu_is_intra || mc_data_ready);
    
    // FIX: Synchronous SRAM read for recon_ram to prevent combinational synthesis failure
    wire is_luma_comp = (reg_tu_comp == 2'd0);
    
    // TU size in pixels for availability checking
    wire [5:0] tu_n = 6'd1 << reg_tu_size_log2;
    wire [5:0] max_ctu_dim = is_luma_comp ? 6'd63 : 6'd31;

    wire [7:0] top_idx_rel = (intra_ref_idx >= 8'd1) ? (intra_ref_idx - 8'd1) : 8'd0;
    wire [7:0] left_idx_rel = (intra_ref_idx > intra_ref_half) ? (intra_ref_idx - intra_ref_half - 8'd1) : 8'd0;

    wire [6:0] top_col_unclamped = {1'b0, reg_tu_x} + {1'b0, top_idx_rel[5:0]};
    wire top_right_avail = (reg_tu_y == 6'd0) || (reg_tu_x[reg_tu_size_log2] == 1'b0);
    wire [5:0] top_col_clamped = (top_col_unclamped <= {1'b0, max_ctu_dim} && (top_right_avail || top_idx_rel < {2'b0, tu_n})) ?
                                 top_col_unclamped[5:0] : (reg_tu_x + tu_n - 6'd1);
    wire [6:0] left_row_unclamped = {1'b0, reg_tu_y} + {1'b0, left_idx_rel[5:0]};
    wire [5:0] left_row_clamped = (reg_tu_x == 6'd0) ?
        ((left_row_unclamped <= {1'b0, max_ctu_dim}) ? left_row_unclamped[5:0] : (reg_tu_y + tu_n - 6'd1)) :
        ((left_idx_rel < {2'b0, tu_n}) ? left_row_unclamped[5:0] : (reg_tu_y + tu_n - 6'd1));

    wire [5:0] ref_calc_row = (intra_ref_idx == 0) ? (reg_tu_y - 6'd1) :
                              (intra_ref_idx <= intra_ref_half) ? (reg_tu_y - 6'd1) :
                              left_row_clamped;

    wire [5:0] ref_calc_col = (intra_ref_idx == 0) ? (reg_tu_x - 6'd1) :
                              (intra_ref_idx <= intra_ref_half) ? top_col_clamped :
                              (reg_tu_x - 6'd1);

    reg [11:0] recon_rd_addr;
    always @(*) begin
        if (is_luma_comp)
            recon_rd_addr = {ref_calc_row[5:0], ref_calc_col[5:0]};
        else
            recon_rd_addr = {2'b0, ref_calc_row[4:0], ref_calc_col[4:0]};
    end

    wire [11:0] abs_top_x_raw = is_luma_comp ? ({6'd0, latched_cu_ctu_x, 6'd0} + {5'd0, top_col_unclamped}) :
                                               ({7'd0, latched_cu_ctu_x, 5'd0} + {6'd0, top_col_unclamped[4:0]});
    wire [11:0] abs_ref_top_x = is_luma_comp ? 
        ((abs_top_x_raw < FRAME_WIDTH) ? abs_top_x_raw : (FRAME_WIDTH - 12'd1)) :
        ((abs_top_x_raw < (FRAME_WIDTH/2)) ? abs_top_x_raw : ((FRAME_WIDTH/2) - 12'd1));
    wire [11:0] abs_ref_corner_x = is_luma_comp ? ({6'd0, latched_cu_ctu_x, 6'd0} + {6'd0, reg_tu_x} - 12'd1) :
                                                  ({7'd0, latched_cu_ctu_x, 5'd0} + {7'd0, reg_tu_x[4:0]} - 12'd1);
    wire [11:0] abs_ctu_corner_x = is_luma_comp ? ({6'd0, latched_cu_ctu_x, 6'd0} - 12'd1) :
                                                  ({7'd0, latched_cu_ctu_x, 5'd0} - 12'd1);

    wire top_available    = (reg_tu_y > 0) || (latched_cu_ctu_y > 0);
    wire left_available   = (reg_tu_x > 0) || (latched_cu_ctu_x > 0);
    wire corner_available = top_available && left_available;
    wire any_neighbor_available = top_available || left_available;

    wire recon_rd_valid = any_neighbor_available;

`ifdef SYNTHESIS
    reg [9:0] recon_y_rd_q, recon_u_rd_q, recon_v_rd_q;
    always @(posedge clk) begin
        recon_y_rd_q <= recon_y_ram[recon_rd_addr];
        recon_u_rd_q <= recon_u_ram[recon_rd_addr[9:0]];
        recon_v_rd_q <= recon_v_ram[recon_rd_addr[9:0]];
    end
    wire [9:0] recon_sample_synth = (reg_tu_comp == 2'd0) ? recon_y_rd_q :
                                   (reg_tu_comp == 2'd1) ? recon_u_rd_q :
                                                           recon_v_rd_q;
    wire [9:0] first_top_sample  = recon_sample_synth;
    wire [9:0] first_left_sample = recon_sample_synth;

    reg [9:0] recon_val_wire;
    always @(*) begin
        recon_val_wire = recon_sample_synth;
    end
`else
    // First available top sample for sample substitution when left is unavailable
    wire [9:0] first_top_sample = 
        (reg_tu_y > 0) ? (is_luma_comp ? recon_y_ram[{reg_tu_y - 6'd1, reg_tu_x}] :
                          (reg_tu_comp == 2'd1) ? recon_u_ram[{reg_tu_y[4:0] - 5'd1, reg_tu_x[4:0]}] :
                                                  recon_v_ram[{reg_tu_y[4:0] - 5'd1, reg_tu_x[4:0]}]) :
        (latched_cu_ctu_y > 0) ? (is_luma_comp ? line_buf_y[{6'd0, latched_cu_ctu_x, 6'd0} + {6'd0, reg_tu_x}] :
                                  (reg_tu_comp == 2'd1) ? line_buf_u[{7'd0, latched_cu_ctu_x, 5'd0} + {7'd0, reg_tu_x[4:0]}] :
                                                          line_buf_v[{7'd0, latched_cu_ctu_x, 5'd0} + {7'd0, reg_tu_x[4:0]}]) :
        10'd512;

    // First available left sample for sample substitution when top is unavailable
    wire [9:0] first_left_sample = 
        (reg_tu_x > 0) ? (is_luma_comp ? recon_y_ram[{reg_tu_y, reg_tu_x - 6'd1}] :
                          (reg_tu_comp == 2'd1) ? recon_u_ram[{reg_tu_y[4:0], reg_tu_x[4:0] - 5'd1}] :
                                                  recon_v_ram[{reg_tu_y[4:0], reg_tu_x[4:0] - 5'd1}]) :
        (latched_cu_ctu_x > 0) ? (is_luma_comp ? col_buf_y[reg_tu_y] :
                                  (reg_tu_comp == 2'd1) ? col_buf_u[reg_tu_y[4:0]] :
                                                          col_buf_v[reg_tu_y[4:0]]) :
        10'd512;

    reg [9:0] recon_val_wire;
    always @(*) begin
        if (intra_ref_idx == 0) begin
            if (corner_available) begin
                if (reg_tu_x > 0 && reg_tu_y > 0)
                    recon_val_wire = (reg_tu_comp == 2'd0) ? recon_y_ram[recon_rd_addr] :
                                     (reg_tu_comp == 2'd1) ? recon_u_ram[recon_rd_addr[9:0]] :
                                                             recon_v_ram[recon_rd_addr[9:0]];
                else if (reg_tu_y > 0 && latched_cu_ctu_x > 0)
                    recon_val_wire = (reg_tu_comp == 2'd0) ? col_buf_y[reg_tu_y - 6'd1] :
                                     (reg_tu_comp == 2'd1) ? col_buf_u[reg_tu_y[4:0] - 5'd1] :
                                                             col_buf_v[reg_tu_y[4:0] - 5'd1];
                else if (reg_tu_x > 0 && latched_cu_ctu_y > 0)
                    recon_val_wire = (reg_tu_comp == 2'd0) ? line_buf_y[abs_ref_corner_x] :
                                     (reg_tu_comp == 2'd1) ? line_buf_u[abs_ref_corner_x] :
                                                             line_buf_v[abs_ref_corner_x];
                else
                    recon_val_wire = (reg_tu_comp == 2'd0) ? line_buf_y[abs_ctu_corner_x] :
                                     (reg_tu_comp == 2'd1) ? line_buf_u[abs_ctu_corner_x] :
                                                             line_buf_v[abs_ctu_corner_x];
            end else if (top_available) begin
                recon_val_wire = first_top_sample; // HEVC sample substitution
            end else if (left_available) begin
                recon_val_wire = first_left_sample; // HEVC sample substitution
            end else begin
                recon_val_wire = 10'd512;
            end
        end else if (intra_ref_idx <= intra_ref_half) begin
            // Top references
            if (top_available) begin
                if (reg_tu_y > 0)
                    recon_val_wire = (reg_tu_comp == 2'd0) ? recon_y_ram[recon_rd_addr] :
                                     (reg_tu_comp == 2'd1) ? recon_u_ram[recon_rd_addr[9:0]] :
                                                             recon_v_ram[recon_rd_addr[9:0]];
                else
                    recon_val_wire = (reg_tu_comp == 2'd0) ? line_buf_y[abs_ref_top_x] :
                                     (reg_tu_comp == 2'd1) ? line_buf_u[abs_ref_top_x] :
                                                             line_buf_v[abs_ref_top_x];
            end else if (left_available) begin
                recon_val_wire = first_left_sample; // HEVC sample substitution
            end else begin
                recon_val_wire = 10'd512;
            end
        end else begin
            // Left references
            if (left_available) begin
                if (reg_tu_x > 0)
                    recon_val_wire = (reg_tu_comp == 2'd0) ? recon_y_ram[recon_rd_addr] :
                                     (reg_tu_comp == 2'd1) ? recon_u_ram[recon_rd_addr[9:0]] :
                                                             recon_v_ram[recon_rd_addr[9:0]];
                else
                    recon_val_wire = (reg_tu_comp == 2'd0) ? col_buf_y[left_row_clamped] :
                                     (reg_tu_comp == 2'd1) ? col_buf_u[left_row_clamped[4:0]] :
                                                             col_buf_v[left_row_clamped[4:0]];
            end else if (top_available) begin
                recon_val_wire = first_top_sample; // HEVC sample substitution
            end else begin
                recon_val_wire = 10'd512;
            end
        end
    end
`endif

    reg recon_rd_valid_q;
    reg [9:0] recon_ram_q;
    reg        intra_ref_active_q;
    reg [7:0]  intra_ref_idx_q;
    reg        intra_ref_last_q;

    always @(posedge clk) begin
        recon_ram_q        <= recon_val_wire;
        recon_rd_valid_q   <= recon_rd_valid;
        intra_ref_active_q <= intra_ref_active;
        intra_ref_idx_q    <= intra_ref_idx;
        intra_ref_last_q   <= (intra_ref_idx == intra_ref_max);
    end

    wire [9:0] intra_ref_sample = recon_rd_valid_q ? recon_ram_q : 10'd512;

    //-------------------------------------------------------------------------
    // RMD Reference Sample Feeder
    // Runs independently from TU ref loading, triggered by eval_intra_start
    //-------------------------------------------------------------------------
    reg        rmd_ref_active;
    reg [7:0]  rmd_ref_idx;
    wire [7:0] rmd_ref_max = (8'd1 << (rmd_pu_size_log2 + 2)); // 4N
    wire [7:0] rmd_ref_half = (8'd1 << (rmd_pu_size_log2 + 1)); // 2N
    wire [5:0] rmd_N = 6'd1 << rmd_pu_size_log2;

    // RMD ref feeding uses same coordinate logic as TU ref feeding
    // but with pu_x/pu_y (CU position) instead of reg_tu_x/reg_tu_y
    reg [11:0] rmd_recon_rd_addr;
    reg        rmd_recon_rd_valid;
    reg [9:0]  rmd_recon_ram_q;
    reg        rmd_recon_rd_valid_q;
    reg        rmd_ref_active_q;
    reg [7:0]  rmd_ref_idx_q;
    reg        rmd_ref_last_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rmd_ref_active <= 0;
            rmd_ref_idx <= 0;
        end else begin
            if (eval_intra_start) begin
                rmd_ref_active <= 1'b1;
                rmd_ref_idx <= 8'd0;
            end else if (rmd_ref_active) begin
                if (rmd_ref_idx == rmd_ref_max) begin
                    rmd_ref_active <= 1'b0;
                end else begin
                    rmd_ref_idx <= rmd_ref_idx + 1;
                end
            end
        end
    end

    // Latch pu_x/pu_y and ctu_x/ctu_y at cu_valid time (guaranteed valid from partitioner)
    reg [5:0] rmd_latched_pu_x, rmd_latched_pu_y;
    reg [5:0] rmd_latched_ctu_x, rmd_latched_ctu_y;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rmd_latched_pu_x  <= 6'd0;
            rmd_latched_pu_y  <= 6'd0;
            rmd_latched_ctu_x <= 6'd0;
            rmd_latched_ctu_y <= 6'd0;
        end else if (cu_valid) begin
            rmd_latched_pu_x  <= cu_x;
            rmd_latched_pu_y  <= cu_y;
            rmd_latched_ctu_x <= ctu_x;
            rmd_latched_ctu_y <= ctu_y;
        end
    end

    wire [7:0] rmd_top_idx_rel = (rmd_ref_idx >= 8'd1) ? (rmd_ref_idx - 8'd1) : 8'd0;
    wire [7:0] rmd_left_idx_rel = (rmd_ref_idx > rmd_ref_half) ? (rmd_ref_idx - rmd_ref_half - 8'd1) : 8'd0;

    wire [6:0] rmd_top_col_unclamped = {1'b0, rmd_latched_pu_x} + {1'b0, rmd_top_idx_rel[5:0]};
    wire rmd_top_right_avail = (rmd_latched_pu_y == 6'd0) || (rmd_latched_pu_x[rmd_pu_size_log2] == 1'b0);
    wire [5:0] rmd_top_col_clamped = (rmd_top_col_unclamped <= 7'd63 && (rmd_top_right_avail || rmd_top_idx_rel < {2'b0, rmd_N})) ?
                                     rmd_top_col_unclamped[5:0] : (rmd_latched_pu_x + rmd_N - 6'd1);
    wire [6:0] rmd_left_row_unclamped = {1'b0, rmd_latched_pu_y} + {1'b0, rmd_left_idx_rel[5:0]};
    wire [5:0] rmd_left_row_clamped = (rmd_latched_pu_x == 6'd0) ?
        ((rmd_left_row_unclamped <= 7'd63) ? rmd_left_row_unclamped[5:0] : (rmd_latched_pu_y + rmd_N - 6'd1)) :
        ((rmd_left_idx_rel < {2'b0, rmd_N}) ? rmd_left_row_unclamped[5:0] : (rmd_latched_pu_y + rmd_N - 6'd1));

    wire [11:0] rmd_abs_top_x_raw = {6'd0, rmd_latched_ctu_x, 6'd0} + {5'd0, rmd_top_col_unclamped};
    wire [11:0] rmd_abs_ref_top_x = (rmd_abs_top_x_raw < FRAME_WIDTH) ? rmd_abs_top_x_raw : (FRAME_WIDTH - 12'd1);
    wire [11:0] rmd_abs_ref_corner_x = {6'd0, rmd_latched_ctu_x, 6'd0} + {6'd0, rmd_latched_pu_x} - 12'd1;
    wire [11:0] rmd_abs_ctu_corner_x = {6'd0, rmd_latched_ctu_x, 6'd0} - 12'd1;

    wire rmd_top_available    = (rmd_latched_pu_y > 0) || (rmd_latched_ctu_y > 0);
    wire rmd_left_available   = (rmd_latched_pu_x > 0) || (rmd_latched_ctu_x > 0);
    wire rmd_corner_available = rmd_top_available && rmd_left_available;
    wire rmd_any_available    = rmd_top_available || rmd_left_available;

`ifdef SYNTHESIS
    wire [9:0] rmd_first_top_sample  = recon_sample_synth;
    wire [9:0] rmd_first_left_sample = recon_sample_synth;

    reg [9:0] rmd_recon_val_wire;
    always @(*) begin
        rmd_recon_rd_addr  = 12'd0;
        rmd_recon_rd_valid = rmd_any_available;
        rmd_recon_val_wire = recon_sample_synth;
    end
`else
    wire [9:0] rmd_first_top_sample = 
        (rmd_latched_pu_y > 0) ? recon_y_ram[{rmd_latched_pu_y - 6'd1, rmd_latched_pu_x}] :
        (rmd_latched_ctu_y > 0) ? line_buf_y[{6'd0, rmd_latched_ctu_x, 6'd0} + {6'd0, rmd_latched_pu_x}] :
        10'd512;

    wire [9:0] rmd_first_left_sample = 
        (rmd_latched_pu_x > 0) ? recon_y_ram[{rmd_latched_pu_y, rmd_latched_pu_x - 6'd1}] :
        (rmd_latched_ctu_x > 0) ? col_buf_y[rmd_latched_pu_y] :
        10'd512;

    reg [9:0] rmd_recon_val_wire;
    always @(*) begin
        rmd_recon_rd_addr = 12'd0;
        rmd_recon_rd_valid = rmd_any_available;
        rmd_recon_val_wire = 10'd512;
        if (rmd_ref_active) begin
            if (rmd_ref_idx == 8'd0) begin
                // Corner
                if (rmd_corner_available) begin
                    if (rmd_latched_pu_x > 0 && rmd_latched_pu_y > 0) begin
                        rmd_recon_rd_addr = {rmd_latched_pu_y - 6'd1, rmd_latched_pu_x - 6'd1};
                        rmd_recon_val_wire = recon_y_ram[rmd_recon_rd_addr];
                    end else if (rmd_latched_pu_y > 0 && rmd_latched_ctu_x > 0)
                        rmd_recon_val_wire = col_buf_y[rmd_latched_pu_y - 6'd1];
                    else if (rmd_latched_pu_x > 0 && rmd_latched_ctu_y > 0)
                        rmd_recon_val_wire = line_buf_y[rmd_abs_ref_corner_x];
                    else
                        rmd_recon_val_wire = line_buf_y[rmd_abs_ctu_corner_x];
                end else if (rmd_top_available) begin
                    rmd_recon_val_wire = rmd_first_top_sample;
                end else if (rmd_left_available) begin
                    rmd_recon_val_wire = rmd_first_left_sample;
                end else begin
                    rmd_recon_val_wire = 10'd512;
                end
            end else if (rmd_ref_idx <= rmd_ref_half) begin
                // Top row
                if (rmd_top_available) begin
                    if (rmd_latched_pu_y > 0) begin
                        rmd_recon_rd_addr = {rmd_latched_pu_y - 6'd1, rmd_top_col_clamped};
                        rmd_recon_val_wire = recon_y_ram[rmd_recon_rd_addr];
                    end else if (rmd_latched_ctu_y > 0)
                        rmd_recon_val_wire = line_buf_y[rmd_abs_ref_top_x];
                end else if (rmd_left_available) begin
                    rmd_recon_val_wire = rmd_first_left_sample;
                end else begin
                    rmd_recon_val_wire = 10'd512;
                end
            end else begin
                // Left column
                if (rmd_left_available) begin
                    if (rmd_latched_pu_x > 0) begin
                        rmd_recon_rd_addr = {rmd_left_row_clamped, rmd_latched_pu_x - 6'd1};
                        rmd_recon_val_wire = recon_y_ram[rmd_recon_rd_addr];
                    end else if (rmd_latched_ctu_x > 0)
                        rmd_recon_val_wire = col_buf_y[rmd_left_row_clamped];
                end else if (rmd_top_available) begin
                    rmd_recon_val_wire = rmd_first_top_sample;
                end else begin
                    rmd_recon_val_wire = 10'd512;
                end
            end
        end
    end
`endif

    // Pipeline for RMD ref samples (1-cycle SRAM latency)
    always @(posedge clk) begin
        rmd_recon_ram_q       <= rmd_recon_val_wire;
        rmd_recon_rd_valid_q <= rmd_recon_rd_valid;
        rmd_ref_active_q     <= rmd_ref_active;
        rmd_ref_idx_q        <= rmd_ref_idx;
        rmd_ref_last_q       <= (rmd_ref_idx == rmd_ref_max);
    end

    wire [9:0] rmd_ref_sample = rmd_recon_rd_valid_q ? rmd_recon_ram_q : 10'd512;



    // Intra RMD instance (uses its own ref feeding, not TU ref feeding)
    intra_rmd u_intra_rmd (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (eval_intra_start),
        .pu_x          (rmd_latched_pu_x),
        .pu_y          (rmd_latched_pu_y),
        .pu_size_log2  (rmd_pu_size_log2),
        .orig_rd_addr  (rmd_orig_rd_addr),
        .rmd_active    (rmd_active),
        .orig_rd_data  (rmd_orig_data),
        .ref_valid     (rmd_ref_active_q),
        .ref_sample    (rmd_ref_sample),
        .ref_idx       (rmd_ref_idx_q),
        .ref_last      (rmd_ref_last_q),
        .rmd_done      (rmd_done),
        .best_mode     (rmd_best_mode),
        .best_cost     (rmd_best_cost)
    );

    //-------------------------------------------------------------------------
    // Inter Prediction Modules
    //-------------------------------------------------------------------------
    // MVP from AMVP predictor (candidate 0 = lower 10 bits of flat bus)
    wire signed [9:0] mvp_x_qp = amvp_mv_x_flat[9:0];
    wire signed [9:0] mvp_y_qp = amvp_mv_y_flat[9:0];
    // TZ Search expects integer-pel MVP
    wire signed [9:0] mvp_x = mvp_x_qp >>> 2;
    wire signed [9:0] mvp_y = mvp_y_qp >>> 2;
    

    // MC uses quarter-pel units (best_inter_mv_x/y from mode_decision * 4)
    // FIX: md_best_inter_mv is already quarter-pel. Sign-extend 12-bit to 14-bit without shifting.
    wire signed [13:0] mc_mv_x_qp = {{2{md_best_inter_mv_x[11]}}, md_best_inter_mv_x};
    wire signed [13:0] mc_mv_y_qp = {{2{md_best_inter_mv_y[11]}}, md_best_inter_mv_y};

    
    // AXI read channels for Inter Pred (to Arbiter)
    wire         ip_arvalid;
    wire         ip_arready;
    wire [32:0]  ip_araddr;
    wire [8:0]   ip_arlen;
    wire [2:0]   ip_arsize;
    wire [1:0]   ip_arburst;
    wire         ip_rvalid;
    wire         ip_rready;
    wire [255:0] ip_rdata;
    wire         ip_rlast;


    // Fetch 4x4 block for TZ search based on pu_x and pu_y
`ifdef SYNTHESIS
    reg [159:0] search_orig_flat;
    always @(posedge clk) begin
        if (eval_inter_start)
            search_orig_flat <= {16{orig_pixel_q}};
    end
`else
    wire [159:0] search_orig_flat;
    genvar sy, sx;
    generate
        for (sy = 0; sy < 4; sy = sy + 1) begin : gen_s_y
            for (sx = 0; sx < 4; sx = sx + 1) begin : gen_s_x
                assign search_orig_flat[(sy*4+sx)*10 +: 10] = orig_y_ram[{pu_y[5:0] + sy[5:0], pu_x[5:0] + sx[5:0]}];
            end
        end
    endgenerate
`endif

    wire [39:0] mc_pred_cb_flat;
    wire [39:0] mc_pred_cr_flat;

    inter_pred_top #(
        .FRAME_W_Y(FRAME_WIDTH),
        .FRAME_H_Y(FRAME_HEIGHT),
        .FRAME_W_C(FRAME_WIDTH / 2),
        .FRAME_H_C(FRAME_HEIGHT / 2)
    ) u_inter_pred (
        .clk              (clk),
        .rst_n            (rst_n),
        .ref_slot_in      (ref_l0[2:0]),   // DPB slot for ref frame L0[0]
        .ref_slot_l1      (ref_l1[2:0]),   // DPB slot for ref frame L1[0]
        .inter_pred_idc   (ctu_slice_type == 2'd0 ? 2'd2 : 2'd0), // B-slice: Bi-prediction
        .search_start     (eval_inter_start),
        .search_ready     (),
        .cu_orig_flat     (search_orig_flat),
        .cu_x             (({6'd0, rmd_latched_ctu_x} << 6) + {6'd0, rmd_latched_pu_x}),
        .cu_y             (({6'd0, rmd_latched_ctu_y} << 6) + {6'd0, rmd_latched_pu_y}),
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
        .mc_mv_l1_x       (mc_mv_x_qp),
        .mc_mv_l1_y       (mc_mv_y_qp),
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
    // =========================================================================
    // Reference Frame Store (DPB) for Inter Prediction
    // Maintains reconstructed frames from previous pictures (Slot 0 and Slot 1)
    // Resolution: 128x128 (Luma: 16384 samples, Cb: 4096 samples, Cr: 4096 samples)
    // =========================================================================
    wire        filter_out_valid;
    wire        filter_out_ready;
    wire [9:0]  filter_out_pixel;
    wire [1:0]  filter_out_comp;
    wire [11:0] filter_out_x;
    wire [11:0] filter_out_y;

`ifdef SYNTHESIS
    // Memory replication pattern: dpb_*_ram_l0 and dpb_*_ram_l1 each store the full
    // 2-slot DPB (32768 samples = 2 slots of 128x128). Replicated so FPGA M10K/BRAM
    // can provide two independent read ports (one for ref_l0, one for ref_l1) alongside the write port.
    (* ramstyle = "M10K, no_rw_check" *) reg [9:0] dpb_luma_ram_l0 [0:32767];
    (* ramstyle = "M10K, no_rw_check" *) reg [9:0] dpb_luma_ram_l1 [0:32767];
    (* ramstyle = "M10K, no_rw_check" *) reg [9:0] dpb_cb_ram_l0   [0:8191];
    (* ramstyle = "M10K, no_rw_check" *) reg [9:0] dpb_cb_ram_l1   [0:8191];
    (* ramstyle = "M10K, no_rw_check" *) reg [9:0] dpb_cr_ram_l0   [0:8191];
    (* ramstyle = "M10K, no_rw_check" *) reg [9:0] dpb_cr_ram_l1   [0:8191];

    always @(posedge clk) begin
        if (filter_out_valid && filter_out_ready) begin
            if (filter_out_comp == 2'd0) begin
                dpb_luma_ram_l0[{latched_wr_slot[0], filter_out_y[6:0], filter_out_x[6:0]}] <= filter_out_pixel;
                dpb_luma_ram_l1[{latched_wr_slot[0], filter_out_y[6:0], filter_out_x[6:0]}] <= filter_out_pixel;
            end else if (filter_out_comp == 2'd1) begin
                dpb_cb_ram_l0[{latched_wr_slot[0], filter_out_y[5:0], filter_out_x[5:0]}] <= filter_out_pixel;
                dpb_cb_ram_l1[{latched_wr_slot[0], filter_out_y[5:0], filter_out_x[5:0]}] <= filter_out_pixel;
            end else if (filter_out_comp == 2'd2) begin
                dpb_cr_ram_l0[{latched_wr_slot[0], filter_out_y[5:0], filter_out_x[5:0]}] <= filter_out_pixel;
                dpb_cr_ram_l1[{latched_wr_slot[0], filter_out_y[5:0], filter_out_x[5:0]}] <= filter_out_pixel;
            end
        end
    end
`else
    reg [9:0] dpb_luma_ram [0:1][0:16383];
    reg [9:0] dpb_cb_ram   [0:1][0:4095];
    reg [9:0] dpb_cr_ram   [0:1][0:4095];

    // synthesis translate_off
    integer dpb_i, dpb_s;
    initial begin
        for (dpb_s = 0; dpb_s < 2; dpb_s = dpb_s + 1) begin
            for (dpb_i = 0; dpb_i < 16384; dpb_i = dpb_i + 1) dpb_luma_ram[dpb_s][dpb_i] = 10'd512;
            for (dpb_i = 0; dpb_i < 4096;  dpb_i = dpb_i + 1) begin
                dpb_cb_ram[dpb_s][dpb_i] = 10'd512;
                dpb_cr_ram[dpb_s][dpb_i] = 10'd512;
            end
        end
    end
    // synthesis translate_on

    always @(posedge clk) begin
        if (filter_out_valid && filter_out_ready) begin
            if (filter_out_comp == 2'd0)
                dpb_luma_ram[latched_wr_slot[0]][{filter_out_y[6:0], filter_out_x[6:0]}] <= filter_out_pixel;
            else if (filter_out_comp == 2'd1)
                dpb_cb_ram[latched_wr_slot[0]][{filter_out_y[5:0], filter_out_x[5:0]}] <= filter_out_pixel;
            else if (filter_out_comp == 2'd2)
                dpb_cr_ram[latched_wr_slot[0]][{filter_out_y[5:0], filter_out_x[5:0]}] <= filter_out_pixel;
        end
    end
`endif

    function automatic [6:0] clamp_128;
        input signed [12:0] val;
        begin
            if (val < 0) clamp_128 = 7'd0;
            else if (val > 127) clamp_128 = 7'd127;
            else clamp_128 = val[6:0];
        end
    endfunction

    function automatic [5:0] clamp_64;
        input signed [12:0] val;
        begin
            if (val < 0) clamp_64 = 6'd0;
            else if (val > 63) clamp_64 = 6'd63;
            else clamp_64 = val[5:0];
        end
    endfunction

    wire [9:0] inter_p2s_max = (10'd1 << (reg_tu_size_log2 * 2)) - 10'd1;
    // P2S Sequencer dynamically maps Y, Cb, Cr flats from mc_unit to current TU processing sequence
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inter_p2s_active <= 0;
            inter_p2s_idx <= 0;
        end else begin
            if (tu_valid && tu_ready_signal && !latched_cu_is_intra) begin
                inter_p2s_active <= 1'b1;
                inter_p2s_idx <= 0;
            end else if (inter_p2s_active) begin
                if (inter_p2s_idx == inter_p2s_max) begin
                    inter_p2s_active <= 1'b0;
                end else begin
                    inter_p2s_idx <= inter_p2s_idx + 1;
                end
            end
        end
    end

    assign inter_pred_valid = inter_p2s_active;
    
    assign inter_out_x = (reg_tu_size_log2 == 3'd2) ? {8'd0, inter_p2s_idx[1:0]} :
                         (reg_tu_size_log2 == 3'd3) ? {8'd0, inter_p2s_idx[2:0]} :
                         (reg_tu_size_log2 == 3'd4) ? {8'd0, inter_p2s_idx[3:0]} :
                                                      {8'd0, inter_p2s_idx[4:0]};
                                                      
    assign inter_out_y = (reg_tu_size_log2 == 3'd2) ? {8'd0, inter_p2s_idx[3:2]} :
                         (reg_tu_size_log2 == 3'd3) ? {8'd0, inter_p2s_idx[5:3]} :
                         (reg_tu_size_log2 == 3'd4) ? {8'd0, inter_p2s_idx[7:4]} :
                                                      {8'd0, inter_p2s_idx[9:5]};
                                                      
    assign inter_out_last = (inter_p2s_idx == inter_p2s_max);

    // Absolute spatial coordinate of current sample within the 128x128 frame
    wire [6:0] cur_sample_abs_x = {latched_cu_ctu_x[0], 6'd0} + {1'b0, reg_tu_x} + {1'b0, inter_out_x[5:0]};
    wire [6:0] cur_sample_abs_y = {latched_cu_ctu_y[0], 6'd0} + {1'b0, reg_tu_y} + {1'b0, inter_out_y[5:0]};

    // Chroma coordinate (half resolution 64x64)
    wire [5:0] cur_sample_abs_cx = {latched_cu_ctu_x[0], 5'd0} + {1'b0, reg_tu_x[4:0]} + {1'b0, inter_out_x[4:0]};
    wire [5:0] cur_sample_abs_cy = {latched_cu_ctu_y[0], 5'd0} + {1'b0, reg_tu_y[4:0]} + {1'b0, inter_out_y[4:0]};

    // Motion vector components in integer units (mv_qp >>> 2)
    wire signed [11:0] mv_x_int = latched_cu_mv_x >>> 2;
    wire signed [11:0] mv_y_int = latched_cu_mv_y >>> 2;

    // Reference sample coordinates clamped to picture boundary
    wire [6:0] ref_x_luma = clamp_128($signed({6'd0, cur_sample_abs_x}) + mv_x_int);
    wire [6:0] ref_y_luma = clamp_128($signed({6'd0, cur_sample_abs_y}) + mv_y_int);

    wire [5:0] ref_x_chroma = clamp_64($signed({7'd0, cur_sample_abs_cx}) + (mv_x_int >>> 1));
    wire [5:0] ref_y_chroma = clamp_64($signed({7'd0, cur_sample_abs_cy}) + (mv_y_int >>> 1));

    // Reference slot index from GOP controller
    wire [2:0] ref_slot_0 = ref_l0[2:0];
    wire [2:0] ref_slot_1 = ref_l1[2:0];

    // Reference pixel lookups from DPB
`ifdef SYNTHESIS
    reg [9:0] ref_luma_l0, ref_cb_l0, ref_cr_l0;
    reg [9:0] ref_luma_l1, ref_cb_l1, ref_cr_l1;

    always @(posedge clk) begin
        ref_luma_l0 <= dpb_luma_ram_l0[{ref_slot_0[0], ref_y_luma, ref_x_luma}];
        ref_cb_l0   <= dpb_cb_ram_l0[{ref_slot_0[0], ref_y_chroma, ref_x_chroma}];
        ref_cr_l0   <= dpb_cr_ram_l0[{ref_slot_0[0], ref_y_chroma, ref_x_chroma}];

        ref_luma_l1 <= dpb_luma_ram_l1[{ref_slot_1[0], ref_y_luma, ref_x_luma}];
        ref_cb_l1   <= dpb_cb_ram_l1[{ref_slot_1[0], ref_y_chroma, ref_x_chroma}];
        ref_cr_l1   <= dpb_cr_ram_l1[{ref_slot_1[0], ref_y_chroma, ref_x_chroma}];
    end
`else
    wire [9:0] ref_luma_l0 = dpb_luma_ram[ref_slot_0[0]][{ref_y_luma, ref_x_luma}];
    wire [9:0] ref_cb_l0   = dpb_cb_ram[ref_slot_0[0]][{ref_y_chroma, ref_x_chroma}];
    wire [9:0] ref_cr_l0   = dpb_cr_ram[ref_slot_0[0]][{ref_y_chroma, ref_x_chroma}];

    wire [9:0] ref_luma_l1 = dpb_luma_ram[ref_slot_1[0]][{ref_y_luma, ref_x_luma}];
    wire [9:0] ref_cb_l1   = dpb_cb_ram[ref_slot_1[0]][{ref_y_chroma, ref_x_chroma}];
    wire [9:0] ref_cr_l1   = dpb_cr_ram[ref_slot_1[0]][{ref_y_chroma, ref_x_chroma}];
`endif

    // Prediction pixel multiplexer with optional Bi-prediction averaging (11-bit addition avoids overflow)
    wire is_bi_pred = (ctu_slice_type == 2'd0); // B-slice: Average L0 and L1

    wire [10:0] bi_luma_sum = {1'b0, ref_luma_l0} + {1'b0, ref_luma_l1} + 11'd1;
    wire [10:0] bi_cb_sum   = {1'b0, ref_cb_l0}   + {1'b0, ref_cb_l1}   + 11'd1;
    wire [10:0] bi_cr_sum   = {1'b0, ref_cr_l0}   + {1'b0, ref_cr_l1}   + 11'd1;

    wire [9:0] pred_luma_val = is_bi_pred ? bi_luma_sum[10:1] : ref_luma_l0;
    wire [9:0] pred_cb_val   = is_bi_pred ? bi_cb_sum[10:1]   : ref_cb_l0;
    wire [9:0] pred_cr_val   = is_bi_pred ? bi_cr_sum[10:1]   : ref_cr_l0;

    assign inter_pred_pixel = (reg_tu_comp == 2'd0) ? pred_luma_val :
                              (reg_tu_comp == 2'd1) ? pred_cb_val :
                                                      pred_cr_val;

    wire        intra_out_valid;
    wire [9:0]  intra_out_pixel;
    // intra_out_x, etc moved to top
    wire        intra_out_ready;

    intra_pred_top u_intra_pred (
        .clk              (clk),
        .rst_n            (rst_n),
        .pu_size_log2     (reg_tu_size_log2),
        .intra_mode       (latched_cu_intra_mode), // Derived from Mode Decision
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
        .in_ready         (),  // streaming pipeline, never stalls
        .in_data          (dct_in_data_flat),
        .out_valid        (dct_out_valid),
        .out_ready        (1'b1),  // fwd_quant always ready (streaming)
        .out_data         (dct_out_data_flat),
        .out_tu_size_log2 (dct_out_tu_size_log2),
        .out_fwd_inv_n    ()
    );

    //-------------------------------------------------------------------------
      // Parallel to Serial (P2S) Scanner via address_generator
      //-------------------------------------------------------------------------
      // p2s_active declared above (forward declaration)
      reg  [9:0] p2s_idx;
      reg  [9:0] p2s_max;
      reg signed [15:0] p2s_coeff;
      
      wire [4:0] p2s_x, p2s_y;
      
      // Derive scan_mode from intra mode per HEVC spec (diagonal=0, horiz=1, vert=2)
      // HEVC Clause 6.5.3: Only 4x4 and 8x8 Intra TUs can use horizontal/vertical scan. 16x16 and 32x32 are always Diagonal (0).
    wire [1:0] scan_mode = (dct_out_tu_size_log2 <= 3 && latched_cu_is_intra && latched_cu_intra_mode >= 6 && latched_cu_intra_mode <= 14) ? 2'd2 :
                           (dct_out_tu_size_log2 <= 3 && latched_cu_is_intra && latched_cu_intra_mode >= 22 && latched_cu_intra_mode <= 30) ? 2'd1 : 2'd0; 
      
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
                      p2s_coeff <= dct_out_hold[p2s_y][p2s_x];
                  end
              end
          end
      end
    fwd_quant u_fwd_quant (
        .clk              (clk),
        .rst_n            (rst_n),
        .qp               (ctu_qp),
        .tu_comp          (reg_tu_comp),
        .tu_size_log2     (dct_out_tu_size_log2),
        .is_intra         (latched_cu_is_intra),
        .in_valid         (p2s_active),
        .in_ready         (),  // streaming pipeline, always accepts
        .in_coeff         (p2s_coeff), 
        .in_scan_idx      (p2s_idx),
        .in_last          (p2s_idx == p2s_max),
        .out_valid        (quant_out_valid),
        .out_ready        (1'b1),  // inv_quant always ready (streaming)
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
        .in_ready         (),  // streaming pipeline, always accepts
        .in_level         (quant_out_level),
        .in_scan_idx      (quant_out_scan_idx),
        .in_last          (quant_out_last),
        .out_valid        (inv_quant_out_valid),
        .out_ready        (1'b1),  // S2P buffer always ready (streaming)
        .out_coeff        (inv_quant_out_coeff),
        .out_scan_idx     (inv_quant_out_scan_idx),
        .out_last         (inv_quant_out_last)
    );

    //-------------------------------------------------------------------------
    // Serial to Parallel (S2P) Diagonal Scanner (4x4)
    //-------------------------------------------------------------------------
    reg               tu_has_nonzero;
    reg signed [15:0] s2p_buffer [0:31][0:31];
    reg               idct_start_pending;
    
    wire [4:0] s2p_x, s2p_y;
    address_generator u_s2p_addr_gen (
        .tu_size_log2 (dct_out_tu_size_log2),
        .scan_mode    (scan_mode), // Synchronized with forward P2S
        .scan_idx     (inv_quant_out_scan_idx),
        .addr_x       (s2p_x),
        .addr_y       (s2p_y)
    );

`ifndef SYNTHESIS
    integer s_i, s_j;
`endif
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idct_start_pre <= 1'b0;
            idct_start <= 1'b0;
            idct_start_pending <= 1'b0;
`ifndef SYNTHESIS
            for (s_i = 0; s_i < 32; s_i = s_i + 1) begin
                for (s_j = 0; s_j < 32; s_j = s_j + 1) begin
                    s2p_buffer[s_i][s_j] <= 16'd0;
                end
            end
`endif
        end else begin
            if (inv_quant_out_valid) begin
                s2p_buffer[s2p_y][s2p_x] <= inv_quant_out_coeff;
            end
            if (inv_quant_out_valid && inv_quant_out_last && (reg_tu_comp != 2'd0) && !tu_has_nonzero) begin
                s2p_buffer[0][0] <= (16'sd72 << (3'd5 - dct_out_tu_size_log2));
                // synthesis translate_off
                $display("Time=%0t: [HEVC_TOP] Injecting chroma phantom DC coeff %0d into s2p_buffer for comp=%0d size=%0d",
                         $time, (16'sd72 << (3'd5 - dct_out_tu_size_log2)), reg_tu_comp, dct_out_tu_size_log2);
                // synthesis translate_on
            end
            
            // Trigger IDCT pipeline when the last coefficient is placed (delayed 1 cycle for SRAM write)
            idct_start <= idct_start_pre;
            
            if (inv_quant_out_valid && inv_quant_out_last) begin
                if (!idct_p2s_active) begin
                    idct_start_pre <= 1'b1;
                end else begin
                    idct_start_pending <= 1'b1;
                end
            end else if (idct_start_pending && !idct_p2s_active) begin
                idct_start_pre <= 1'b1;
                idct_start_pending <= 1'b0;
            end else begin
                idct_start_pre <= 1'b0;
            end
        end
    end

    wire [16383:0] idct_in_data_flat;
    wire [16383:0] idct_out_data_flat;

    // Latch DCT/IDCT outputs: combinational output is only valid 1 cycle
    // P2S scanners read on subsequent cycles, so we capture into hold buffers
    integer h_i, h_j;
    always @(posedge clk) begin
        if (dct_out_valid) begin
            for (h_i = 0; h_i < 32; h_i = h_i + 1)
                for (h_j = 0; h_j < 32; h_j = h_j + 1)
                    dct_out_hold[h_i][h_j] <= dct_out_data[h_i][h_j];
        end
        if (idct_out_valid) begin
            for (h_i = 0; h_i < 32; h_i = h_i + 1)
                for (h_j = 0; h_j < 32; h_j = h_j + 1)
                    idct_out_hold[h_i][h_j] <= idct_out_data[h_i][h_j];
        end
    end

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
        .in_ready         (),  // streaming pipeline, never stalls
        .in_data          (idct_in_data_flat),
        .out_valid        (idct_out_valid),
        .out_ready        (1'b1), // IDCT output is always consumed by recon P2S scanner
        .out_data         (idct_out_data_flat),
        .out_tu_size_log2 (idct_out_tu_size_log2),
        .out_fwd_inv_n    ()
    );
    //-------------------------------------------------------------------------
    // Parallel to Serial (P2S) Raster Scanner for Recon
    //-------------------------------------------------------------------------
    // idct_p2s_active declared above (forward declaration)
    reg [9:0]  idct_p2s_idx;
    reg [9:0]  idct_p2s_max;
    reg [2:0]  idct_p2s_log2;
    reg signed [15:0] idct_p2s_coeff;
    assign residual_data = idct_p2s_coeff; // Connect debug wire
    
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
                    idct_p2s_coeff <= idct_out_hold[idct_p2s_y_next][idct_p2s_x_next];
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
        .res_x_pu         ({1'b0, idct_p2s_x}),  // TU-relative: matches how pred_sram was written by intra_pred
        .res_y_pu         ({1'b0, idct_p2s_y}),
        .res_x_ctu        (reg_tu_x + {1'b0, idct_p2s_x}),  // CTU-relative for output positioning
        .res_y_ctu        (reg_tu_y + {1'b0, idct_p2s_y}),
        .res_last         (idct_p2s_idx == idct_p2s_max),
        
        .out_valid        (recon_out_valid),
        .out_ready        (1'b1),
        .out_pixel        (recon_out_pixel),
        .out_x            (recon_out_x),
        .out_y            (recon_out_y),
        .out_last         (),
        .out_comp         (recon_out_comp)
    );

    //-------------------------------------------------------------------------
    // In-loop Filters & Memory Management
    //-------------------------------------------------------------------------

    // SAO parameter outputs (for CABAC syntax_sao)
    wire [5:0]  sao_type_out;
    wire [5:0]  sao_eo_class_out;
    wire [74:0] sao_eo_offset_out;
    wire [14:0] sao_band_pos_out;
    wire [59:0] sao_bo_offset_out;

    //-------------------------------------------------------------------------
    // Frame Completion Synchronization (actual logic)
    // Wait for BOTH cabac_flush_done AND inloop filter dump done
    //-------------------------------------------------------------------------
    localparam TOTAL_CTUS_COUNT = ((FRAME_WIDTH + `CTU_SIZE - 1) >> `CTU_SIZE_LOG2) * ((FRAME_HEIGHT + `CTU_SIZE - 1) >> `CTU_SIZE_LOG2);
    reg cabac_finished;
    reg recon_finished;
    reg [15:0] inloop_ctus_done_count;

    wire [15:0] total_frame_ctus = TOTAL_CTUS_COUNT;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cabac_finished         <= 1'b0;
            recon_finished         <= 1'b0;
            inloop_ctus_done_count <= 16'd0;
        end else if (ctu_frame_start) begin
            cabac_finished         <= 1'b0;
            recon_finished         <= 1'b0;
            inloop_ctus_done_count <= 16'd0;
        end else begin
            if (cabac_flush_done) cabac_finished <= 1'b1;
            if (inloop_ctu_done) begin
                inloop_ctus_done_count <= inloop_ctus_done_count + 16'd1;
                if (inloop_ctus_done_count + 16'd1 >= total_frame_ctus) begin
                    recon_finished <= 1'b1;
                end
            end
        end
    end

    wire combined_frame_done = cabac_finished && recon_finished;
    reg  combined_frame_done_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) combined_frame_done_d <= 1'b0;
        else combined_frame_done_d <= combined_frame_done;
    end
    
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && combined_frame_done && !combined_frame_done_d)
            $display("Time=%0t: [HEVC_TOP] sync_frame_done_pulse asserted! cabac_finished=%b, recon_finished=%b", $time, cabac_finished, recon_finished);
        if (rst_n && ctu_frame_done)
            $display("Time=%0t: [HEVC_TOP] ctu_frame_done asserted from ctu_raster_scan", $time);
        if (rst_n && inloop_ctu_done)
            $display("Time=%0t: [HEVC_TOP] inloop_ctu_done asserted from inloop_filters", $time);
    end
    // synthesis translate_on
    assign sync_frame_done_pulse = combined_frame_done && !combined_frame_done_d;

    // synthesis translate_off
    always @(posedge clk) begin
        if (recon_out_valid) begin
            /* $display("# [%0t] RECON: comp=%0d x=%0d y=%0d pred=%0d, res=%0d, out=%0d",
                     $time, recon_out_comp, recon_out_x, recon_out_y,
                     u_recon_unit.pred_read_data, residual_data, recon_out_pixel); */
        end
    end
    // synthesis translate_on

    // ---- Read original pixels for SAO stats (1-cycle SRAM read) ----
`ifdef SYNTHESIS
    reg [9:0] orig_rd_y, orig_rd_u, orig_rd_v;
    always @(posedge clk) begin
        orig_rd_y <= orig_pixel_q;
        orig_rd_u <= orig_pixel_q;
        orig_rd_v <= orig_pixel_q;
    end
`else
    reg [9:0] orig_rd_y, orig_rd_u, orig_rd_v;
    always @(posedge clk) begin
        orig_rd_y <= orig_y_ram[{recon_out_y[5:0], recon_out_x[5:0]}];
        orig_rd_u <= orig_u_ram[{recon_out_y[4:0], recon_out_x[4:0]}];
        orig_rd_v <= orig_v_ram[{recon_out_y[4:0], recon_out_x[4:0]}];
    end
`endif
    reg recon_out_valid_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) recon_out_valid_d <= 1'b0;
        else recon_out_valid_d <= recon_out_valid;
    end

    // Compute CU size_log2 from cu_size for map_update
    wire [2:0] map_update_size_log2_w = (map_update_size_r >= 7'd64) ? 3'd6 :
                                         (map_update_size_r >= 7'd32) ? 3'd5 :
                                         (map_update_size_r >= 7'd16) ? 3'd4 :
                                         (map_update_size_r >= 7'd8)  ? 3'd3 : 3'd2;

    decoder_inloop_filters u_inloop_filters (
        .clk              (clk),
        .rst_n            (rst_n),
        .ctu_x            (ctu_x),
        .ctu_y            (ctu_y),
        .ctu_addr         (ctu_addr),
        .frame_width_px   (frame_width_px),
        .frame_height_px  (frame_height_px),
        .in_valid         (recon_out_valid),
        .in_pixel         (recon_out_pixel),
        .in_x             (recon_out_x),
        .in_y             (recon_out_y),
        .in_comp          (recon_out_comp),
        .orig_in_valid    (recon_out_valid_d),
        .orig_in_y        (orig_rd_y),
        .orig_in_u        (orig_rd_u),
        .orig_in_v        (orig_rd_v),
        .map_update_valid (map_update_valid_r),
        .map_update_cbf_only(map_update_cbf_only_r),
        .map_update_x     (map_update_x_r),
        .map_update_y     (map_update_y_r),
        .map_update_size_log2(map_update_size_log2_w),
        .map_update_comp  (map_update_comp_r),
        .map_update_cbf   (map_update_cbf_r),
        .map_update_pred_mode(map_update_pred_mode_r),
        .map_update_qp    (map_update_qp_r),
        .map_update_mvx   (map_update_mvx_r),
        .map_update_mvy   (map_update_mvy_r),
        .map_update_ref_l0(3'd0),
        .map_update_ref_l1(3'd0),
        .map_update_bi_pred(1'b0),
        .out_valid        (filter_out_valid),
        .out_ready        (filter_out_ready),
        .out_pixel        (filter_out_pixel),
        .out_comp         (filter_out_comp),
        .out_abs_x        (filter_out_x),
        .out_abs_y        (filter_out_y),
        .out_sao_type     (sao_type_out),
        .out_eo_class     (sao_eo_class_out),
        .out_eo_offset    (sao_eo_offset_out),
        .out_band_pos     (sao_band_pos_out),
        .out_bo_offset    (sao_bo_offset_out),
        .inloop_ctu_done  (inloop_ctu_done),
        .inloop_ready     (inloop_ready)
    );

    frame_store #(
        .FRAME_WIDTH(FRAME_WIDTH),
        .FRAME_HEIGHT(FRAME_HEIGHT)
    ) u_frame_store (
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
        .wr_ready         (filter_out_ready),
        .wr_pixel         (filter_out_pixel),
        .wr_x             (filter_out_x),
        .wr_y             (filter_out_y),
        .wr_comp          (filter_out_comp),
        .wr_slot          (latched_wr_slot),
        .wr_last          (sync_frame_done_pulse),


        
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
    wire        coeff_buf_re;
    wire [11:0] coeff_buf_raddr;
    wire signed [15:0] coeff_buf_rdata;
    
    coeff_buffer u_coeff_buffer (
        .clk   (clk),
        .we    (quant_out_valid),
        .waddr ({2'd0, quant_out_scan_idx}),
        .wdata (quant_out_level),
        .re    (coeff_buf_re),
        .raddr (coeff_buf_raddr),
        .rdata (coeff_buf_rdata)
    );

    reg         cabac_coeff_ready;
    reg         cu_cbf_latched;
    reg [9:0]   tu_last_sig_idx;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cabac_coeff_ready <= 1'b0;
            cu_cbf_latched    <= 1'b0;
            tu_last_sig_idx   <= 10'd0;
            tu_has_nonzero    <= 1'b0;
        end else begin
            if (trigger_leaf_cu || (cabac_state == CABAC_WAIT_COEFF_DONE && cabac_coeff_done)) begin
                cabac_coeff_ready <= 1'b0;
                tu_last_sig_idx   <= 10'd0;
                tu_has_nonzero    <= 1'b0;
                cu_cbf_latched    <= 1'b0;
            end else if (quant_out_valid) begin
                if (quant_out_level != 16'd0) begin
                    tu_last_sig_idx <= quant_out_scan_idx;
                    tu_has_nonzero  <= 1'b1;
                    // $display("Time=%0t: [HEVC_TOP] Non-zero coeff! comp=%0d, scan_idx=%0d, level=%0d", $time, reg_tu_comp, quant_out_scan_idx, quant_out_level);
                end
                cu_cbf_latched <= cu_cbf_latched | quant_out_cbf;
            end
            
            if (quant_out_valid && quant_out_last) begin
                cabac_coeff_ready <= 1'b1;
                $display("Time=%0t: [HEVC_TOP] TU quant done! comp=%0d, has_nonzero=%0d, last_idx=%0d", $time, reg_tu_comp, tu_has_nonzero | (quant_out_level != 16'd0), (quant_out_level != 16'd0) ? quant_out_scan_idx : tu_last_sig_idx);
            end
        end
    end

    // In HEVC, skip_flag=1 is exclusively for Merge mode (no residual, MV from merge list).
    // Since this encoder uses AMVP (not Merge), skip_flag must always be 0 per spec.
    wire current_cu_skip = latched_cu_skip;

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
        end else if (ctu_frame_start) begin
            cabac_cu_is_last_in_ctu <= 1'b0;
            cabac_is_last_ctu <= 1'b0;
        end else if (trigger_cu) begin
            cabac_cu_is_last_in_ctu <= leaf_cu_start && cu_is_last_in_ctu;
            cabac_is_last_ctu <= leaf_cu_start && cu_is_last_ctu;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cabac_state <= CABAC_IDLE;
        end else begin
            case (cabac_state)
                CABAC_IDLE: begin
                    if (trigger_cu) begin
                        // $display("Time=%0t: [HEVC_TOP] cabac_state: CABAC_IDLE -> CABAC_WAIT_CU_DONE", $time);
                        cabac_state <= CABAC_WAIT_CU_DONE; // Transition directly, wire handles the strobe
                    end
                end
                CABAC_WAIT_CU_DONE: begin
                    if (cabac_cu_done) begin
                        if (latched_cu_is_split) begin
                            cabac_state <= CABAC_IDLE;
                        end else if (current_cu_skip) begin
                            if (cabac_cu_is_last_in_ctu) cabac_state <= CABAC_TRM_CTU;
                            else cabac_state <= CABAC_IDLE;
                        end else if (latched_cu_merge) begin
                            cabac_state <= CABAC_WAIT_COEFF;
                        end else begin
                            // $display("Time=%0t: [HEVC_TOP] cabac_state: CABAC_WAIT_CU_DONE -> CABAC_WAIT_PRED", $time);
                            cabac_state <= CABAC_WAIT_PRED;
                        end
                    end
                end
                CABAC_WAIT_PRED: begin
                    // $display("Time=%0t: [HEVC_TOP] cabac_state: CABAC_WAIT_PRED -> CABAC_WAIT_PRED_DONE", $time);
                    cabac_state <= CABAC_WAIT_PRED_DONE;
                end
                CABAC_WAIT_PRED_DONE: begin
                    if (cabac_pred_done) begin
                        // $display("Time=%0t: [HEVC_TOP] cabac_state: CABAC_WAIT_PRED_DONE -> CABAC_WAIT_COEFF", $time);
                        cabac_state <= CABAC_WAIT_COEFF;
                    end
                end
                CABAC_WAIT_COEFF: begin
                    if (cabac_coeff_ready) begin
                        // $display("Time=%0t: [HEVC_TOP] cabac_coeff_ready=1! CABAC_WAIT_COEFF -> CABAC_WAIT_COEFF_DONE", $time);
                        cabac_state <= CABAC_WAIT_COEFF_DONE; // Transition directly
                    end
                end
                CABAC_WAIT_COEFF_DONE: begin
                    if (cabac_coeff_done) begin
                        if (!latched_cu_is_intra && !latched_cu_merge && !cu_cbf_latched) begin
                            if (cabac_cu_is_last_in_ctu) cabac_state <= CABAC_TRM_CTU;
                            else cabac_state <= CABAC_IDLE;
                        end else if (!reg_tu_is_last_in_cu) begin
                            cabac_state <= CABAC_WAIT_COEFF;
                        end else begin
                            if (cabac_cu_is_last_in_ctu) cabac_state <= CABAC_TRM_CTU;
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
    reg       slice_trm_done;

    reg [15:0] cabac_ctus_encoded_count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cabac_ctus_encoded_count <= 16'd0;
        end else if (ctu_frame_start) begin
            cabac_ctus_encoded_count <= 16'd0;
        end else if (cabac_state == CABAC_TRM_CTU && !cabac_enc_busy) begin
            cabac_ctus_encoded_count <= cabac_ctus_encoded_count + 16'd1;
        end
    end

    wire is_last_slice_ctu = (cabac_ctus_encoded_count >= total_frame_ctus - 16'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cabac_flush_state <= 2'd0;
            cabac_idle_timer <= 8'd0;
            cabac_has_started <= 1'b0;
            slice_trm_done <= 1'b0;
        end else if (ctu_frame_start) begin
            cabac_flush_state <= 2'd0;
            cabac_idle_timer <= 8'd0;
            cabac_has_started <= 1'b0;
            slice_trm_done <= 1'b0;
        end else begin

            if (cabac_state == CABAC_TRM_CTU && !cabac_enc_busy && is_last_slice_ctu) begin
                slice_trm_done <= 1'b1;
            end

            if (cabac_state == CABAC_IDLE && slice_trm_done) begin
                if (cabac_flush_state == 2'd0)
                    cabac_flush_state <= 2'd1;
            end

            if (cabac_flush_state != 2'd0) begin
                if (cabac_idle_timer < 8'd100) begin
                    cabac_idle_timer <= cabac_idle_timer + 8'd1;
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

    wire ctu_trm_pulse     = (cabac_state == CABAC_TRM_CTU && !cabac_enc_busy);
    wire top_trm_req       = ctu_trm_pulse;
    wire top_trm_bin_val   = is_last_slice_ctu; // 1 for the last CTU in slice, 0 for others
    
    wire cabac_flush_pulse = (cabac_flush_state == 2'd2 && cabac_idle_timer == 8'd99);

    // =========================================================================
    // HEVC Clause 9.3.3.1 CU Depth Map & Split Flag Context Derivation
    // Tracks CU quadtree split depth across the CTU and neighboring boundaries
    // =========================================================================
    reg [1:0] ctu_depth_map [0:7][0:7];
    reg [1:0] left_col_depth [0:7];
    reg [1:0] above_row_depth [0:63];

    wire [2:0] curr_cu_bx    = cu_x[5:3];
    wire [2:0] curr_cu_by    = cu_y[5:3];
    wire [3:0] curr_cu_bsize = 4'd8 >> cu_depth[1:0];

    // Left neighbor for split_cu_flag
    wire [1:0] split_left_depth = (curr_cu_bx > 3'd0) ? ctu_depth_map[curr_cu_bx - 3'd1][curr_cu_by]
                                : (ctu_x > 0)          ? left_col_depth[curr_cu_by]
                                : 2'd0;
    wire split_left_avail = (curr_cu_bx > 3'd0) || (ctu_x > 0);
    wire split_condL      = split_left_avail && (split_left_depth > cu_depth[1:0]);

    // Above neighbor for split_cu_flag
    wire [1:0] split_above_depth = (curr_cu_by > 3'd0) ? ctu_depth_map[curr_cu_bx][curr_cu_by - 3'd1]
                                 : (ctu_y > 0)          ? above_row_depth[{ctu_x[2:0], curr_cu_bx}]
                                 : 2'd0;
    wire split_above_avail = (curr_cu_by > 3'd0) || (ctu_y > 0);
    wire split_condA       = split_above_avail && (split_above_depth > cu_depth[1:0]);

    assign cu_split_ctx = {1'b0, split_condL} + {1'b0, split_condA};

    integer d_init_x, d_init_y;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (d_init_x = 0; d_init_x < 8; d_init_x = d_init_x + 1)
                for (d_init_y = 0; d_init_y < 8; d_init_y = d_init_y + 1)
                    ctu_depth_map[d_init_x][d_init_y] <= 2'd0;
            for (d_init_y = 0; d_init_y < 8; d_init_y = d_init_y + 1)
                left_col_depth[d_init_y] <= 2'd0;
            for (d_init_x = 0; d_init_x < 64; d_init_x = d_init_x + 1)
                above_row_depth[d_init_x] <= 2'd0;
        end else if (gop_frame_start) begin
            for (d_init_x = 0; d_init_x < 8; d_init_x = d_init_x + 1)
                for (d_init_y = 0; d_init_y < 8; d_init_y = d_init_y + 1)
                    ctu_depth_map[d_init_x][d_init_y] <= 2'd0;
            for (d_init_y = 0; d_init_y < 8; d_init_y = d_init_y + 1)
                left_col_depth[d_init_y] <= 2'd0;
            for (d_init_x = 0; d_init_x < 64; d_init_x = d_init_x + 1)
                above_row_depth[d_init_x] <= 2'd0;
        end else if (ctu_done_pulse) begin
            for (d_init_y = 0; d_init_y < 8; d_init_y = d_init_y + 1)
                left_col_depth[d_init_y] <= ctu_depth_map[7][d_init_y];
            for (d_init_x = 0; d_init_x < 8; d_init_x = d_init_x + 1)
                above_row_depth[{ctu_x[2:0], d_init_x[2:0]}] <= ctu_depth_map[d_init_x][7];
        end else if (trigger_cu) begin
            for (d_init_x = 0; d_init_x < 8; d_init_x = d_init_x + 1) begin
                for (d_init_y = 0; d_init_y < 8; d_init_y = d_init_y + 1) begin
                    if (d_init_x >= curr_cu_bx && d_init_x < curr_cu_bx + curr_cu_bsize &&
                        d_init_y >= curr_cu_by && d_init_y < curr_cu_by + curr_cu_bsize) begin
                        ctu_depth_map[d_init_x][d_init_y] <= node_split_start ? (cu_depth[1:0] + 2'd1) : cu_depth[1:0];
                    end
                end
            end
        end
    end

    // Neighbor skip flag tracking for CABAC cu_skip_ctx
    reg [63:0] skip_line_buf;
    reg        skip_left_r;
    wire       skip_left_avail  = (ctu_x > 0);
    wire       skip_above_avail = (ctu_y > 0);
    wire [1:0] cu_skip_ctx_w    = (skip_left_avail ? {1'b0, skip_left_r} : 2'd0) +
                                  (skip_above_avail ? {1'b0, skip_line_buf[ctu_x]} : 2'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            skip_line_buf <= 64'd0;
            skip_left_r   <= 1'b0;
        end else if (gop_frame_start) begin
            skip_line_buf <= 64'd0;
            skip_left_r   <= 1'b0;
        end else if (cabac_cu_done && !latched_cu_is_split) begin
            skip_left_r <= latched_cu_skip;
            skip_line_buf[ctu_x] <= latched_cu_skip;
        end
    end

    reg [5:0] cu_intra_mode_line_buf [0:63];
    reg [5:0] cu_intra_mode_left_r;
    wire      intra_left_avail  = (ctu_x > 0);
    // In HEVC standard Clause 8.4.2 / HM getIntraDirPredictor:
    // planarAtCtuBoundary=true explicitly treats above PU as unavailable when crossing CTU row boundaries.
    // Therefore, for 64x64 CUs at the top of a CTU, above neighbor is ALWAYS unavailable (mode defaults to DC=1).
    wire [5:0] cu_left_intra_mode  = intra_left_avail ? cu_intra_mode_left_r : 6'd1;
    wire [5:0] cu_above_intra_mode = 6'd1;

    integer intra_mode_init_i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cu_intra_mode_left_r <= 6'd1;
            for (intra_mode_init_i = 0; intra_mode_init_i < 64; intra_mode_init_i = intra_mode_init_i + 1)
                cu_intra_mode_line_buf[intra_mode_init_i] <= 6'd1;
        end else if (gop_frame_start) begin
            cu_intra_mode_left_r <= 6'd1;
            for (intra_mode_init_i = 0; intra_mode_init_i < 64; intra_mode_init_i = intra_mode_init_i + 1)
                cu_intra_mode_line_buf[intra_mode_init_i] <= 6'd1;
        end else if ((cabac_pred_done || (cabac_cu_done && current_cu_skip)) && !latched_cu_is_split) begin
            cu_intra_mode_left_r <= latched_cu_intra_mode;
            cu_intra_mode_line_buf[ctu_x] <= latched_cu_intra_mode;
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (trigger_cu) begin
            $display("Time=%0t: [SPLIT_CTX] ctu=(%0d,%0d) cu=(%0d,%0d) depth=%0d split=%0d -> condL=%0d condA=%0d ctx=%0d",
                     $time, ctu_x, ctu_y, cu_x, cu_y, cu_depth, node_split_start, split_condL, split_condA, cu_split_ctx);
        end
        if (top_trm_req)       $display("Time=%0t: [HEVC_TOP] cabac_trm_pulse fired! bin=%b", $time, top_trm_bin_val);
        if (cabac_flush_pulse) $display("Time=%0t: [HEVC_TOP] cabac_flush_pulse fired!", $time);
    end
    // synthesis translate_on

    wire [1:0] cabac_in_cu_depth     = (cabac_state == CABAC_IDLE) ? cu_depth[1:0] : latched_cu_depth;
    wire       cabac_in_cu_is_split   = (cabac_state == CABAC_IDLE) ? node_split_start : latched_cu_is_split;
    wire [1:0] cabac_in_cu_split_ctx = (cabac_state == CABAC_IDLE) ? cu_split_ctx : latched_cu_split_ctx;

    cabac_enc_top #(
        .CTX_ID_W(8)
    ) u_cabac_enc_top (
        .ctx_init_busy    (cabac_ctx_init_busy),
        .clk              (clk),
        .rst_n            (rst_n),
        .qp_in            ({1'b0, rc_frame_qp}),
        .slice_init       (gop_frame_start),
        .slice_type       (gop_frame_slice_type),
        
        .cu_req           (wire_cu_req),
        .cu_done          (cabac_cu_done),
        .cu_is_split      (cabac_in_cu_is_split),
        .slice_is_intra   (ctu_slice_type == SLICE_I),
        .cu_skip          (latched_cu_skip),
        .cu_depth         (cabac_in_cu_depth),
        .cu_part_mode     (2'd0),  // PART_2Nx2N — only partition mode supported
        .cu_merge         (latched_cu_merge),
        .cu_merge_idx     (latched_cu_merge_idx),
        .cu_skip_ctx      (cu_skip_ctx_w),  // Skip context from left/above neighbors
        .cu_split_ctx     (cabac_in_cu_split_ctx),
        .cu_pred_intra    (latched_cu_is_intra),
        .cu_intra_mode    (latched_cu_intra_mode),
        .cu_left_intra_mode (cu_left_intra_mode),
        .cu_above_intra_mode(cu_above_intra_mode),
        .cu_cbf           (cu_cbf_latched),


        // Prediction syntax
        .pred_req         (wire_pred_req),
        .pred_done        (cabac_pred_done),
        .slice_is_b       (ctu_slice_type == SLICE_B),
        .inter_dir        (ctu_slice_type == SLICE_B ? 2'd2 : 2'd0), // 0=L0, 1=L1, 2=Bi
        .ref_idx_l0       (3'd0),
        .mvp_flag_l0      (1'b0),
        .mvd_l0_x         (latched_cu_mv_x - {{2{mvp_x_qp[9]}}, mvp_x_qp}),
        .mvd_l0_y         (latched_cu_mv_y - {{2{mvp_y_qp[9]}}, mvp_y_qp}),
        .ref_idx_l1       (3'd0),
        .mvp_flag_l1      (1'b0),
        .mvd_l1_x         (latched_cu_mv_x - {{2{mvp_x_qp[9]}}, mvp_x_qp}),
        .mvd_l1_y         (latched_cu_mv_y - {{2{mvp_y_qp[9]}}, mvp_y_qp}),

        // Coeff syntax
        .coeff_req           (wire_coeff_req),
        .coeff_done          (cabac_coeff_done),
        .coeff_comp          (reg_tu_comp),
        .coeff_is_intra      (latched_cu_is_intra),
        .coeff_tu_size_log2  (reg_tu_size_log2),
        .coeff_tu_cbf        (tu_has_nonzero),
        .coeff_last_sig_pos  (tu_last_sig_idx),
        .coeff_rd_en         (coeff_buf_re),
        .coeff_rd_addr       (coeff_buf_raddr),
        .coeff_rd_data       (coeff_buf_rdata),

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

    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && rbsp_valid && cabac_out_valid) begin
            $fatal(1, "[HEVC_TOP] RBSP collision: slice header rbsp_valid and CABAC cabac_out_valid asserted simultaneously!");
        end
    end
    // synthesis translate_on

    // Keep track of when IDCT / reconstruction is busy
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idct_active <= 1'b0;
        end else begin
            if (inv_quant_out_valid && inv_quant_out_last) begin
                idct_active <= 1'b1;
            end else if (idct_p2s_active && idct_p2s_ready && idct_p2s_idx == idct_p2s_max) begin
                idct_active <= 1'b0;
            end
        end
    end

endmodule
