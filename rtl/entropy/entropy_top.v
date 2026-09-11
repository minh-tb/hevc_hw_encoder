//=============================================================================
// entropy_top.v
// Top-Level HEVC Entropy Coding Wrapper
//
// Wraps param_set_writer, slice_controller, cabac_enc_top, and nal_writer
// into a single unified entropy module with a clean frame/CTU interface.
//
// Target: I-Slice only, 64x64 resolution, Main 10 profile.
//=============================================================================

`include "parameter_pkg.vh"

module entropy_top #(
    parameter CTX_ID_W = 8,
    parameter COEFF_W  = 16,
    parameter MVD_W    = 12,
    parameter N_COEFF  = 16
)(
    input  wire         clk,
    input  wire         rst_n,

    // Frame-level Control
    input  wire         frame_start,
    output wire         frame_done,
    
    // CTU-level Control
    output wire         ctu_frame_start,
    input  wire         ctu_frame_done,

    // CU/TU Syntax Coding Interface
    input  wire         cu_req,
    output wire         cu_done,
    input  wire [1:0]   cu_depth,
    input  wire         cu_is_split,
    input  wire         cu_pred_intra,
    input  wire         cu_cbf,

    input  wire         pred_req,
    output wire         pred_done,

    input  wire         coeff_req,
    output wire         coeff_done,
    input  wire [1:0]   coeff_comp,
    input  wire [COEFF_W*N_COEFF-1:0] coeff_flat,

    // Output Annex B Bitstream
    output wire         out_valid,
    input  wire         out_ready,
    output wire [7:0]   out_byte
);

    //=========================================================================
    // Internal Signals
    //=========================================================================
    // FSM States
    // FSM States
    localparam S_IDLE           = 4'd0;
    localparam S_WRITE_SLICE_HDR= 4'd1;
    localparam S_ENCODE_CTUS    = 4'd2;
    localparam S_WAIT_CABAC_IDLE_FOR_TRM = 4'd3;
    localparam S_FLUSH_TRM      = 4'd4;
    localparam S_WAIT_CABAC_IDLE_FOR_FLUSH = 4'd5;
    localparam S_FLUSH_WAIT     = 4'd6;

    reg [3:0] state;

    // Parameter Set Writer signals
    reg  vps_req_r, sps_req_r, pps_req_r;
    wire vps_done, sps_done, pps_done;
    wire psw_rbsp_valid;
    wire [7:0] psw_rbsp_byte;
    wire psw_rbsp_last;

    // Slice Controller signals
    reg  sc_frame_start_r;
    wire sc_ctu_frame_start;
    reg  sc_ctu_frame_done_r;
    wire sc_nal_start;
    wire [5:0] sc_out_nal_type;
    wire [2:0] sc_out_temporal_id;
    wire sc_nal_end;
    wire sc_rbsp_valid;
    wire [7:0] sc_rbsp_byte;
    wire sc_rbsp_last;
    wire sc_frame_done;

    // CABAC Encoder Top signals
    wire cabac_ctx_init_busy;
    wire cabac_out_valid;
    wire [7:0] cabac_out_byte;
    reg  cabac_trm_req_r;
    reg  cabac_flush_req_r;
    wire cabac_flush_done;
    wire cabac_enc_busy;

    // NAL Writer Multiplexed Signals
    reg        nal_start;
    reg [5:0]  nal_type;
    reg [2:0]  nal_temporal_id;
    reg        nal_end;

    reg        rbsp_valid;
    wire       rbsp_ready;
    reg [7:0]  rbsp_byte;
    reg        rbsp_last;

    //=========================================================================
    // Sub-Module Instantiations
    //=========================================================================
    
    // 1. Parameter Set ROM Writer (Moved to slice_controller.v)
    
    // 2. Slice Controller (CRA/IDR Slice Header + VPS/SPS/PPS)
    slice_controller u_slice_controller (
        .clk              (clk),
        .rst_n            (rst_n),
        .frame_start      (sc_frame_start_r),
        .frame_poc        (10'd0), // POC always 0 for IDR
        .frame_slice_type (2'd2),  // I-slice (SLICE_I = 2)
        .temporal_id      (3'd0),
        .nal_type         (6'd19), // IDR_W_RADL
        .frame_done       (sc_frame_done),
        .ctu_frame_start  (sc_ctu_frame_start),
        .ctu_frame_done   (sc_ctu_frame_done_r),
        .nal_start        (sc_nal_start),
        .out_nal_type     (sc_out_nal_type),
        .out_temporal_id  (sc_out_temporal_id),
        .nal_end          (sc_nal_end),
        .rbsp_valid       (sc_rbsp_valid),
        .rbsp_ready       (rbsp_ready),
        .rbsp_byte        (sc_rbsp_byte),
        .rbsp_last        (sc_rbsp_last)
    );

    // 3. CABAC Encoder Core
    cabac_enc_top #(
        .CTX_ID_W (CTX_ID_W),
        .COEFF_W  (COEFF_W),
        .MVD_W    (MVD_W),
        .N_COEFF  (N_COEFF)
    ) u_cabac_enc_top (
        .clk              (clk),
        .rst_n            (rst_n),
        .qp_in            (7'd29), // Hardcoded to 29 (matches slice header QP delta)
        .slice_init       (sc_ctu_frame_start),
        .slice_type       (2'd2),  // 2=I-slice in cabac_enc_top slice_type map
        .ctx_init_busy    (cabac_ctx_init_busy),

        // CU syntax ports
        .cu_req           (cu_req && (state == S_ENCODE_CTUS)),
        .cu_done          (cu_done),
        .cu_depth         (cu_depth),
        .cu_is_split      (cu_is_split),
        .slice_is_intra   (1'b1), // always intra for I-slice
        .cu_skip          (1'b0), // no skip in intra
        .cu_merge         (1'b0),
        .cu_merge_idx     (3'd0),
        .cu_skip_ctx      (2'd0),
        .cu_pred_intra    (cu_pred_intra),
        .cu_part_mode     (2'd0), // PART_2Nx2N
        .cu_cbf           (cu_cbf),

        // Pred syntax ports
        .pred_req         (pred_req && (state == S_ENCODE_CTUS)),
        .pred_done        (pred_done),
        .slice_is_b       (1'b0),
        .inter_dir        (2'd0),
        .ref_idx_l0       (3'd0),
        .mvp_flag_l0      (1'b0),
        .mvd_l0_x         (12'd0),
        .mvd_l0_y         (12'd0),
        .ref_idx_l1       (3'd0),
        .mvp_flag_l1      (1'b0),
        .mvd_l1_x         (12'd0),
        .mvd_l1_y         (12'd0),

        // Coeff syntax ports
        .coeff_req        (coeff_req && (state == S_ENCODE_CTUS)),
        .coeff_done       (coeff_done),
        .coeff_comp       (coeff_comp),
        .coeff_is_intra   (1'b1),
        .coeff_flat       (coeff_flat),

        // Terminating / Flush control
        .trm_req          (cabac_trm_req_r),
        .trm_bin_val      (1'b1), // end_of_slice_segment_flag = 1
        .flush_req        (cabac_flush_req_r),
        .flush_done       (cabac_flush_done),

        // Output stream
        .byte_valid       (cabac_out_valid),
        .byte_out         (cabac_out_byte),
        .byte_ready       (rbsp_ready),
        .enc_busy         (cabac_enc_busy)
    );

    // 4. Annex B Framer & Emulation Prevention
    nal_writer u_nal_writer (
        .clk              (clk),
        .rst_n            (rst_n),
        .nal_start        (nal_start),
        .nal_type         (nal_type),
        .temporal_id      (nal_temporal_id),
        .nal_end          (nal_end),
        .rbsp_valid       (rbsp_valid),
        .rbsp_ready       (rbsp_ready),
        .rbsp_byte        (rbsp_byte),
        .rbsp_last        (rbsp_last),
        .out_valid        (out_valid),
        .out_ready        (out_ready),
        .out_byte         (out_byte),
        .out_last_in_nal  (),
        .nal_byte_count   (),
        .total_nal_count  ()
    );

    //=========================================================================
    // Control FSM
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= S_IDLE;
            vps_req_r           <= 1'b0;
            sps_req_r           <= 1'b0;
            pps_req_r           <= 1'b0;
            sc_frame_start_r    <= 1'b0;
            sc_ctu_frame_done_r <= 1'b0;
            cabac_trm_req_r     <= 1'b0;
            cabac_flush_req_r   <= 1'b0;
        end else begin
            vps_req_r           <= 1'b0;
            sps_req_r           <= 1'b0;
            pps_req_r           <= 1'b0;
            sc_frame_start_r    <= 1'b0;
            sc_ctu_frame_done_r <= 1'b0;
            cabac_trm_req_r     <= 1'b0;
            cabac_flush_req_r   <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (frame_start) begin
                        sc_frame_start_r <= 1'b1;
                        state            <= S_WRITE_SLICE_HDR;
                    end
                end

                S_WRITE_SLICE_HDR: begin
                    // Wait for slice header to finish sending and CTU scanning to start
                    if (sc_ctu_frame_start) begin
                        state <= S_ENCODE_CTUS;
                    end
                end

                S_ENCODE_CTUS: begin
                    if (ctu_frame_done) begin
                        // synthesis translate_off
                        $display("Time=%0t: [ENTROPY_TOP] ctu_frame_done received! Entering S_WAIT_CABAC_IDLE_FOR_TRM", $time);
                        // synthesis translate_on
                        state <= S_WAIT_CABAC_IDLE_FOR_TRM;
                    end
                end
                
                S_WAIT_CABAC_IDLE_FOR_TRM: begin
                    if (!cabac_enc_busy) begin
                        // synthesis translate_off
                        $display("Time=%0t: [ENTROPY_TOP] cabac_enc_busy is false, asserting cabac_trm_req_r", $time);
                        // synthesis translate_on
                        cabac_trm_req_r <= 1'b1;
                        state           <= S_FLUSH_TRM;
                    end
                end

                S_FLUSH_TRM: begin
                    state <= S_WAIT_CABAC_IDLE_FOR_FLUSH;
                    // synthesis translate_off
                    $display("Time=%0t: [ENTROPY_TOP] S_FLUSH_TRM -> Waiting for CABAC idle for FLUSH...", $time);
                    // synthesis translate_on
                end
                
                S_WAIT_CABAC_IDLE_FOR_FLUSH: begin
                    if (!cabac_enc_busy) begin
                        state <= S_FLUSH_WAIT;
                        // synthesis translate_off
                        $display("Time=%0t: [ENTROPY_TOP] CABAC idle! Entering S_FLUSH_WAIT.", $time);
                        // synthesis translate_on
                    end
                end

                S_FLUSH_WAIT: begin
                    cabac_flush_req_r <= 1'b1; // Hold flush request high until done
                    if (cabac_flush_done) begin
                        cabac_flush_req_r   <= 1'b0;
                        sc_ctu_frame_done_r <= 1'b1; // Trigger slice_controller to end the NAL
                        state               <= S_IDLE;
                    end
                end
            endcase
        end
    end

    assign ctu_frame_start = sc_ctu_frame_start;
    assign frame_done      = sc_frame_done;

    //=========================================================================
    // RBSP and NAL Control Multiplexer
    //=========================================================================
    always @(*) begin
        // Default tie-offs
        nal_start       = 1'b0;
        nal_type        = 6'd0;
        nal_temporal_id = 3'd0;
        nal_end         = 1'b0;
        rbsp_valid      = 1'b0;
        rbsp_byte       = 8'd0;
        rbsp_last       = 1'b0;

        case (state)
            S_WRITE_SLICE_HDR: begin
                nal_start       = sc_nal_start;
                nal_type        = sc_out_nal_type;
                nal_temporal_id = sc_out_temporal_id;
                nal_end         = 1'b0;
                rbsp_valid      = sc_rbsp_valid;
                rbsp_byte       = sc_rbsp_byte;
                rbsp_last       = sc_rbsp_last;
            end

            S_ENCODE_CTUS, S_FLUSH_TRM, S_FLUSH_WAIT: begin
                nal_start       = sc_nal_start;
                nal_type        = sc_out_nal_type;
                nal_temporal_id = sc_out_temporal_id;
                nal_end         = sc_nal_end;
                rbsp_valid      = cabac_out_valid;
                rbsp_byte       = cabac_out_byte;
                rbsp_last       = 1'b0; // End of slice NAL is driven by slice_controller nal_end
            end

            default: begin
                nal_start       = sc_nal_start;
                nal_type        = sc_out_nal_type;
                nal_temporal_id = sc_out_temporal_id;
                nal_end         = sc_nal_end;
                rbsp_valid      = 1'b0;
                rbsp_byte       = 8'd0;
                rbsp_last       = 1'b0;
            end
        endcase
    end

endmodule
