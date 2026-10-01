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

    integer map_i, map_j;
    wire [3:0] map_luma_log2 = (map_update_comp == 2'd0) ? map_update_size_log2 : (map_update_size_log2 + 3'd1);
    wire [3:0] map_blk_mask  = (map_luma_log2 >= 4'd6) ? 4'b0000 :
                               (map_luma_log2 == 4'd5) ? 4'b1000 :
                               (map_luma_log2 == 4'd4) ? 4'b1100 :
                               (map_luma_log2 == 4'd3) ? 4'b1110 : 4'b1111;
    wire [3:0] map_cx = map_update_x[5:2];
    wire [3:0] map_cy = map_update_y[5:2];

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
        end else begin
            if (in_valid && pixel_count == 13'd0) begin
                cu_map_cbf_luma   <= 256'd0;
                cu_map_cbf_chroma <= 256'd0;
            end

            if (map_update_valid) begin
                for (map_i = 0; map_i < 16; map_i = map_i + 1) begin
                    for (map_j = 0; map_j < 16; map_j = map_j + 1) begin
                        if ((((map_i[3:0] ^ map_cy) & map_blk_mask) == 4'b0000) &&
                            (((map_j[3:0] ^ map_cx) & map_blk_mask) == 4'b0000)) begin
                            cu_map_pred_mode[(map_i*16)+map_j] <= map_update_pred_mode;
                            cu_map_qp[((map_i*16)+map_j)*6 +: 6] <= map_update_qp;
                            if (map_update_comp == 2'd0) begin
                                cu_map_cbf_luma[(map_i*16)+map_j] <= map_update_cbf;
                                cu_map_mvx_l0[((map_i*16)+map_j)*16 +: 16] <= map_update_mvx;
                                cu_map_mvy_l0[((map_i*16)+map_j)*16 +: 16] <= map_update_mvy;
                                cu_map_ref_l0[((map_i*16)+map_j)*3 +: 3] <= map_update_ref_l0;
                                cu_map_ref_l1[((map_i*16)+map_j)*3 +: 3] <= map_update_ref_l1;
                                cu_map_bi_pred[(map_i*16)+map_j] <= map_update_bi_pred;
                                cu_map_mvx_l1[((map_i*16)+map_j)*16 +: 16] <= 16'd0;
                                cu_map_mvy_l1[((map_i*16)+map_j)*16 +: 16] <= 16'd0;
                            end else begin
                                cu_map_cbf_chroma[(map_i*16)+map_j] <= map_update_cbf;
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
        .pix_wr_ready   (1'b1),
        .pix_wr_x       (db_pix_wr_x),
        .pix_wr_y       (db_pix_wr_y),
        .pix_wr_comp    (db_pix_wr_comp),
        .pix_wr_data    (db_pix_wr_data),
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

`ifdef SYNTHESIS
    // Unified synchronous read addresses for M10K block RAM inference
    wire [11:0] syn_luma_rd_addr = (filter_state == S_DUMP) ? dump_count[11:0] : {rd_y[5:0], rd_x[5:0]};
    wire [9:0]  syn_cb_rd_addr   = (filter_state == S_DUMP) ? dump_count[9:0]  : {rd_y[4:0], rd_x[4:0]};
    wire [9:0]  syn_cr_rd_addr   = (filter_state == S_DUMP) ? dump_count[9:0]  : {rd_y[4:0], rd_x[4:0]};

    reg [9:0] luma_rd_q;
    reg [9:0] cb_rd_q;
    reg [9:0] cr_rd_q;
    reg [1:0] rd_comp_q;

    // SAO stats original pixel synchronous read registers
    reg [9:0] orig_y_rd_q, orig_u_rd_q, orig_v_rd_q;
    reg [1:0] stats_org_rd_comp_q;

    always @(posedge clk) begin
        db_pix_resp_valid_q <= db_rd_pending;
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
        if (rd_comp_q == 2'd0) begin
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
        if (rd_comp == 2'd0) begin
            db_pix_resp_data  <= luma_ram[{rd_y[5:0], rd_x[5:0]}];
            sao_pix_resp_data <= luma_ram[{rd_y[5:0], rd_x[5:0]}];
            stats_rec_resp_data <= luma_ram[{rd_y[5:0], rd_x[5:0]}];
        end else if (rd_comp == 2'd1) begin
            db_pix_resp_data  <= cb_ram[{rd_y[4:0], rd_x[4:0]}];
            sao_pix_resp_data <= cb_ram[{rd_y[4:0], rd_x[4:0]}];
            stats_rec_resp_data <= cb_ram[{rd_y[4:0], rd_x[4:0]}];
        end else begin
            db_pix_resp_data  <= cr_ram[{rd_y[4:0], rd_x[4:0]}];
            sao_pix_resp_data <= cr_ram[{rd_y[4:0], rd_x[4:0]}];
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
        end else if (db_pix_wr_valid) begin
            case (db_pix_wr_comp)
                2'd0: luma_ram[{db_pix_wr_y[5:0], db_pix_wr_x[5:0]}] <= db_pix_wr_data;
                2'd1: cb_ram  [{db_pix_wr_y[4:0], db_pix_wr_x[4:0]}] <= db_pix_wr_data;
                2'd2: cr_ram  [{db_pix_wr_y[4:0], db_pix_wr_x[4:0]}] <= db_pix_wr_data;
                default: ;
            endcase
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
                    $display("Time=%0t: [INLOOP_FILTERS] Deblock complete. Starting SAO Stats...", $time);
                    // synthesis translate_on
                    filter_state <= S_STATS;
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
    // Dump Logic — output pixels from SRAMs to DPB
    //=========================================================================
    always @(*) begin
        out_valid = (filter_state == S_DUMP);

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
