//=============================================================================
// decoder_inloop_filters.v
// Decoder In-loop Filters — Deblock + SAO integration wrapper
//
// Pipeline per CTU:
//   S_FILL  — receive 6144 recon pixels into SRAMs + original pixels
//   S_DB    — run deblock_top (reads/writes SRAMs in-place)
//   S_STATS — run sao_stats (reads SRAMs + original, decides SAO params)
//   S_SAO   — run sao_top (reads/writes SRAMs with SAO offsets)
//   S_DUMP  — output all 6144 pixels (Y/Cb/Cr) to DPB via frame_store
//=============================================================================

`include "parameter_pkg.vh"

module decoder_inloop_filters (
    input  wire         clk,
    input  wire         rst_n,

    // CTU position
    input  wire [`CTU_COORD_WIDTH-1:0] ctu_x,
    input  wire [`CTU_COORD_WIDTH-1:0] ctu_y,
    input  wire [`CTU_ADDR_WIDTH-1:0]  ctu_addr,
    input  wire [`FRAME_DIM_WIDTH-1:0] frame_width_px,
    input  wire [`FRAME_DIM_WIDTH-1:0] frame_height_px,

    // Reconstructed pixel input (from recon_unit)
    input  wire         in_valid,
    input  wire [9:0]   in_pixel,
    input  wire [5:0]   in_x,
    input  wire [5:0]   in_y,
    input  wire [1:0]   in_comp,

    // Original pixel input (for SAO stats RDO)
    input  wire         orig_in_valid,
    input  wire [9:0]   orig_in_y,
    input  wire [9:0]   orig_in_u,
    input  wire [9:0]   orig_in_v,

    // CU map update (for deblock boundary strength)
    input  wire         map_update_valid,
    input  wire         map_update_cbf_only,
    input  wire [5:0]   map_update_x,
    input  wire [5:0]   map_update_y,
    input  wire [2:0]   map_update_size_log2,
    input  wire [1:0]   map_update_comp,
    input  wire         map_update_cbf,
    input  wire         map_update_pred_mode,
    input  wire [5:0]   map_update_qp,
    input  wire [15:0]  map_update_mvx,
    input  wire [15:0]  map_update_mvy,
    input  wire [2:0]   map_update_ref_l0,
    input  wire [2:0]   map_update_ref_l1,
    input  wire         map_update_bi_pred,

    // Output to DPB (Frame Store)
    output reg          out_valid,
    input  wire         out_ready,    // backpressure from frame_store
    output reg  [9:0]   out_pixel,
    output reg  [1:0]   out_comp,
    output reg  [11:0]  out_abs_x,
    output reg  [11:0]  out_abs_y,

    // SAO parameters output (for CABAC encoding)
    output wire [5:0]   out_sao_type,
    output wire [5:0]   out_eo_class,
    output wire [74:0]  out_eo_offset,
    output wire [14:0]  out_band_pos,
    output wire [59:0]  out_bo_offset,

    // Done
    output reg          inloop_ctu_done,
    output wire         inloop_ready
);

    //=========================================================================
    // FSM
    //=========================================================================
    localparam [2:0]
        S_FILL  = 3'd0,
        S_DB    = 3'd1,
        S_STATS = 3'd2,
        S_SAO   = 3'd3,
        S_DUMP  = 3'd4;

    reg [2:0] filter_state;
    assign inloop_ready = (filter_state == S_FILL);

    //=========================================================================
    // SRAM Buffers — reconstructed pixels
    //=========================================================================
    (* ramstyle = "M10K, no_rw_check" *) reg [9:0] luma_ram [0:4095];   // 64x64
    (* ramstyle = "M10K, no_rw_check" *) reg [9:0] cb_ram   [0:1023];   // 32x32
    (* ramstyle = "M10K, no_rw_check" *) reg [9:0] cr_ram   [0:1023];   // 32x32

    // Original pixel SRAMs (for SAO stats)
    (* ramstyle = "M10K, no_rw_check" *) reg [9:0] orig_y_ram [0:4095];
    (* ramstyle = "M10K, no_rw_check" *) reg [9:0] orig_u_ram [0:1023];
    (* ramstyle = "M10K, no_rw_check" *) reg [9:0] orig_v_ram [0:1023];

    //=========================================================================
    // Cross-CTU Line Buffers and Column Buffers (Phase 2 Deblocking)
    //=========================================================================
    // 4-row Line Buffer (holds bottom rows of CTU row above; up to 128 px wide)
    reg [9:0] line_buf_luma [0:3][0:127];
    reg [9:0] line_buf_cb   [0:1][0:63];
    reg [9:0] line_buf_cr   [0:1][0:63];

    // 4-column Buffer (holds rightmost columns of left neighbor CTU)
    reg [9:0] col_buf_luma [0:63][0:3];
    reg [9:0] col_buf_cb   [0:31][0:3];
    reg [9:0] col_buf_cr   [0:31][0:3];

    // Neighbor CU Metadata Caches
    // Left CTU's rightmost column (column 15, rows 0..15)
    reg [15:0]   left_map_pred_mode;
    reg [15:0]   left_map_cbf_luma;
    reg [15:0]   left_map_cbf_chroma;
    reg [47:0]   left_map_ref_l0;
    reg [47:0]   left_map_ref_l1;
    reg [15:0]   left_map_bi_pred;
    reg [255:0]  left_map_mvx_l0;
    reg [255:0]  left_map_mvy_l0;
    reg [255:0]  left_map_mvx_l1;
    reg [255:0]  left_map_mvy_l1;
    reg [95:0]   left_map_qp;

    // Above CTU's bottom row (row 15, cols 0..31 for 2 CTUs)
    reg [31:0]   top_map_pred_mode;
    reg [31:0]   top_map_cbf_luma;
    reg [31:0]   top_map_cbf_chroma;
    reg [95:0]   top_map_ref_l0;
    reg [95:0]   top_map_ref_l1;
    reg [31:0]   top_map_bi_pred;
    reg [511:0]  top_map_mvx_l0;
    reg [511:0]  top_map_mvy_l0;
    reg [511:0]  top_map_mvx_l1;
    reg [511:0]  top_map_mvy_l1;
    reg [191:0]  top_map_qp;

    // 4x4 Corner Buffer (holds bottom-right of CTU 0 across CTU 2 execution)
    reg [9:0] corner_buf_luma [0:3][0:3];
    reg [9:0] corner_buf_cb   [0:1][0:3];
    reg [9:0] corner_buf_cr   [0:1][0:3];
    reg        corner_pred_mode;
    reg [5:0]  corner_qp;
    reg        corner_cbf_luma;
    reg        corner_cbf_chroma;
    reg [2:0]  corner_ref_l0;
    reg [2:0]  corner_ref_l1;
    reg        corner_bi_pred;
    reg signed [15:0] corner_mvx_l0;
    reg signed [15:0] corner_mvy_l0;
    reg signed [15:0] corner_mvx_l1;
    reg signed [15:0] corner_mvy_l1;

    integer init_i, init_j;
    initial begin
        for (init_i = 0; init_i < 4; init_i = init_i + 1)
            for (init_j = 0; init_j < 128; init_j = init_j + 1)
                line_buf_luma[init_i][init_j] = 10'd0;
        for (init_i = 0; init_i < 2; init_i = init_i + 1)
            for (init_j = 0; init_j < 64; init_j = init_j + 1) begin
                line_buf_cb[init_i][init_j] = 10'd0;
                line_buf_cr[init_i][init_j] = 10'd0;
            end
        for (init_i = 0; init_i < 64; init_i = init_i + 1)
            for (init_j = 0; init_j < 4; init_j = init_j + 1)
                col_buf_luma[init_i][init_j] = 10'd0;
        for (init_i = 0; init_i < 32; init_i = init_i + 1)
            for (init_j = 0; init_j < 4; init_j = init_j + 1) begin
                col_buf_cb[init_i][init_j] = 10'd0;
                col_buf_cr[init_i][init_j] = 10'd0;
            end
        for (init_i = 0; init_i < 2; init_i = init_i + 1)
            for (init_j = 0; init_j < 4; init_j = init_j + 1) begin
                corner_buf_cb[init_i][init_j] = 10'd0;
                corner_buf_cr[init_i][init_j] = 10'd0;
            end
    end

    //=========================================================================
    // Counters
    //=========================================================================
    reg [12:0] pixel_count;
    reg [12:0] dump_count;
    reg [`CTU_COORD_WIDTH-1:0] cur_ctu_x, cur_ctu_y;

    wire ctu_recon_done = in_valid && (pixel_count == 13'd6143);

    //=========================================================================
    // Shadow Maps for Deblock
    //=========================================================================
    reg [255:0]  cu_map_pred_mode;
    reg [255:0]  cu_map_cbf_luma;
    reg [255:0]  cu_map_cbf_chroma;
    reg [767:0]  cu_map_ref_l0;
    reg [767:0]  cu_map_ref_l1;
    reg [255:0]  cu_map_bi_pred;
    reg [4095:0] cu_map_mvx_l0;
    reg [4095:0] cu_map_mvy_l0;
    reg [4095:0] cu_map_mvx_l1;
    reg [4095:0] cu_map_mvy_l1;
    reg [1535:0] cu_map_qp;

    integer map_i, map_j, c_k;
    wire [3:0] map_luma_log2 = (map_update_comp == 2'd0) ? map_update_size_log2 : (map_update_size_log2 + 3'd1);
    wire [3:0] map_blk_mask  = (map_luma_log2 >= 4'd6) ? 4'b0000 :
                               (map_luma_log2 == 4'd5) ? 4'b1000 :
                               (map_luma_log2 == 4'd4) ? 4'b1100 :
                               (map_luma_log2 == 4'd3) ? 4'b1110 : 4'b1111;
    wire [5:0] map_up_x_luma = (map_update_comp == 2'd0) ? map_update_x : {map_update_x[4:0], 1'b0};
    wire [5:0] map_up_y_luma = (map_update_comp == 2'd0) ? map_update_y : {map_update_y[4:0], 1'b0};
    wire [3:0] map_cx = map_up_x_luma[5:2];
    wire [3:0] map_cy = map_up_y_luma[5:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cu_map_pred_mode  <= 256'd0;
            cu_map_cbf_luma   <= 256'd0;
            cu_map_cbf_chroma <= 256'd0;
            cu_map_ref_l0     <= 768'd0;
            cu_map_ref_l1     <= 768'd0;
            cu_map_bi_pred    <= 256'd0;
            cu_map_mvx_l0     <= 4096'd0;
            cu_map_mvy_l0     <= 4096'd0;
            cu_map_mvx_l1     <= 4096'd0;
            cu_map_mvy_l1     <= 4096'd0;
            cu_map_qp         <= 1536'd0;

            left_map_pred_mode  <= 16'd0;
            left_map_cbf_luma   <= 16'd0;
            left_map_cbf_chroma <= 16'd0;
            left_map_ref_l0     <= 48'd0;
            left_map_ref_l1     <= 48'd0;
            left_map_bi_pred    <= 16'd0;
            left_map_mvx_l0     <= 256'd0;
            left_map_mvy_l0     <= 256'd0;
            left_map_mvx_l1     <= 256'd0;
            left_map_mvy_l1     <= 256'd0;
            left_map_qp         <= 96'd0;

            top_map_pred_mode   <= 32'd0;
            top_map_cbf_luma    <= 32'd0;
            top_map_cbf_chroma  <= 32'd0;
            top_map_ref_l0      <= 96'd0;
            top_map_ref_l1      <= 96'd0;
            top_map_bi_pred     <= 32'd0;
            top_map_mvx_l0      <= 512'd0;
            top_map_mvy_l0      <= 512'd0;
            top_map_mvx_l1      <= 512'd0;
            top_map_mvy_l1      <= 512'd0;
            top_map_qp          <= 192'd0;
            corner_pred_mode   <= 1'b0;
            corner_qp          <= 6'd0;
            corner_cbf_luma    <= 1'b0;
            corner_cbf_chroma  <= 1'b0;
            corner_ref_l0      <= 3'd0;
            corner_ref_l1      <= 3'd0;
            corner_bi_pred     <= 1'b0;
            corner_mvx_l0      <= 16'd0;
            corner_mvy_l0      <= 16'd0;
            corner_mvx_l1      <= 16'd0;
            corner_mvy_l1      <= 16'd0;
        end else begin
            // Clear CBFs and latch neighbor CU caches when CTU finishes dumping to frame store
            if (filter_state == S_DUMP && out_ready && dump_count == 13'd6143) begin
                cu_map_cbf_luma   <= 256'd0;
                cu_map_cbf_chroma <= 256'd0;

                if (cur_ctu_x == 0 && cur_ctu_y == 0) begin
                    corner_pred_mode   <= cu_map_pred_mode[(15*16) + 15];
                    corner_qp          <= cu_map_qp[((15*16) + 15)*6 +: 6];
                    corner_cbf_luma    <= cu_map_cbf_luma[(15*16) + 15];
                    corner_cbf_chroma  <= cu_map_cbf_chroma[(15*16) + 15];
                    corner_ref_l0      <= cu_map_ref_l0[((15*16) + 15)*3 +: 3];
                    corner_ref_l1      <= cu_map_ref_l1[((15*16) + 15)*3 +: 3];
                    corner_bi_pred     <= cu_map_bi_pred[(15*16) + 15];
                    corner_mvx_l0      <= cu_map_mvx_l0[((15*16) + 15)*16 +: 16];
                    corner_mvy_l0      <= cu_map_mvy_l0[((15*16) + 15)*16 +: 16];
                    corner_mvx_l1      <= cu_map_mvx_l1[((15*16) + 15)*16 +: 16];
                    corner_mvy_l1      <= cu_map_mvy_l1[((15*16) + 15)*16 +: 16];
                end

                for (c_k = 0; c_k < 16; c_k = c_k + 1) begin
                    left_map_pred_mode[c_k]              <= cu_map_pred_mode[(c_k*16) + 15];
                    left_map_cbf_luma[c_k]               <= cu_map_cbf_luma[(c_k*16) + 15];
                    left_map_cbf_chroma[c_k]             <= cu_map_cbf_chroma[(c_k*16) + 15];
                    left_map_ref_l0[c_k*3 +: 3]          <= cu_map_ref_l0[((c_k*16) + 15)*3 +: 3];
                    left_map_ref_l1[c_k*3 +: 3]          <= cu_map_ref_l1[((c_k*16) + 15)*3 +: 3];
                    left_map_bi_pred[c_k]                <= cu_map_bi_pred[(c_k*16) + 15];
                    left_map_mvx_l0[c_k*16 +: 16]        <= cu_map_mvx_l0[((c_k*16) + 15)*16 +: 16];
                    left_map_mvy_l0[c_k*16 +: 16]        <= cu_map_mvy_l0[((c_k*16) + 15)*16 +: 16];
                    left_map_mvx_l1[c_k*16 +: 16]        <= cu_map_mvx_l1[((c_k*16) + 15)*16 +: 16];
                    left_map_mvy_l1[c_k*16 +: 16]        <= cu_map_mvy_l1[((c_k*16) + 15)*16 +: 16];
                    left_map_qp[c_k*6 +: 6]              <= cu_map_qp[((c_k*16) + 15)*6 +: 6];

                    if (cur_ctu_x[0]) begin
                        top_map_pred_mode[16 + c_k]              <= cu_map_pred_mode[(15*16) + c_k];
                        top_map_cbf_luma[16 + c_k]               <= cu_map_cbf_luma[(15*16) + c_k];
                        top_map_cbf_chroma[16 + c_k]             <= cu_map_cbf_chroma[(15*16) + c_k];
                        top_map_ref_l0[(16 + c_k)*3 +: 3]        <= cu_map_ref_l0[((15*16) + c_k)*3 +: 3];
                        top_map_ref_l1[(16 + c_k)*3 +: 3]        <= cu_map_ref_l1[((15*16) + c_k)*3 +: 3];
                        top_map_bi_pred[16 + c_k]                <= cu_map_bi_pred[(15*16) + c_k];
                        top_map_mvx_l0[(16 + c_k)*16 +: 16]      <= cu_map_mvx_l0[((15*16) + c_k)*16 +: 16];
                        top_map_mvy_l0[(16 + c_k)*16 +: 16]      <= cu_map_mvy_l0[((15*16) + c_k)*16 +: 16];
                        top_map_mvx_l1[(16 + c_k)*16 +: 16]      <= cu_map_mvx_l1[((15*16) + c_k)*16 +: 16];
                        top_map_mvy_l1[(16 + c_k)*16 +: 16]      <= cu_map_mvy_l1[((15*16) + c_k)*16 +: 16];
                        top_map_qp[(16 + c_k)*6 +: 6]            <= cu_map_qp[((15*16) + c_k)*6 +: 6];
                    end else begin
                        top_map_pred_mode[c_k]                   <= cu_map_pred_mode[(15*16) + c_k];
                        top_map_cbf_luma[c_k]                    <= cu_map_cbf_luma[(15*16) + c_k];
                        top_map_cbf_chroma[c_k]                  <= cu_map_cbf_chroma[(15*16) + c_k];
                        top_map_ref_l0[c_k*3 +: 3]               <= cu_map_ref_l0[((15*16) + c_k)*3 +: 3];
                        top_map_ref_l1[c_k*3 +: 3]               <= cu_map_ref_l1[((15*16) + c_k)*3 +: 3];
                        top_map_bi_pred[c_k]                     <= cu_map_bi_pred[(15*16) + c_k];
                        top_map_mvx_l0[c_k*16 +: 16]             <= cu_map_mvx_l0[((15*16) + c_k)*16 +: 16];
                        top_map_mvy_l0[c_k*16 +: 16]             <= cu_map_mvy_l0[((15*16) + c_k)*16 +: 16];
                        top_map_mvx_l1[c_k*16 +: 16]             <= cu_map_mvx_l1[((15*16) + c_k)*16 +: 16];
                        top_map_mvy_l1[c_k*16 +: 16]             <= cu_map_mvy_l1[((15*16) + c_k)*16 +: 16];
                        top_map_qp[c_k*6 +: 6]                   <= cu_map_qp[((15*16) + c_k)*6 +: 6];
                    end
                end
            end

            if (map_update_valid) begin
                for (map_i = 0; map_i < 16; map_i = map_i + 1) begin
                    for (map_j = 0; map_j < 16; map_j = map_j + 1) begin
                        if ((((map_i[3:0] ^ map_cy) & map_blk_mask) == 4'b0000) &&
                            (((map_j[3:0] ^ map_cx) & map_blk_mask) == 4'b0000)) begin
                            if (map_update_cbf_only) begin
                                if (map_update_comp == 2'd0) begin
                                    cu_map_cbf_luma[(map_i*16)+map_j] <= map_update_cbf;
                                end else begin
                                    cu_map_cbf_chroma[(map_i*16)+map_j] <= cu_map_cbf_chroma[(map_i*16)+map_j] | map_update_cbf;
                                end
                            end else begin
                                cu_map_pred_mode[(map_i*16)+map_j] <= map_update_pred_mode;
                                cu_map_qp[((map_i*16)+map_j)*6 +: 6] <= map_update_qp;
                                cu_map_cbf_luma[(map_i*16)+map_j]   <= map_update_cbf;
                                cu_map_cbf_chroma[(map_i*16)+map_j] <= 1'b0;
                                cu_map_mvx_l0[((map_i*16)+map_j)*16 +: 16] <= map_update_mvx;
                                cu_map_mvy_l0[((map_i*16)+map_j)*16 +: 16] <= map_update_mvy;
                                cu_map_ref_l0[((map_i*16)+map_j)*3 +: 3] <= map_update_ref_l0;
                                cu_map_ref_l1[((map_i*16)+map_j)*3 +: 3] <= map_update_ref_l1;
                                cu_map_bi_pred[(map_i*16)+map_j] <= map_update_bi_pred;
                                cu_map_mvx_l1[((map_i*16)+map_j)*16 +: 16] <= 16'd0;
                                cu_map_mvy_l1[((map_i*16)+map_j)*16 +: 16] <= 16'd0;
                            end
                        end
                    end
                end
            end
        end
    end

    //=========================================================================
    // Fill Logic (Original Pixels for SAO stats)
    //=========================================================================
    always @(posedge clk) begin
        // Store original pixels for SAO stats
        if (orig_in_valid && filter_state == S_FILL) begin
            case (in_comp)
                2'd0: orig_y_ram[{in_y[5:0], in_x[5:0]}] <= orig_in_y;
                2'd1: orig_u_ram[{in_y[4:0], in_x[4:0]}] <= orig_in_u;
                2'd2: orig_v_ram[{in_y[4:0], in_x[4:0]}] <= orig_in_v;
                default: ;
            endcase
        end
    end

    //=========================================================================
    // Deblock Interface Wires
    //=========================================================================
    wire        db_ctu_done;
    wire        db_pix_rd_valid;
    reg         db_pix_rd_ready;
    reg         db_pix_resp_valid_q;
    wire [5:0]  db_pix_rd_x, db_pix_rd_y;
    wire [1:0]  db_pix_rd_comp;
    reg  [9:0]  db_pix_resp_data;
    wire        db_pix_wr_valid;
    wire [5:0]  db_pix_wr_x, db_pix_wr_y;
    wire [1:0]  db_pix_wr_comp;
    wire [9:0]  db_pix_wr_data;

    wire        db_pix_rd_neighbor;
    wire        db_pix_rd_is_vert;
    wire        db_pix_rd_corner;
    wire        db_pix_wr_neighbor;
    wire        db_pix_wr_is_vert;
    wire        db_pix_wr_corner;
    wire        db_pix_wr_ready = db_pix_wr_neighbor ? out_ready : 1'b1;

    deblock_top u_deblock (
        .clk(clk), .rst_n(rst_n),
        .ctu_valid      (filter_state == S_DB && !db_ctu_done),
        .ctu_ready      (),
        .ctu_addr       ({3'd0, ctu_addr}),
        .ctu_x          ({4'd0, cur_ctu_x}),
        .ctu_y          ({4'd0, cur_ctu_y}),
        .frame_width_px (frame_width_px),
        .frame_height_px(frame_height_px),
        .cu_map_pred_mode (cu_map_pred_mode),
        .cu_map_cbf_luma  (cu_map_cbf_luma),
        .cu_map_cbf_chroma(cu_map_cbf_chroma),
        .cu_map_ref_l0    (cu_map_ref_l0),
        .cu_map_ref_l1    (cu_map_ref_l1),
        .cu_map_bi_pred   (cu_map_bi_pred),
        .cu_map_mvx_l0    (cu_map_mvx_l0),
        .cu_map_mvy_l0    (cu_map_mvy_l0),
        .cu_map_mvx_l1    (cu_map_mvx_l1),
        .cu_map_mvy_l1    (cu_map_mvy_l1),
        .cu_map_qp        (cu_map_qp),
        .pix_rd_valid   (db_pix_rd_valid),
        .pix_rd_ready   (db_pix_rd_ready),
        .pix_rd_x       (db_pix_rd_x),
        .pix_rd_y       (db_pix_rd_y),
        .pix_rd_comp    (db_pix_rd_comp),
        .pix_resp_valid (db_pix_resp_valid_q),
        .pix_resp_ready (),
        .pix_resp_data  (db_pix_resp_data),
        .pix_wr_valid   (db_pix_wr_valid),
        .pix_wr_ready   (db_pix_wr_ready),
        .pix_wr_x       (db_pix_wr_x),
        .pix_wr_y       (db_pix_wr_y),
        .pix_wr_comp    (db_pix_wr_comp),
        .pix_wr_data    (db_pix_wr_data),
        .nbr_col_pred_mode  (left_map_pred_mode),
        .nbr_col_cbf_luma   (left_map_cbf_luma),
        .nbr_col_cbf_chroma (left_map_cbf_chroma),
        .nbr_col_ref_l0     (left_map_ref_l0),
        .nbr_col_ref_l1     (left_map_ref_l1),
        .nbr_col_bi_pred    (left_map_bi_pred),
        .nbr_col_mvx_l0     (left_map_mvx_l0),
        .nbr_col_mvy_l0     (left_map_mvy_l0),
        .nbr_col_mvx_l1     (left_map_mvx_l1),
        .nbr_col_mvy_l1     (left_map_mvy_l1),
        .nbr_col_qp         (left_map_qp),
        .nbr_row_pred_mode  (db_pix_rd_corner ? {corner_pred_mode, 15'd0}  : (cur_ctu_x[0] ? top_map_pred_mode[31:16] : top_map_pred_mode[15:0])),
        .nbr_row_cbf_luma   (db_pix_rd_corner ? {corner_cbf_luma, 15'd0}   : (cur_ctu_x[0] ? top_map_cbf_luma[31:16]  : top_map_cbf_luma[15:0])),
        .nbr_row_cbf_chroma (db_pix_rd_corner ? {corner_cbf_chroma, 15'd0} : (cur_ctu_x[0] ? top_map_cbf_chroma[31:16]: top_map_cbf_chroma[15:0])),
        .nbr_row_ref_l0     (db_pix_rd_corner ? {corner_ref_l0, 45'd0}     : (cur_ctu_x[0] ? top_map_ref_l0[95:48]    : top_map_ref_l0[47:0])),
        .nbr_row_ref_l1     (db_pix_rd_corner ? {corner_ref_l1, 45'd0}     : (cur_ctu_x[0] ? top_map_ref_l1[95:48]    : top_map_ref_l1[47:0])),
        .nbr_row_bi_pred    (db_pix_rd_corner ? {corner_bi_pred, 15'd0}    : (cur_ctu_x[0] ? top_map_bi_pred[31:16]   : top_map_bi_pred[15:0])),
        .nbr_row_mvx_l0     (db_pix_rd_corner ? {corner_mvx_l0, 240'd0}    : (cur_ctu_x[0] ? top_map_mvx_l0[511:256]  : top_map_mvx_l0[255:0])),
        .nbr_row_mvy_l0     (db_pix_rd_corner ? {corner_mvy_l0, 240'd0}    : (cur_ctu_x[0] ? top_map_mvy_l0[511:256]  : top_map_mvy_l0[255:0])),
        .nbr_row_mvx_l1     (db_pix_rd_corner ? {corner_mvx_l1, 240'd0}    : (cur_ctu_x[0] ? top_map_mvx_l1[511:256]  : top_map_mvx_l1[255:0])),
        .nbr_row_mvy_l1     (db_pix_rd_corner ? {corner_mvy_l1, 240'd0}    : (cur_ctu_x[0] ? top_map_mvy_l1[511:256]  : top_map_mvy_l1[255:0])),
        .nbr_row_qp         (db_pix_rd_corner ? {corner_qp, 90'd0}         : (cur_ctu_x[0] ? top_map_qp[191:96]       : top_map_qp[95:0])),
        .pix_rd_neighbor    (db_pix_rd_neighbor),
        .pix_rd_is_vert     (db_pix_rd_is_vert),
        .pix_rd_corner      (db_pix_rd_corner),
        .pix_wr_neighbor    (db_pix_wr_neighbor),
        .pix_wr_is_vert     (db_pix_wr_is_vert),
        .pix_wr_corner      (db_pix_wr_corner),
        .ctu_done       (db_ctu_done)
    );

    //=========================================================================
    // SAO Stats Interface
    //=========================================================================
    wire        stats_ctu_done;
    wire        stats_rec_rd_valid;
    wire [5:0]  stats_rec_rd_x, stats_rec_rd_y;
    wire [1:0]  stats_rec_rd_comp;
    reg  [9:0]  stats_rec_resp_data;
    wire        stats_org_rd_valid;
    wire [5:0]  stats_org_rd_x, stats_org_rd_y;
    wire [1:0]  stats_org_rd_comp;
    reg  [9:0]  stats_org_resp_data;

    sao_stats u_sao_stats (
        .clk(clk), .rst_n(rst_n),
        .start          (filter_state == S_STATS && !stats_ctu_done),
        .done           (stats_ctu_done),
        .rec_rd_valid   (stats_rec_rd_valid),
        .rec_rd_x       (stats_rec_rd_x),
        .rec_rd_y       (stats_rec_rd_y),
        .rec_rd_comp    (stats_rec_rd_comp),
        .rec_resp_data  (stats_rec_resp_data),
        .org_rd_valid   (stats_org_rd_valid),
        .org_rd_x       (stats_org_rd_x),
        .org_rd_y       (stats_org_rd_y),
        .org_rd_comp    (stats_org_rd_comp),
        .org_resp_data  (stats_org_resp_data),
        .sao_type       (out_sao_type),
        .eo_class       (out_eo_class),
        .eo_offset      (out_eo_offset),
        .band_pos       (out_band_pos),
        .bo_offset      (out_bo_offset)
    );

    //=========================================================================
    // SAO Filter Interface
    //=========================================================================
    wire        sao_ctu_done;
    wire        sao_pix_rd_valid;
    wire [5:0]  sao_pix_rd_x, sao_pix_rd_y;
    wire [1:0]  sao_pix_rd_comp;
    reg  [9:0]  sao_pix_resp_data;
    wire        sao_pix_wr_valid;
    wire [5:0]  sao_pix_wr_x, sao_pix_wr_y;
    wire [1:0]  sao_pix_wr_comp;
    wire [9:0]  sao_pix_wr_data;
    wire        sao_n0_rd_valid;
    wire signed [7:0] sao_n0_rd_x, sao_n0_rd_y;
    wire [1:0]  sao_n0_rd_comp;
    reg  [9:0]  sao_n0_resp_data;
    wire        sao_n1_rd_valid;
    wire signed [7:0] sao_n1_rd_x, sao_n1_rd_y;
    wire [1:0]  sao_n1_rd_comp;
    reg  [9:0]  sao_n1_resp_data;

    // 1-cycle delay registers for SAO response valid (SRAM has 1-cycle read latency)
    reg         sao_pix_resp_valid_q;
    reg         sao_n0_resp_valid_q;
    reg         sao_n1_resp_valid_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sao_pix_resp_valid_q <= 1'b0;
            sao_n0_resp_valid_q  <= 1'b0;
            sao_n1_resp_valid_q  <= 1'b0;
        end else begin
            sao_pix_resp_valid_q <= sao_pix_rd_valid;
            sao_n0_resp_valid_q  <= sao_n0_rd_valid;
            sao_n1_resp_valid_q  <= sao_n1_rd_valid;
        end
    end

    sao_top u_sao (
        .clk(clk), .rst_n(rst_n),
        .ctu_valid      (filter_state == S_SAO && !sao_ctu_done),
        .ctu_ready      (),
        .ctu_x          ({4'd0, cur_ctu_x}),
        .ctu_y          ({4'd0, cur_ctu_y}),
        .sao_type       (out_sao_type),
        .eo_class       (out_eo_class),
        .eo_offset      (out_eo_offset),
        .band_pos       (out_band_pos),
        .bo_offset      (out_bo_offset),
        .pix_rd_valid   (sao_pix_rd_valid),
        .pix_rd_ready   (1'b1),
        .pix_rd_x       (sao_pix_rd_x),
        .pix_rd_y       (sao_pix_rd_y),
        .pix_rd_comp    (sao_pix_rd_comp),
        .pix_resp_valid (sao_pix_resp_valid_q),
        .pix_resp_ready (),
        .pix_resp_data  (sao_pix_resp_data),
        .n0_rd_valid    (sao_n0_rd_valid),
        .n0_rd_ready    (1'b1),
        .n0_rd_x        (sao_n0_rd_x),
        .n0_rd_y        (sao_n0_rd_y),
        .n0_rd_comp     (sao_n0_rd_comp),
        .n0_resp_valid  (sao_n0_resp_valid_q),
        .n0_resp_ready  (),
        .n0_resp_data   (sao_n0_resp_data),
        .n1_rd_valid    (sao_n1_rd_valid),
        .n1_rd_ready    (1'b1),
        .n1_rd_x        (sao_n1_rd_x),
        .n1_rd_y        (sao_n1_rd_y),
        .n1_rd_comp     (sao_n1_rd_comp),
        .n1_resp_valid  (sao_n1_resp_valid_q),
        .n1_resp_ready  (),
        .n1_resp_data   (sao_n1_resp_data),
        .pix_wr_valid   (sao_pix_wr_valid),
        .pix_wr_ready   (1'b1),
        .pix_wr_x       (sao_pix_wr_x),
        .pix_wr_y       (sao_pix_wr_y),
        .pix_wr_comp    (sao_pix_wr_comp),
        .pix_wr_data    (sao_pix_wr_data),
        .ctu_done       (sao_ctu_done)
    );

    //=========================================================================
    // SRAM Read Multiplexer (Deblock / SAO Stats / SAO read from same SRAMs)
    //=========================================================================
    // Pixel Read Arbiter — handles 1-cycle SRAM read latency
    // 
    // Protocol: deblock asserts pix_rd_valid with address. On next cycle,
    // SRAM data is available and pix_resp_valid fires for exactly 1 cycle.
    //=========================================================================
    reg [5:0] rd_x, rd_y;
    reg [1:0] rd_comp;
    reg       db_rd_pending;  // tracks in-flight SRAM read for deblock

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            db_rd_pending <= 1'b0;
        else if (filter_state == S_DB && db_pix_rd_valid && !db_rd_pending)
            db_rd_pending <= 1'b1;  // accept new read request
        else
            db_rd_pending <= 1'b0;  // clear after 1 cycle (data now valid)
    end

    // db_pix_rd_ready pulses for 1 cycle when we accept the request
    always @(*) begin
        rd_x = 6'd0; rd_y = 6'd0; rd_comp = 2'd0;
        db_pix_rd_ready = 1'b0;

        case (filter_state)
            S_DB: begin
                rd_x = db_pix_rd_x; rd_y = db_pix_rd_y; rd_comp = db_pix_rd_comp;
                // Accept new request only when not already pending
                db_pix_rd_ready = db_pix_rd_valid && !db_rd_pending;
            end
            S_STATS: begin
                rd_x = stats_rec_rd_x; rd_y = stats_rec_rd_y; rd_comp = stats_rec_rd_comp;
            end
            S_SAO: begin
                rd_x = sao_pix_rd_x; rd_y = sao_pix_rd_y; rd_comp = sao_pix_rd_comp;
            end
            default: ;
        endcase
    end

    wire db_rd_from_corner = db_pix_rd_corner && (rd_comp == 2'd0 ? (rd_y >= 6'd60) : (rd_y >= 5'd30));
    wire db_rd_from_col    = db_pix_rd_corner ? (rd_comp == 2'd0 ? (rd_y < 6'd60) : (rd_y < 5'd30)) : db_pix_rd_is_vert;

`ifdef SYNTHESIS
    // Unified synchronous read addresses for M10K block RAM inference
    wire [11:0] syn_luma_rd_addr = (filter_state == S_DUMP) ? dump_count[11:0] : {rd_y[5:0], rd_x[5:0]};
    wire [9:0]  syn_cb_rd_addr   = (filter_state == S_DUMP) ? dump_count[9:0]  : {rd_y[4:0], rd_x[4:0]};
    wire [9:0]  syn_cr_rd_addr   = (filter_state == S_DUMP) ? dump_count[9:0]  : {rd_y[4:0], rd_x[4:0]};

    reg [9:0] luma_rd_q;
    reg [9:0] cb_rd_q;
    reg [9:0] cr_rd_q;
    reg [1:0] rd_comp_q;
    reg [9:0] db_nbr_rd_q;
    reg       db_rd_neighbor_q;

    // SAO stats original pixel synchronous read registers
    reg [9:0] orig_y_rd_q, orig_u_rd_q, orig_v_rd_q;
    reg [1:0] stats_org_rd_comp_q;

    always @(posedge clk) begin
        db_pix_resp_valid_q <= db_rd_pending;
        db_rd_neighbor_q    <= (filter_state == S_DB && db_pix_rd_neighbor);
        if (filter_state == S_DB && db_pix_rd_neighbor) begin
            if (db_rd_from_corner) begin
                case (rd_comp)
                    2'd0: db_nbr_rd_q <= corner_buf_luma[rd_y[1:0]][rd_x[1:0]];
                    2'd1: db_nbr_rd_q <= corner_buf_cb[rd_y[0]][rd_x[1:0]];
                    2'd2: db_nbr_rd_q <= corner_buf_cr[rd_y[0]][rd_x[1:0]];
                    default: db_nbr_rd_q <= 10'd0;
                endcase
            end else if (db_rd_from_col) begin
                case (rd_comp)
                    2'd0: db_nbr_rd_q <= col_buf_luma[rd_y[5:0]][rd_x[1:0]];
                    2'd1: db_nbr_rd_q <= col_buf_cb[rd_y[4:0]][rd_x[1:0]];
                    2'd2: db_nbr_rd_q <= col_buf_cr[rd_y[4:0]][rd_x[1:0]];
                    default: db_nbr_rd_q <= 10'd0;
                endcase
            end else begin
                case (rd_comp)
                    2'd0: db_nbr_rd_q <= line_buf_luma[rd_y[1:0]][({7'd0, cur_ctu_x} << 6) + {1'b0, rd_x[5:0]}];
                    2'd1: db_nbr_rd_q <= line_buf_cb[rd_y[0]][({6'd0, cur_ctu_x} << 5) + {1'b0, rd_x[4:0]}];
                    2'd2: db_nbr_rd_q <= line_buf_cr[rd_y[0]][({6'd0, cur_ctu_x} << 5) + {1'b0, rd_x[4:0]}];
                    default: db_nbr_rd_q <= 10'd0;
                endcase
            end
        end
        luma_rd_q           <= luma_ram[syn_luma_rd_addr];
        cb_rd_q             <= cb_ram[syn_cb_rd_addr];
        cr_rd_q             <= cr_ram[syn_cr_rd_addr];
        rd_comp_q           <= rd_comp;

        orig_y_rd_q         <= orig_y_ram[{stats_org_rd_y[5:0], stats_org_rd_x[5:0]}];
        orig_u_rd_q         <= orig_u_ram[{stats_org_rd_y[4:0], stats_org_rd_x[4:0]}];
        orig_v_rd_q         <= orig_v_ram[{stats_org_rd_y[4:0], stats_org_rd_x[4:0]}];
        stats_org_rd_comp_q <= stats_org_rd_comp;
    end

    always @(*) begin
        if (db_rd_neighbor_q) begin
            db_pix_resp_data    = db_nbr_rd_q;
            sao_pix_resp_data   = luma_rd_q;
            stats_rec_resp_data = luma_rd_q;
        end else if (rd_comp_q == 2'd0) begin
            db_pix_resp_data    = luma_rd_q;
            sao_pix_resp_data   = luma_rd_q;
            stats_rec_resp_data = luma_rd_q;
        end else if (rd_comp_q == 2'd1) begin
            db_pix_resp_data    = cb_rd_q;
            sao_pix_resp_data   = cb_rd_q;
            stats_rec_resp_data = cb_rd_q;
        end else begin
            db_pix_resp_data    = cr_rd_q;
            sao_pix_resp_data   = cr_rd_q;
            stats_rec_resp_data = cr_rd_q;
        end
        sao_n0_resp_data = db_pix_resp_data;
        sao_n1_resp_data = db_pix_resp_data;

        if (stats_org_rd_comp_q == 2'd0)
            stats_org_resp_data = orig_y_rd_q;
        else if (stats_org_rd_comp_q == 2'd1)
            stats_org_resp_data = orig_u_rd_q;
        else
            stats_org_resp_data = orig_v_rd_q;
    end
`else
    // Registered SRAM read — data available 1 cycle after address is presented
    always @(posedge clk) begin
        db_pix_resp_valid_q <= db_rd_pending; // Response fires when pending read completes
        if (filter_state == S_DB && db_pix_rd_neighbor) begin
            if (db_rd_from_corner) begin
                case (rd_comp)
                    2'd0: db_pix_resp_data <= corner_buf_luma[rd_y[1:0]][rd_x[1:0]];
                    2'd1: db_pix_resp_data <= corner_buf_cb[rd_y[0]][rd_x[1:0]];
                    2'd2: db_pix_resp_data <= corner_buf_cr[rd_y[0]][rd_x[1:0]];
                    default: ;
                endcase
            end else if (db_rd_from_col) begin
                case (rd_comp)
                    2'd0: db_pix_resp_data <= col_buf_luma[rd_y[5:0]][rd_x[1:0]];
                    2'd1: db_pix_resp_data <= col_buf_cb[rd_y[4:0]][rd_x[1:0]];
                    2'd2: db_pix_resp_data <= col_buf_cr[rd_y[4:0]][rd_x[1:0]];
                    default: ;
                endcase
            end else begin
                case (rd_comp)
                    2'd0: db_pix_resp_data <= line_buf_luma[rd_y[1:0]][({7'd0, cur_ctu_x} << 6) + {1'b0, rd_x[5:0]}];
                    2'd1: db_pix_resp_data <= line_buf_cb[rd_y[0]][({6'd0, cur_ctu_x} << 5) + {1'b0, rd_x[4:0]}];
                    2'd2: db_pix_resp_data <= line_buf_cr[rd_y[0]][({6'd0, cur_ctu_x} << 5) + {1'b0, rd_x[4:0]}];
                    default: ;
                endcase
            end
        end else if (rd_comp == 2'd0) begin
            db_pix_resp_data    <= luma_ram[{rd_y[5:0], rd_x[5:0]}];
            sao_pix_resp_data   <= luma_ram[{rd_y[5:0], rd_x[5:0]}];
            stats_rec_resp_data <= luma_ram[{rd_y[5:0], rd_x[5:0]}];
        end else if (rd_comp == 2'd1) begin
            db_pix_resp_data    <= cb_ram[{rd_y[4:0], rd_x[4:0]}];
            sao_pix_resp_data   <= cb_ram[{rd_y[4:0], rd_x[4:0]}];
            stats_rec_resp_data <= cb_ram[{rd_y[4:0], rd_x[4:0]}];
        end else begin
            db_pix_resp_data    <= cr_ram[{rd_y[4:0], rd_x[4:0]}];
            sao_pix_resp_data   <= cr_ram[{rd_y[4:0], rd_x[4:0]}];
            stats_rec_resp_data <= cr_ram[{rd_y[4:0], rd_x[4:0]}];
        end

        // SAO neighbour reads (clamp to CTU boundary)
        begin : sao_nbr_read
            reg [5:0] n0x, n0y, n1x, n1y;
            reg [1:0] nc;
            reg [5:0] nmax;

            nc = sao_n0_rd_comp;
            nmax = (nc == 2'd0) ? 6'd63 : 6'd31;

            n0x = (sao_n0_rd_x < 0) ? 6'd0 : (sao_n0_rd_x > nmax) ? nmax : sao_n0_rd_x[5:0];
            n0y = (sao_n0_rd_y < 0) ? 6'd0 : (sao_n0_rd_y > nmax) ? nmax : sao_n0_rd_y[5:0];
            n1x = (sao_n1_rd_x < 0) ? 6'd0 : (sao_n1_rd_x > nmax) ? nmax : sao_n1_rd_x[5:0];
            n1y = (sao_n1_rd_y < 0) ? 6'd0 : (sao_n1_rd_y > nmax) ? nmax : sao_n1_rd_y[5:0];

            if (nc == 2'd0) begin
                sao_n0_resp_data <= luma_ram[{n0y, n0x}];
                sao_n1_resp_data <= luma_ram[{n1y, n1x}];
            end else if (nc == 2'd1) begin
                sao_n0_resp_data <= cb_ram[{n0y[4:0], n0x[4:0]}];
                sao_n1_resp_data <= cb_ram[{n1y[4:0], n1x[4:0]}];
            end else begin
                sao_n0_resp_data <= cr_ram[{n0y[4:0], n0x[4:0]}];
                sao_n1_resp_data <= cr_ram[{n1y[4:0], n1x[4:0]}];
            end
        end

        // SAO stats original pixel read
        if (stats_org_rd_comp == 2'd0)
            stats_org_resp_data <= orig_y_ram[{stats_org_rd_y[5:0], stats_org_rd_x[5:0]}];
        else if (stats_org_rd_comp == 2'd1)
            stats_org_resp_data <= orig_u_ram[{stats_org_rd_y[4:0], stats_org_rd_x[4:0]}];
        else
            stats_org_resp_data <= orig_v_ram[{stats_org_rd_y[4:0], stats_org_rd_x[4:0]}];
    end
`endif

    //=========================================================================
    // Unified SRAM Write Port (Fill, Deblock, and SAO)
    //=========================================================================
    always @(posedge clk) begin
        if (in_valid && filter_state == S_FILL) begin
            case (in_comp)
                2'd0: luma_ram[{in_y[5:0], in_x[5:0]}] <= in_pixel;
                2'd1: cb_ram  [{in_y[4:0], in_x[4:0]}] <= in_pixel;
                2'd2: cr_ram  [{in_y[4:0], in_x[4:0]}] <= in_pixel;
                default: ;
            endcase
        end else if (db_pix_wr_valid && db_pix_wr_ready) begin
            if (db_pix_wr_neighbor) begin
                if (db_pix_wr_corner) begin
                    case (db_pix_wr_comp)
                        2'd0: begin
                            if (db_pix_wr_y < 6'd60)
                                col_buf_luma[db_pix_wr_y[5:0]][db_pix_wr_x[1:0]] <= db_pix_wr_data;
                        end
                        2'd1: begin
                            if (db_pix_wr_y < 5'd30)
                                col_buf_cb[db_pix_wr_y[4:0]][db_pix_wr_x[1:0]] <= db_pix_wr_data;
                        end
                        2'd2: begin
                            if (db_pix_wr_y < 5'd30)
                                col_buf_cr[db_pix_wr_y[4:0]][db_pix_wr_x[1:0]] <= db_pix_wr_data;
                        end
                        default: ;
                    endcase
                end else if (db_pix_wr_is_vert) begin
                    case (db_pix_wr_comp)
                        2'd0: begin
                            col_buf_luma[db_pix_wr_y[5:0]][db_pix_wr_x[1:0]] <= db_pix_wr_data;
                            if (db_pix_wr_y >= 6'd60 && cur_ctu_x > 0) begin
                                line_buf_luma[db_pix_wr_y[1:0]][({7'd0, cur_ctu_x - 1'b1} << 6) + {1'b0, db_pix_wr_x[5:0]}] <= db_pix_wr_data;
                                if (cur_ctu_y == 0)
                                    corner_buf_luma[db_pix_wr_y[1:0]][db_pix_wr_x[1:0]] <= db_pix_wr_data;
                            end
                        end
                        2'd1: begin
                            col_buf_cb[db_pix_wr_y[4:0]][db_pix_wr_x[1:0]] <= db_pix_wr_data;
                            if (db_pix_wr_y >= 5'd30 && cur_ctu_x > 0) begin
                                line_buf_cb[db_pix_wr_y[0]][({6'd0, cur_ctu_x - 1'b1} << 5) + {1'b0, db_pix_wr_x[4:0]}] <= db_pix_wr_data;
                                if (cur_ctu_y == 0)
                                    corner_buf_cb[db_pix_wr_y[0]][db_pix_wr_x[1:0]] <= db_pix_wr_data;
                            end
                        end
                        2'd2: begin
                            col_buf_cr[db_pix_wr_y[4:0]][db_pix_wr_x[1:0]] <= db_pix_wr_data;
                            if (db_pix_wr_y >= 5'd30 && cur_ctu_x > 0) begin
                                line_buf_cr[db_pix_wr_y[0]][({6'd0, cur_ctu_x - 1'b1} << 5) + {1'b0, db_pix_wr_x[4:0]}] <= db_pix_wr_data;
                                if (cur_ctu_y == 0)
                                    corner_buf_cr[db_pix_wr_y[0]][db_pix_wr_x[1:0]] <= db_pix_wr_data;
                            end
                        end
                        default: ;
                    endcase
                end else begin
                    case (db_pix_wr_comp)
                        2'd0: line_buf_luma[db_pix_wr_y[1:0]][({7'd0, cur_ctu_x} << 6) + {1'b0, db_pix_wr_x[5:0]}] <= db_pix_wr_data;
                        2'd1: line_buf_cb[db_pix_wr_y[0]][({6'd0, cur_ctu_x} << 5) + {1'b0, db_pix_wr_x[4:0]}] <= db_pix_wr_data;
                        2'd2: line_buf_cr[db_pix_wr_y[0]][({6'd0, cur_ctu_x} << 5) + {1'b0, db_pix_wr_x[4:0]}] <= db_pix_wr_data;
                        default: ;
                    endcase
                end
            end else begin
                case (db_pix_wr_comp)
                    2'd0: luma_ram[{db_pix_wr_y[5:0], db_pix_wr_x[5:0]}] <= db_pix_wr_data;
                    2'd1: cb_ram  [{db_pix_wr_y[4:0], db_pix_wr_x[4:0]}] <= db_pix_wr_data;
                    2'd2: cr_ram  [{db_pix_wr_y[4:0], db_pix_wr_x[4:0]}] <= db_pix_wr_data;
                    default: ;
                endcase
            end
        end else if (sao_pix_wr_valid) begin
            case (sao_pix_wr_comp)
                2'd0: luma_ram[{sao_pix_wr_y[5:0], sao_pix_wr_x[5:0]}] <= sao_pix_wr_data;
                2'd1: cb_ram  [{sao_pix_wr_y[4:0], sao_pix_wr_x[4:0]}] <= sao_pix_wr_data;
                2'd2: cr_ram  [{sao_pix_wr_y[4:0], sao_pix_wr_x[4:0]}] <= sao_pix_wr_data;
                default: ;
            endcase
        end
    end

    //=========================================================================
    // Capture Line Buffer and Column Buffer during S_DUMP
    //=========================================================================
    always @(posedge clk) begin
        if (filter_state == S_DUMP && out_ready) begin
            if (dump_count < 13'd4096) begin
                // Luma (dump_count[11:6] = y, dump_count[5:0] = x)
                if (dump_count[5:0] >= 6'd60)
                    col_buf_luma[dump_count[11:6]][dump_count[1:0]] <= luma_ram[dump_count[11:0]];
                if (dump_count[11:6] >= 6'd60)
                    line_buf_luma[dump_count[7:6]][({7'd0, cur_ctu_x} << 6) + {1'b0, dump_count[5:0]}] <= luma_ram[dump_count[11:0]];
                if (cur_ctu_x == 0 && cur_ctu_y == 0 && dump_count[11:6] >= 6'd60 && dump_count[5:0] >= 6'd60)
                    corner_buf_luma[dump_count[7:6]][dump_count[1:0]] <= luma_ram[dump_count[11:0]];
            end else if (dump_count < 13'd5120) begin
                // Cb (local = dump_count[9:0], y = local[9:5], x = local[4:0])
                if (dump_count[4:0] >= 5'd28)
                    col_buf_cb[dump_count[9:5]][dump_count[1:0]] <= cb_ram[dump_count[9:0]];
                if (dump_count[9:5] >= 5'd30)
                    line_buf_cb[dump_count[5]][({6'd0, cur_ctu_x} << 5) + {1'b0, dump_count[4:0]}] <= cb_ram[dump_count[9:0]];
                if (cur_ctu_x == 0 && cur_ctu_y == 0 && dump_count[9:5] >= 5'd30 && dump_count[4:0] >= 5'd28)
                    corner_buf_cb[dump_count[5]][dump_count[1:0]] <= cb_ram[dump_count[9:0]];
            end else begin
                // Cr (local = dump_count[9:0], y = local[9:5], x = local[4:0])
                if (dump_count[4:0] >= 5'd28)
                    col_buf_cr[dump_count[9:5]][dump_count[1:0]] <= cr_ram[dump_count[9:0]];
                if (dump_count[9:5] >= 5'd30)
                    line_buf_cr[dump_count[5]][({6'd0, cur_ctu_x} << 5) + {1'b0, dump_count[4:0]}] <= cr_ram[dump_count[9:0]];
                if (cur_ctu_x == 0 && cur_ctu_y == 0 && dump_count[9:5] >= 5'd30 && dump_count[4:0] >= 5'd28)
                    corner_buf_cr[dump_count[5]][dump_count[1:0]] <= cr_ram[dump_count[9:0]];
            end
        end
    end

    //=========================================================================
    // Main FSM
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            filter_state <= S_FILL;
            pixel_count  <= 13'd0;
            dump_count   <= 13'd0;
            cur_ctu_x    <= 0;
            cur_ctu_y    <= 0;
        end else begin
            case (filter_state)
                S_FILL: begin
                    if (in_valid) begin
                        if (ctu_recon_done) begin
                            pixel_count  <= 13'd0;
                            filter_state <= S_DB;
                            dump_count   <= 13'd0;
                            // synthesis translate_off
                            $display("Time=%0t: [INLOOP_FILTERS] CTU (%0d,%0d) Reconstructed. Starting Deblocking Filter...", $time, cur_ctu_x, cur_ctu_y);
                            // synthesis translate_on
                        end else begin
                            pixel_count <= pixel_count + 13'd1;
                        end
                    end
                end
                S_DB: if (db_ctu_done) begin
                    // synthesis translate_off
                    $display("Time=%0t: [INLOOP_FILTERS] Deblock complete. Bypassing SAO (slice_sao=0)...", $time);
                    // synthesis translate_on
                    filter_state <= S_DUMP;
                    dump_count   <= 13'd0;
                end
                S_STATS: if (stats_ctu_done) begin
                    // synthesis translate_off
                    $display("Time=%0t: [INLOOP_FILTERS] SAO Stats complete. Starting SAO Filter...", $time);
                    // synthesis translate_on
                    filter_state <= S_SAO;
                end
                S_SAO: if (sao_ctu_done) begin
                    // synthesis translate_off
                    $display("Time=%0t: [INLOOP_FILTERS] SAO complete. Dumping 6144 pixels to DPB...", $time);
                    // synthesis translate_on
                    filter_state <= S_DUMP;
                    dump_count   <= 13'd0;
                end
                S_DUMP: begin
                    if (out_ready) begin  // wait for frame_store to be ready
                        if (dump_count == 13'd6143) begin
                            dump_count   <= 13'd0;
                            filter_state <= S_FILL;
                            if (cur_ctu_x == (frame_width_px >> 6) - 1) begin
                                cur_ctu_x <= 0;
                                if (cur_ctu_y == (frame_height_px >> 6) - 1)
                                    cur_ctu_y <= 0;
                                else
                                    cur_ctu_y <= cur_ctu_y + 1;
                            end else begin
                                cur_ctu_x <= cur_ctu_x + 1;
                            end
                            // synthesis translate_off
                            $display("Time=%0t: [INLOOP_FILTERS] Dump complete for CTU (%0d,%0d).", $time, cur_ctu_x, cur_ctu_y);
                            // synthesis translate_on
                        end else begin
                            dump_count <= dump_count + 13'd1;
                        end
                    end
                end
            endcase
        end
    end

    //=========================================================================
    // Dump and Neighbor Write Logic — output pixels from SRAMs / Filters to DPB
    //=========================================================================
    // Absolute frame coordinates for neighbor writes during deblock
    wire db_wr_is_top_ctu = db_pix_wr_corner ? 
                            (db_pix_wr_y >= (db_pix_wr_comp == 2'd0 ? 6'd60 : 5'd30)) :
                            (!db_pix_wr_is_vert);
    wire db_wr_is_left_ctu = db_pix_wr_corner ? 
                             1'b1 :
                             db_pix_wr_is_vert;

    wire [11:0] db_nbr_ctu_x = (db_wr_is_left_ctu && cur_ctu_x > 0) ? ({6'd0, cur_ctu_x} - 12'd1) : {6'd0, cur_ctu_x};
    wire [11:0] db_nbr_ctu_y = (db_wr_is_top_ctu  && cur_ctu_y > 0) ? ({6'd0, cur_ctu_y} - 12'd1) : {6'd0, cur_ctu_y};
    wire [11:0] db_nbr_abs_x = (db_pix_wr_comp == 2'd0) ?
                               ((db_nbr_ctu_x << 6) + {6'd0, db_pix_wr_x[5:0]}) :
                               ((db_nbr_ctu_x << 5) + {7'd0, db_pix_wr_x[4:0]});
    wire [11:0] db_nbr_abs_y = (db_pix_wr_comp == 2'd0) ?
                               ((db_nbr_ctu_y << 6) + {6'd0, db_pix_wr_y[5:0]}) :
                               ((db_nbr_ctu_y << 5) + {7'd0, db_pix_wr_y[4:0]});

    always @(*) begin
        out_valid = 1'b0;
        out_comp  = 2'd0;
        out_pixel = 10'd0;
        out_abs_x = 12'd0;
        out_abs_y = 12'd0;

        if (filter_state == S_DB && db_pix_wr_valid && db_pix_wr_neighbor) begin
            out_valid = 1'b1;
            out_comp  = db_pix_wr_comp;
            out_pixel = db_pix_wr_data;
            out_abs_x = db_nbr_abs_x;
            out_abs_y = db_nbr_abs_y;
        end else if (filter_state == S_DUMP) begin
            out_valid = 1'b1;
            if (dump_count < 13'd4096) begin
                out_comp  = 2'd0;
                out_pixel = luma_ram[dump_count[11:0]];
                out_abs_x = ({12'd0, cur_ctu_x} << 6) + dump_count[5:0];
                out_abs_y = ({12'd0, cur_ctu_y} << 6) + dump_count[11:6];
            end else if (dump_count < 13'd5120) begin
                out_comp  = 2'd1;
                out_pixel = cb_ram[dump_count[9:0]];
                out_abs_x = ({12'd0, cur_ctu_x} << 5) + dump_count[4:0];
                out_abs_y = ({12'd0, cur_ctu_y} << 5) + dump_count[9:5];
            end else begin
                out_comp  = 2'd2;
                out_pixel = cr_ram[dump_count[9:0]];
                out_abs_x = ({12'd0, cur_ctu_x} << 5) + dump_count[4:0];
                out_abs_y = ({12'd0, cur_ctu_y} << 5) + dump_count[9:5];
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inloop_ctu_done <= 1'b0;
        end else begin
            inloop_ctu_done <= 1'b0;
            if (filter_state == S_DUMP && out_ready) begin
                if (dump_count == 13'd6143) begin
                    inloop_ctu_done <= 1'b1;
                end
            end
        end
    end

    // synthesis translate_off
    always @(posedge clk)
        if (rst_n && inloop_ctu_done)
            $display("INFO [inloop_filters] CTU (%0d,%0d) done t=%0t", cur_ctu_x, cur_ctu_y, $time);
    // synthesis translate_on

endmodule
