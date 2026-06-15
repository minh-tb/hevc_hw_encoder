`timescale 1ns / 1ps
//=============================================================================
// cabac_dec_top.v
// CABAC Decoder Top-Level
//
// Stitches bin_decoder with the inverse syntax parsers and coordinates
// the decoding of CTUs, CUs, PUs, and TUs.
//=============================================================================

`include "parameter_pkg.vh"

module cabac_dec_top #(
    parameter CTX_ID_W = 8
)(
    input  wire         clk,
    input  wire         rst_n,

    // NAL input
    input  wire         rbsp_valid,
    input  wire [7:0]   rbsp_byte,
    input  wire         rbsp_last,
    output wire         rbsp_ready,

    // Slice parameters
    input  wire         slice_init,
    input  wire [1:0]   slice_type,
    input  wire [6:0]   slice_qp,

    // Output syntax
    output reg          coeff_valid,
    output wire [15:0]  coeff_out,
    output reg [2:0]    tu_size_log2,
    output wire         is_intra,
    output wire [5:0]   intra_mode,
    output wire [1:0]   inter_dir,
    output wire [2:0]   ref_idx_l0,
    output wire [2:0]   ref_idx_l1,
    output wire signed [11:0] mvd_l0_x,
    output wire signed [11:0] mvd_l0_y,
    output wire signed [11:0] mvd_l1_x,
    output wire signed [11:0] mvd_l1_y,

    // Control
    output wire         slice_done
);

    wire [CTX_ID_W-1:0] rd_ctx_id;
    wire [6:0] rd_state;
    wire upd_valid;
    wire [CTX_ID_W-1:0] upd_ctx_id;
    wire upd_bin;
    wire init_busy;

    ctx_model_store #(.CTX_ID_W(CTX_ID_W)) u_ctx (
        .clk(clk),
        .rst_n(rst_n),
        .slice_init(slice_init),
        .slice_type(slice_type),
        .qp_in(slice_qp),
        .rd_ctx_id(rd_ctx_id),
        .rd_state(rd_state),
        .upd_valid(upd_valid),
        .upd_ctx_id(upd_ctx_id),
        .upd_bin(upd_bin),
        .init_busy(init_busy)
    );

    wire dec_req, dec_ready, dec_valid, dec_bin, is_ep;
    wire [CTX_ID_W-1:0] dec_ctx_id;

    bin_decoder #(.CTX_ID_W(CTX_ID_W)) u_bin_dec (
        .clk(clk),
        .rst_n(rst_n),
        .coder_init(1'b0),
        .rd_ctx_id(rd_ctx_id),
        .rd_state(rd_state),
        .upd_valid(upd_valid),
        .upd_ctx_id(upd_ctx_id),
        .upd_bin(upd_bin),
        .byte_valid(rbsp_valid),
        .byte_in(rbsp_byte),
        .byte_ready(rbsp_ready),
        .dec_req(dec_req),
        .dec_ctx_id(dec_ctx_id),
        .is_ep(is_ep),
        .is_trm(1'b0),
        .dec_ready(dec_ready),
        .dec_valid(dec_valid),
        .dec_bin(dec_bin)
    );

    // Mux requests from syntax modules
    reg [1:0] active_module; // 0=CU, 1=PRED, 2=COEFF
    
    wire cu_req, cu_done;
    wire cu_dec_req, cu_is_ep;
    wire [CTX_ID_W-1:0] cu_dec_ctx_id;

    wire pred_req, pred_done;
    wire pred_dec_req, pred_is_ep;
    wire [CTX_ID_W-1:0] pred_dec_ctx_id;

    wire coeff_req_mod, coeff_done_mod;
    wire coeff_dec_req, coeff_is_ep;
    wire [CTX_ID_W-1:0] coeff_dec_ctx_id;

    assign dec_req = (active_module == 0) ? cu_dec_req :
                     (active_module == 1) ? pred_dec_req :
                                            coeff_dec_req;
    assign dec_ctx_id = (active_module == 0) ? cu_dec_ctx_id :
                        (active_module == 1) ? pred_dec_ctx_id :
                                               coeff_dec_ctx_id;
    assign is_ep = (active_module == 0) ? cu_is_ep :
                   (active_module == 1) ? pred_is_ep :
                                          coeff_is_ep;

    wire cu_is_split, cu_skip, cu_merge, cu_pred_intra, cu_cbf;
    wire [1:0] cu_part_mode;
    assign is_intra = cu_pred_intra;
    assign intra_mode = 6'd0; // Simplified

    syntax_dec_cu u_cu (
        .clk(clk), .rst_n(rst_n),
        .cu_req(cu_req), .cu_done(cu_done),
        .cu_depth(2'd0), .slice_is_intra(1'b0), .cu_skip_ctx(2'd0),
        .cu_is_split(cu_is_split), .cu_skip(cu_skip), .cu_merge(cu_merge),
        .cu_merge_idx(),
        .cu_pred_intra(cu_pred_intra), .cu_part_mode(cu_part_mode), .cu_cbf(cu_cbf),
        .dec_req(cu_dec_req), .dec_ctx_id(cu_dec_ctx_id), .is_ep(cu_is_ep),
        .dec_ready(dec_ready && active_module==0),
        .dec_valid(dec_valid && active_module==0),
        .dec_bin(dec_bin)
    );

    syntax_dec_pred u_pred (
        .clk(clk), .rst_n(rst_n),
        .pred_req(pred_req), .pred_done(pred_done),
        .slice_is_b(1'b0), .cu_depth(2'd0),
        .inter_dir(inter_dir), .ref_idx_l0(ref_idx_l0), .ref_idx_l1(ref_idx_l1),
        .mvp_flag_l0(), .mvp_flag_l1(),
        .mvd_l0_x(mvd_l0_x), .mvd_l0_y(mvd_l0_y),
        .mvd_l1_x(mvd_l1_x), .mvd_l1_y(mvd_l1_y),
        .dec_req(pred_dec_req), .dec_ctx_id(pred_dec_ctx_id), .is_ep(pred_is_ep),
        .dec_ready(dec_ready && active_module==1),
        .dec_valid(dec_valid && active_module==1),
        .dec_bin(dec_bin)
    );

    wire [255:0] flat_coeffs;
    assign coeff_out = flat_coeffs[15:0]; // Simplified to push first coeff for now

    syntax_dec_coeff u_coeff (
        .clk(clk), .rst_n(rst_n),
        .coeff_req(coeff_req_mod), .coeff_done(coeff_done_mod),
        .comp_id(2'd0), .is_intra(cu_pred_intra),
        .coeff_flat(flat_coeffs),
        .dec_req(coeff_dec_req), .dec_ctx_id(coeff_dec_ctx_id), .is_ep(coeff_is_ep),
        .dec_ready(dec_ready && active_module==2),
        .dec_valid(dec_valid && active_module==2),
        .dec_bin(dec_bin)
    );

    // =========================================================================
    // Master FSM: Orchestrating the CTU decoding flow
    // =========================================================================
    reg [2:0] m_state;
    localparam M_IDLE  = 3'd0,
               M_CU    = 3'd1,
               M_PRED  = 3'd2,
               M_COEFF = 3'd3,
               M_NEXT  = 3'd4;

    assign cu_req = (m_state == M_IDLE) && !init_busy && !slice_init;
    assign pred_req = (m_state == M_CU && cu_done && !cu_skip && !cu_pred_intra);
    assign coeff_req_mod = (m_state == M_PRED && pred_done) || (m_state == M_CU && cu_done && cu_pred_intra);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_state <= M_IDLE;
            active_module <= 2'd0;
            coeff_valid <= 1'b0;
            tu_size_log2 <= 3'd2; // 4x4
        end else begin
            coeff_valid <= 1'b0;
            case (m_state)
            M_IDLE: begin
                if (!init_busy && !slice_init) begin
                    active_module <= 2'd0; // CU
                    m_state <= M_CU;
                end
            end
            M_CU: begin
                if (cu_done) begin
                    if (cu_skip) begin
                        m_state <= M_NEXT; // Skips pred and coeff
                    end else if (cu_pred_intra) begin
                        active_module <= 2'd2; // COEFF
                        m_state <= M_COEFF;
                    end else begin
                        active_module <= 2'd1; // PRED
                        m_state <= M_PRED;
                    end
                end
            end
            M_PRED: begin
                if (pred_done) begin
                    active_module <= 2'd2; // COEFF
                    m_state <= M_COEFF;
                end
            end
            M_COEFF: begin
                if (coeff_done_mod) begin
                    coeff_valid <= 1'b1; // Trigger datapath
                    m_state <= M_NEXT;
                end
            end
            M_NEXT: begin
                m_state <= M_IDLE; // Loop to next CU
            end
            endcase
        end
    end

    assign slice_done = 1'b0;

endmodule
