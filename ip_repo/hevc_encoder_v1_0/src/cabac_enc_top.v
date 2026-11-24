//=============================================================================
// cabac_enc_top.v
// CABAC Encoder Top-Level — integrates all entropy sub-modules
//
// Mapped from HM source:
//   TLibEncoder/TEncSbac.cpp     :: TEncSbac (wrapper for all syntax encoders)
//   TLibEncoder/TEncBinCABAC.cpp :: TEncBinCABAC (arithmetic coder)
//   TLibEncoder/TEncSlice.cpp    :: encodeSlice() — drives the encoding flow
//
// Module hierarchy instantiated here:
//
//   cabac_enc_top
//    ├── ctx_model_store    (186 × 7-bit state SRAM, slice init, read/write)
//    ├── bin_encoder        (ctx lookup → range_coder dispatch, EP bypass)
//    ├── range_coder        (M-coder arithmetic engine, byte output)
//    ├── syntax_cu          (split_flag, skip, merge, pred_mode, part_mode)
//    ├── syntax_pred        (inter_dir, ref_idx, mvp_flag, MVD)
//    └── syntax_coeff       (last_sig, sig_map, gt1, gt2, sign, remaining)
//
// Encoding flow for one CU:
//
//   1. [slice_init] → ctx_model_store reset (186 cycles)
//   2. [cu_req]     → syntax_cu   → bins → bin_encoder → range_coder → bytes
//   3. [pred_req]   → syntax_pred → bins → bin_encoder → range_coder → bytes
//   4. [coeff_req]  → syntax_coeff→ bins → bin_encoder → range_coder → bytes
//   5. [flush_req]  → range_coder flush → final bytes → NAL writer
//
// Bin arbitration:
//   Only one syntax_* module drives bin_encoder at a time.
//   State machine tracks active source: NONE / CU / PRED / COEFF
//   bin_valid is muxed from the active source; bin_rdy is broadcast to all.
//
// External interface:
//   Slice-level: slice_init, slice_type, qp_in → ctx_model_store
//   CU-level:    cu_req + CU fields → syntax_cu (see syntax_cu.v ports)
//   Pred-level:  pred_req + pred fields → syntax_pred
//   Coeff-level: coeff_req + coeff array → syntax_coeff
//   Flush:       flush_req → range_coder (end of slice/NALU)
//   Output:      byte_valid, byte_out → NAL writer / output_fifo
//=============================================================================

`include "parameter_pkg.vh"

module cabac_enc_top #(
    parameter CTX_ID_W  = 8,
    parameter COEFF_W   = 16,
    parameter MVD_W     = 12,
    parameter N_COEFF   = 16    // 4×4 block
)(
    input  wire        clk,
    input  wire        rst_n,

    // ── Slice initialization ─────────────────────────────────────────────
    input  wire        slice_init,     // pulse: reset contexts + range coder
    input  wire [1:0]  slice_type,     // 0=I, 1=P, 2=B
    input  wire [6:0]  qp_in,         // QP (tie to 7'd32 for fixed-QP)

    // ── CU syntax request ────────────────────────────────────────────────
    input  wire        cu_req,
    output wire        cu_done,
    input  wire [1:0]  cu_depth,
    input  wire        cu_is_split,
    input  wire        slice_is_intra,
    input  wire        cu_skip,
    input  wire        cu_merge,
    input  wire [2:0]  cu_merge_idx,
    input  wire        cu_pred_intra,
    input  wire [5:0]  cu_intra_mode,
    input  wire [2:0]  cu_chroma_pred_mode,
    input  wire [5:0]  cu_left_intra_mode,
    input  wire [5:0]  cu_above_intra_mode,
    input  wire [1:0]  cu_part_mode,
    input  wire        cu_cbf,
    input  wire [1:0]  cu_skip_ctx,
    input  wire [1:0]  cu_split_ctx,

    // ── Prediction syntax request ────────────────────────────────────────
    input  wire        pred_req,
    output wire        pred_done,
    input  wire        slice_is_b,
    input  wire [1:0]  inter_dir,
    input  wire [2:0]  ref_idx_l0,
    input  wire        mvp_flag_l0,
    input  wire signed [MVD_W-1:0] mvd_l0_x,
    input  wire signed [MVD_W-1:0] mvd_l0_y,
    input  wire [2:0]  ref_idx_l1,
    input  wire        mvp_flag_l1,
    input  wire signed [MVD_W-1:0] mvd_l1_x,
    input  wire signed [MVD_W-1:0] mvd_l1_y,

    // ── Coefficient syntax request ───────────────────────────────────────
    input  wire        coeff_req,
    output wire        coeff_done,
    input  wire [1:0]  coeff_comp,
    input  wire        coeff_is_intra,
    input  wire [2:0]  coeff_tu_size_log2,
    input  wire        coeff_tu_cbf,
    input  wire [9:0]  coeff_last_sig_pos,
    input  wire [1:0]  coeff_scan_mode,
    input  wire        tu_cg_mask_en,
    input  wire [63:0] tu_cg_nonzero_mask,
    output wire        coeff_rd_en,
    output wire [11:0] coeff_rd_addr,
    input  wire signed [COEFF_W-1:0] coeff_rd_data,

    // ── SAO syntax request ───────────────────────────────────────────────
    input  wire [5:0]  ctu_x,
    input  wire [5:0]  ctu_y,
    input  wire        sao_req,
    output wire        sao_done,
    input  wire [5:0]  sao_type,
    input  wire [5:0]  sao_eo_class,
    input  wire [74:0] sao_eo_offset,
    input  wire [14:0] sao_band_pos,
    input  wire [59:0] sao_bo_offset,

    // ── SAO CTU delay & drain (T3-13) & 2-bank CTU Ping-Pong ────────────
    input  wire        ctu_sao_delay_en,
    input  wire        ctu_fe_done,
    output wire        ctu_bin_wr_ready,
    input  wire        ctu_bin_drain_en,
    output wire        ctu_bin_drain_done,

    // ── Terminating bin + flush ──────────────────────────────────────────
    input  wire        trm_req,        // encode terminating bin (end of slice)
    input  wire        trm_bin_val,    // 1 for end_of_slice, 0 otherwise
    input  wire        flush_req,      // flush range coder (end of NALU)
    output wire        flush_done,

    // ── Byte output → output_fifo / NAL writer ───────────────────────────
    output wire        byte_valid,
    output wire [7:0]  byte_out,
    input  wire        byte_ready,

    // ── Status ───────────────────────────────────────────────────────────
    output wire        enc_busy,       // 1 while any syntax element being encoded
    output wire        ctx_init_busy   // 1 during 186-cycle context initialization
);

    // =========================================================================
    // ctx_model_store
    // =========================================================================
    wire [CTX_ID_W-1:0] rd_ctx_id;
    wire [6:0]           rd_state;
    wire                 upd_valid;
    wire [CTX_ID_W-1:0] upd_ctx_id;
    wire                 upd_bin;

    ctx_model_store #(.CTX_ID_W(CTX_ID_W)) u_ctx (
        .clk        (clk),
        .rst_n      (rst_n),
        .slice_init (slice_init),
        .slice_type (slice_type),
        .qp_in      (qp_in),
        .rd_ctx_id  (rd_ctx_id),
        .rd_state   (rd_state),
        .upd_valid  (upd_valid),
        .upd_ctx_id (upd_ctx_id),
        .upd_bin    (upd_bin),
        .init_busy  (ctx_init_busy)
    );

    // =========================================================================
    // range_coder
    // =========================================================================
    wire        rc_bin_valid, rc_bin_value, rc_bin_ready;
    wire [5:0]  rc_pstate;
    wire        rc_valmps;
    wire        rc_ep_valid, rc_ep_value;
    wire        rc_coder_busy;
    wire        rc_muxed_bin_value;

    wire [CTX_ID_W-1:0] rc_ctx_id;
    wire        eff_trm_valid;
    wire        eff_trm_val;

    range_coder u_rc (
        .clk        (clk),
        .rst_n      (rst_n),
        .coder_init (slice_init),
        .bin_valid  (rc_bin_valid),
        .bin_value  (rc_muxed_bin_value),
        .bin_pstate (rc_pstate),
        .bin_valmps (rc_valmps),
        .bin_ctx_id (rc_ctx_id),
        .bin_ready  (rc_bin_ready),
        .ep_valid   (rc_ep_valid),
        .trm_valid  (eff_trm_valid),
        .flush_valid(flush_req),
        .flush_done (flush_done),
        .byte_valid (byte_valid),
        .byte_out   (byte_out),
        .byte_ready (byte_ready),
        .coder_busy (rc_coder_busy)
    );

    // =========================================================================
    // bin_encoder — arbitrated bin mux feeds into this via 2-entry skid buffer
    // =========================================================================
    wire                 be_bin_valid, be_bin_value;
    wire [CTX_ID_W-1:0] be_ctx_id;
    wire                 be_is_ep;
    wire                 be_bin_rdy;
    wire                 be_skid_in_ready;
    wire                 cu_bin_rdy;

    bin_encoder #(.CTX_ID_W(CTX_ID_W)) u_be (
        .clk         (clk),
        .rst_n       (rst_n),
        .init_busy   (ctx_init_busy),
        .bin_valid   (be_bin_valid),
        .bin_value   (be_bin_value),
        .ctx_id      (be_ctx_id),
        .is_ep       (be_is_ep),
        .bin_rdy_out (be_bin_rdy),
        .rd_ctx_id   (rd_ctx_id),
        .rd_state    (rd_state),
        .upd_valid   (upd_valid),
        .upd_ctx_id  (upd_ctx_id),
        .upd_bin     (upd_bin),
        .rc_bin_valid(rc_bin_valid),
        .rc_bin_value(rc_bin_value),
        .rc_pstate   (rc_pstate),
        .rc_valmps   (rc_valmps),
        .rc_bin_ready(rc_bin_ready),
        .rc_ep_valid (rc_ep_valid),
        .rc_ctx_id   (rc_ctx_id)
    );

    // =========================================================================
    // syntax_cu
    // =========================================================================
    wire sc_bin_valid, sc_bin_value, sc_is_ep;
    wire [CTX_ID_W-1:0] sc_ctx_id;

    syntax_cu #(.CTX_ID_W(CTX_ID_W)) u_scu (
        .clk           (clk),
        .rst_n         (rst_n),
        .cu_valid      (cu_req),
        .cu_done       (cu_done),
        .cu_depth      (cu_depth),
        .cu_is_split   (cu_is_split),
        .slice_is_intra(slice_is_intra),
        .cu_skip       (cu_skip),
        .cu_merge      (cu_merge),
        .cu_merge_idx  (cu_merge_idx),
        .cu_pred_intra (cu_pred_intra),
        .cu_part_mode  (cu_part_mode),
        .cu_cbf        (cu_cbf),
        .cu_skip_ctx   (cu_skip_ctx),
        .cu_split_ctx  (cu_split_ctx),
        .bin_valid     (sc_bin_valid),
        .bin_value     (sc_bin_value),
        .bin_ctx_id    (sc_ctx_id),
        .bin_is_ep     (sc_is_ep),
        .bin_rdy       (cu_bin_rdy)
    );

    // =========================================================================
    // syntax_pred
    // =========================================================================
    wire sp_bin_valid, sp_bin_value, sp_is_ep;
    wire [CTX_ID_W-1:0] sp_ctx_id;

    // Standard HEVC MPM Derivation (Clause 8.4.2 / HM getIntraDirPredictor)
    reg [5:0] cand0, cand1, cand2;
    always @(*) begin
        if (cu_left_intra_mode == cu_above_intra_mode) begin
            if (cu_left_intra_mode > 6'd1) begin
                cand0 = cu_left_intra_mode;
                cand1 = 6'd2 + ((cu_left_intra_mode - 6'd2 + 6'd31) % 6'd32);
                cand2 = 6'd2 + ((cu_left_intra_mode - 6'd2 + 6'd1) % 6'd32);
            end else begin
                cand0 = 6'd0;  // Planar
                cand1 = 6'd1;  // DC
                cand2 = 6'd26; // Vertical
            end
        end else begin
            cand0 = cu_left_intra_mode;
            cand1 = cu_above_intra_mode;
            if (cu_left_intra_mode != 6'd0 && cu_above_intra_mode != 6'd0)
                cand2 = 6'd0;
            else if (cu_left_intra_mode != 6'd1 && cu_above_intra_mode != 6'd1)
                cand2 = 6'd1;
            else
                cand2 = 6'd26;
        end
    end

    wire prev_intra_luma_flag = (cu_intra_mode == cand0) || (cu_intra_mode == cand1) || (cu_intra_mode == cand2);
    wire [1:0] intra_mpm_idx  = (cu_intra_mode == cand0) ? 2'd0 :
                                (cu_intra_mode == cand1) ? 2'd1 : 2'd2;

    // Sort MPMs for remaining mode derivation
    reg [5:0] s0, s1, s2;
    reg [5:0] swap_tmp;
    always @(*) begin
        swap_tmp = 6'd0;
        s0 = cand0;
        s1 = cand1;
        s2 = cand2;
        if (s0 > s1) begin swap_tmp = s0; s0 = s1; s1 = swap_tmp; end
        if (s0 > s2) begin swap_tmp = s0; s0 = s2; s2 = swap_tmp; end
        if (s1 > s2) begin swap_tmp = s1; s1 = s2; s2 = swap_tmp; end
    end

    wire [4:0] intra_rem_mode = (cu_intra_mode > s2) ? (cu_intra_mode[4:0] - 5'd3) :
                                (cu_intra_mode > s1) ? (cu_intra_mode[4:0] - 5'd2) :
                                (cu_intra_mode > s0) ? (cu_intra_mode[4:0] - 5'd1) :
                                                       cu_intra_mode[4:0];

    // synthesis translate_off
    always @(posedge clk) begin
        if (pred_req) begin
            $display("Time=%0t: [CABAC_ENC_TOP] pred_req fired! cu_intra_mode=%0d, left=%0d, above=%0d, cand0=%0d, cand1=%0d, cand2=%0d, prev_flag=%b, mpm_idx=%0d",
                     $time, cu_intra_mode, cu_left_intra_mode, cu_above_intra_mode, cand0, cand1, cand2, prev_intra_luma_flag, intra_mpm_idx);
        end
    end
    // synthesis translate_on

    syntax_pred #(.CTX_ID_W(CTX_ID_W), .MVD_W(MVD_W)) u_sp (
        .clk         (clk),
        .rst_n       (rst_n),
        .pred_valid       (pred_req),
        .pred_done        (pred_done),
        .slice_is_b       (slice_is_b),
        .cu_depth         (cu_depth),
        .inter_dir        (inter_dir),
        
        // Intra prediction
        .cu_pred_intra    (cu_pred_intra),
        .prev_intra_luma_pred_flag (prev_intra_luma_flag),
        .mpm_idx          (intra_mpm_idx),
        .rem_intra_luma_pred_mode  (intra_rem_mode),
        .intra_chroma_pred_mode    (cu_chroma_pred_mode),
        
        // L0 prediction
        .ref_idx_l0  (ref_idx_l0),
        .mvp_flag_l0 (mvp_flag_l0),
        .mvd_l0_x    (mvd_l0_x),
        .mvd_l0_y    (mvd_l0_y),
        .ref_idx_l1  (ref_idx_l1),
        .mvp_flag_l1 (mvp_flag_l1),
        .mvd_l1_x    (mvd_l1_x),
        .mvd_l1_y    (mvd_l1_y),
        .bin_valid   (sp_bin_valid),
        .bin_value   (sp_bin_value),
        .bin_ctx_id  (sp_ctx_id),
        .bin_is_ep   (sp_is_ep),
        .bin_rdy     (cu_bin_rdy)
    );

    // =========================================================================
    // syntax_coeff
    // =========================================================================
    wire sf_bin_valid, sf_bin_value, sf_is_ep;
    wire [CTX_ID_W-1:0] sf_ctx_id;

    syntax_coeff #(.CTX_ID_W(CTX_ID_W), .COEFF_W(COEFF_W)) u_sc (
        .clk           (clk),
        .rst_n         (rst_n),
        .coeff_valid   (coeff_req),
        .cu_valid      (cu_req),
        .cu_depth      (cu_depth),
        .coeff_done    (coeff_done),
        .comp_id       (coeff_comp),
        .is_intra      (coeff_is_intra),
        .is_merge      (cu_merge),
        .tu_size_log2  (coeff_tu_size_log2),
        .tu_cbf        (coeff_tu_cbf),
        .last_sig_pos  (coeff_last_sig_pos),
        .scan_mode         (coeff_scan_mode),
        .tu_cg_mask_en     (tu_cg_mask_en),
        .tu_cg_nonzero_mask(tu_cg_nonzero_mask),
        .coeff_rd_en   (coeff_rd_en),
        .coeff_rd_addr (coeff_rd_addr),
        .coeff_rd_data (coeff_rd_data),
        .bin_valid     (sf_bin_valid),
        .bin_value     (sf_bin_value),
        .bin_ctx_id    (sf_ctx_id),
        .bin_is_ep     (sf_is_ep),
        .bin_rdy       (cu_bin_rdy)
    );

    // =========================================================================
    // syntax_sao
    // =========================================================================
    wire ss_bin_valid, ss_bin_value, ss_is_ep;
    wire [CTX_ID_W-1:0] ss_ctx_id;

    syntax_sao #(.CTX_ID_W(CTX_ID_W)) u_ssao (
        .clk        (clk),
        .rst_n      (rst_n),
        .ctu_x      (ctu_x),
        .ctu_y      (ctu_y),
        .sao_req    (sao_req),
        .sao_done   (sao_done),
        .sao_type   (sao_type),
        .eo_class   (sao_eo_class),
        .eo_offset  (sao_eo_offset),
        .band_pos   (sao_band_pos),
        .bo_offset  (sao_bo_offset),
        .bin_valid  (ss_bin_valid),
        .bin_value  (ss_bin_value),
        .bin_ctx_id (ss_ctx_id),
        .bin_is_ep  (ss_is_ep),
        .bin_rdy    (be_skid_in_ready)
    );

    // =========================================================================
    // CTU-Delayed Bin Buffer (2-Bank Ping-Pong 8192 x 10 Block RAM)
    // =========================================================================
    wire eff_ctu_sao_delay_en = (ctu_sao_delay_en === 1'b1);
    wire eff_ctu_bin_drain_en = (ctu_bin_drain_en === 1'b1);

    (* ramstyle = "M10K, no_rw_check", ram_style = "block" *) reg [9:0] ctu_bin_ram_0 [0:8191];
    (* ramstyle = "M10K, no_rw_check", ram_style = "block" *) reg [9:0] ctu_bin_ram_1 [0:8191];

    reg        bin_wr_bank;
    reg        bin_rd_bank;
    reg [1:0]  bin_bank_full;
    reg [12:0] bin_wr_ptr;
    reg [12:0] bin_rd_ptr;
    reg [12:0] bin_bank_len [0:1];
    reg [9:0]  bin_ram_rdata_0_q;
    reg [9:0]  bin_ram_rdata_1_q;
    reg        bin_rd_bank_q;
    reg        drain_prefetched_valid;

    wire [9:0] bin_ram_rdata_q = bin_rd_bank_q ? bin_ram_rdata_1_q : bin_ram_rdata_0_q;

    wire        cu_bin_valid = sc_bin_valid | sp_bin_valid | sf_bin_valid;
    wire        cu_bin_value = sc_bin_valid ? sc_bin_value :
                               sp_bin_valid ? sp_bin_value : sf_bin_value;
    wire [CTX_ID_W-1:0] cu_bin_ctx_id = sc_bin_valid ? sc_ctx_id :
                                        sp_bin_valid ? sp_ctx_id : sf_ctx_id;
    wire        cu_bin_is_ep = sc_bin_valid ? sc_is_ep :
                               sp_bin_valid ? sp_is_ep : sf_is_ep;

    assign      ctu_bin_wr_ready = !bin_bank_full[bin_wr_bank];
    assign      cu_bin_rdy   = eff_ctu_sao_delay_en ? (!bin_bank_full[bin_wr_bank] && (bin_wr_ptr < 13'd8191)) : be_skid_in_ready;

    wire        bin_ram_we   = eff_ctu_sao_delay_en && cu_bin_valid && cu_bin_rdy;
    wire [9:0]  bin_ram_wdata = {cu_bin_is_ep, cu_bin_value, cu_bin_ctx_id};

    wire [12:0] rd_bank_len     = bin_bank_len[bin_rd_bank];
    wire        drain_has_data  = bin_bank_full[bin_rd_bank] && (bin_rd_ptr < rd_bank_len);
    wire        drain_bin_valid = eff_ctu_sao_delay_en && eff_ctu_bin_drain_en && !ss_bin_valid
                                && drain_has_data && drain_prefetched_valid;
    wire        drain_bin_fire  = drain_bin_valid && be_skid_in_ready;
    assign      ctu_bin_drain_done = eff_ctu_sao_delay_en
                                   ? (eff_ctu_bin_drain_en && bin_bank_full[bin_rd_bank] && !drain_has_data)
                                   : 1'b1;

    wire [12:0] bin_rd_addr_mux = drain_bin_fire ? (bin_rd_ptr + 13'd1) : bin_rd_ptr;

    always @(posedge clk) begin
        if (bin_ram_we && !bin_wr_bank)
            ctu_bin_ram_0[bin_wr_ptr] <= bin_ram_wdata;
        if (bin_ram_we && bin_wr_bank)
            ctu_bin_ram_1[bin_wr_ptr] <= bin_ram_wdata;
        bin_ram_rdata_0_q <= ctu_bin_ram_0[bin_rd_addr_mux];
        bin_ram_rdata_1_q <= ctu_bin_ram_1[bin_rd_addr_mux];
        bin_rd_bank_q     <= bin_rd_bank;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bin_wr_bank            <= 1'b0;
            bin_rd_bank            <= 1'b0;
            bin_bank_full          <= 2'b00;
            bin_wr_ptr             <= 13'd0;
            bin_rd_ptr             <= 13'd0;
            bin_bank_len[0]        <= 13'd0;
            bin_bank_len[1]        <= 13'd0;
            drain_prefetched_valid <= 1'b0;
        end else if (slice_init) begin
            bin_wr_bank            <= 1'b0;
            bin_rd_bank            <= 1'b0;
            bin_bank_full          <= 2'b00;
            bin_wr_ptr             <= 13'd0;
            bin_rd_ptr             <= 13'd0;
            bin_bank_len[0]        <= 13'd0;
            bin_bank_len[1]        <= 13'd0;
            drain_prefetched_valid <= 1'b0;
        end else begin
            // Write-bank control (syntax_cu/pred/coeff -> ctu_bin_ram[bin_wr_bank])
            if (eff_ctu_sao_delay_en && ctu_fe_done) begin
                bin_bank_len[bin_wr_bank]  <= bin_wr_ptr + (bin_ram_we ? 13'd1 : 13'd0);
                bin_bank_full[bin_wr_bank] <= 1'b1;
                bin_wr_bank                <= ~bin_wr_bank;
                bin_wr_ptr                 <= 13'd0;
            end else if (bin_ram_we) begin
                bin_wr_ptr <= bin_wr_ptr + 13'd1;
            end

            // Read-bank control (ctu_bin_ram[bin_rd_bank] -> bin_encoder)
            if (trm_req) begin
                if (eff_ctu_sao_delay_en) begin
                    bin_bank_full[bin_rd_bank] <= 1'b0;
                    bin_rd_bank                <= ~bin_rd_bank;
                end
                bin_rd_ptr             <= 13'd0;
                drain_prefetched_valid <= 1'b0;
            end else begin
                if (drain_bin_fire)
                    bin_rd_ptr <= bin_rd_ptr + 13'd1;
                // Track when bin_ram_rdata_q holds already-committed RAM data at bin_rd_addr_mux.
                drain_prefetched_valid <= bin_bank_full[bin_rd_bank] && (bin_rd_addr_mux < rd_bank_len);
            end
        end
    end

    wire        drain_bin_value = bin_ram_rdata_q[8];
    wire [CTX_ID_W-1:0] drain_ctx_id = bin_ram_rdata_q[7:0];
    wire        drain_is_ep     = bin_ram_rdata_q[9];

    // =========================================================================
    // Bin arbitration mux + 2-entry registered skid buffer -> bin_encoder (u_be)
    // Cuts syntax_* / ctu_bin_ram -> u_ctx -> u_rc combinational path for 180 MHz.
    // =========================================================================
    wire                raw_be_bin_valid = eff_ctu_sao_delay_en ? (ss_bin_valid | drain_bin_valid)
                                                                  : (cu_bin_valid | ss_bin_valid);
    wire                raw_be_bin_value = eff_ctu_sao_delay_en ? (ss_bin_valid ? ss_bin_value : drain_bin_value)
                                                                  : (cu_bin_valid ? cu_bin_value : ss_bin_value);
    wire [CTX_ID_W-1:0] raw_be_ctx_id    = eff_ctu_sao_delay_en ? (ss_bin_valid ? ss_ctx_id : drain_ctx_id)
                                                                  : (cu_bin_valid ? cu_bin_ctx_id : ss_ctx_id);
    wire                raw_be_is_ep     = eff_ctu_sao_delay_en ? (ss_bin_valid ? ss_is_ep : drain_is_ep)
                                                                  : (cu_bin_valid ? cu_bin_is_ep : ss_is_ep);

    reg [9:0] be_skid_mem [0:1];
    reg       be_skid_wr_ptr;
    reg       be_skid_rd_ptr;
    reg [1:0] be_skid_count;
    reg       trm_pending;
    reg       trm_pending_val;

    assign be_skid_in_ready = (be_skid_count < 2'd2);
    wire   be_skid_push     = raw_be_bin_valid && be_skid_in_ready;
    wire   be_skid_pop      = (be_skid_count != 2'd0) && be_bin_rdy;

    assign be_bin_valid = (be_skid_count != 2'd0);
    assign be_is_ep     = be_skid_mem[be_skid_rd_ptr][9];
    assign be_bin_value = be_skid_mem[be_skid_rd_ptr][8];
    assign be_ctx_id    = be_skid_mem[be_skid_rd_ptr][7:0];

    wire trm_can_fire_now = (be_skid_count == 2'd0) && rc_bin_ready;
    assign eff_trm_valid  = (trm_pending && trm_can_fire_now) || (trm_req && !trm_pending && trm_can_fire_now);
    assign eff_trm_val    = trm_pending ? trm_pending_val : trm_bin_val;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            be_skid_mem[0]  <= 10'd0;
            be_skid_mem[1]  <= 10'd0;
            be_skid_wr_ptr  <= 1'b0;
            be_skid_rd_ptr  <= 1'b0;
            be_skid_count   <= 2'd0;
            trm_pending     <= 1'b0;
            trm_pending_val <= 1'b0;
        end else if (slice_init) begin
            be_skid_wr_ptr  <= 1'b0;
            be_skid_rd_ptr  <= 1'b0;
            be_skid_count   <= 2'd0;
            trm_pending     <= 1'b0;
            trm_pending_val <= 1'b0;
        end else begin
            if (be_skid_push) begin
                be_skid_mem[be_skid_wr_ptr] <= {raw_be_is_ep, raw_be_bin_value, raw_be_ctx_id};
                be_skid_wr_ptr <= ~be_skid_wr_ptr;
            end
            if (be_skid_pop) begin
                be_skid_rd_ptr <= ~be_skid_rd_ptr;
            end
            case ({be_skid_push, be_skid_pop})
                2'b10:   be_skid_count <= be_skid_count + 2'd1;
                2'b01:   be_skid_count <= be_skid_count - 2'd1;
                default: be_skid_count <= be_skid_count;
            endcase

            if (trm_pending && trm_can_fire_now) begin
                trm_pending <= 1'b0;
            end else if (trm_req && !trm_pending && !trm_can_fire_now) begin
                trm_pending     <= 1'b1;
                trm_pending_val <= trm_bin_val;
            end
        end
    end

    // Mux bin value and context into range_coder
    assign rc_muxed_bin_value = eff_trm_valid ? eff_trm_val : rc_bin_value;

    // =========================================================================
    // Busy signal (includes be_skid_count & trm_pending so trm_req waits cleanly)
    // =========================================================================
    assign enc_busy = (eff_ctu_sao_delay_en ? (drain_bin_valid | ss_bin_valid) : (cu_bin_valid | ss_bin_valid))
                    | (be_skid_count != 2'd0)
                    | trm_pending
                    | ctx_init_busy | rc_coder_busy;

    // =========================================================================
    // Simulation
    // =========================================================================
    // synthesis translate_off
    always @(posedge clk) begin
        // Warn if multiple mutually-exclusive bin sources assert simultaneously
        if (eff_ctu_sao_delay_en) begin
            if (({sc_bin_valid, sp_bin_valid, sf_bin_valid} != 3'b001) &&
                ({sc_bin_valid, sp_bin_valid, sf_bin_valid} != 3'b010) &&
                ({sc_bin_valid, sp_bin_valid, sf_bin_valid} != 3'b100) &&
                ({sc_bin_valid, sp_bin_valid, sf_bin_valid} != 3'b000))
                $display("WARN [cabac_enc_top] multiple FE bin sources active: %b at t=%0t",
                         {sc_bin_valid, sp_bin_valid, sf_bin_valid}, $time);
        end else begin
            if ({sc_bin_valid, sp_bin_valid, sf_bin_valid, ss_bin_valid} != 4'b0001 &&
                {sc_bin_valid, sp_bin_valid, sf_bin_valid, ss_bin_valid} != 4'b0010 &&
                {sc_bin_valid, sp_bin_valid, sf_bin_valid, ss_bin_valid} != 4'b0100 &&
                {sc_bin_valid, sp_bin_valid, sf_bin_valid, ss_bin_valid} != 4'b1000 &&
                {sc_bin_valid, sp_bin_valid, sf_bin_valid, ss_bin_valid} != 4'b0000)
                $display("WARN [cabac_enc_top] multiple bin sources active: %b at t=%0t",
                         {sc_bin_valid, sp_bin_valid, sf_bin_valid, ss_bin_valid}, $time);
        end
        if (eff_ctu_sao_delay_en && cu_bin_valid && !cu_bin_rdy)
            $display("WARN [cabac_enc_top] CTU bin buffer full/backpressure: cu_bin_valid dropped at wr_ptr=%0d t=%0t",
                     bin_wr_ptr, $time);
        if (flush_done)
            $display("INFO [cabac_enc_top] flush done — slice bitstream complete");
            
        // if (be_bin_valid && be_bin_rdy) begin
        //     $display("CABAC_BIN_ENC: value=%b is_ep=%b ctx=%0d at t=%0t", be_bin_value, be_is_ep, be_ctx_id, $time);
        // end
        // if (rc_bin_valid && rc_bin_ready) begin
        //     $display("CABAC_RANGE_CODER: in_val=%b pstate=%0d valmps=%b at t=%0t", rc_muxed_bin_value, rc_pstate, rc_valmps, $time);
        // end
    end
    // synthesis translate_on

endmodule