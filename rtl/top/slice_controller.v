`timescale 1ns / 1ps
//=============================================================================
// slice_controller.v
// Top-Level Slice Controller
//
// Function:
//   Coordinates the start of a frame by first writing the NAL Unit Header
//   and Slice Segment Header via the nal_writer. Once the header is written,
//   it triggers the ctu_raster_scan to begin the actual CTU encoding.
//
//   Uses a semi-static Slice Header generation approach optimized for 
//   the encoder_randomaccess_main10.cfg (Option 2).
//=============================================================================

`include "parameter_pkg.vh"
`include "hevc_interfaces.vh"

module slice_controller (
    input  wire         clk,
    input  wire         rst_n,

    //=========================================================================
    // Interface to GOP Controller
    //=========================================================================
    input  wire         frame_start,
    input  wire [9:0]   frame_poc,
    input  wire [1:0]   frame_slice_type,
    input  wire [2:0]   temporal_id,
    input  wire [5:0]   nal_type,
    output reg          frame_done,

    //=========================================================================
    // Interface to CTU Raster Scan
    //=========================================================================
    output reg          ctu_frame_start,
    input  wire         ctu_frame_done,

    //=========================================================================
    // Interface to NAL Writer
    //=========================================================================
    output reg          nal_start,
    output reg  [5:0]   out_nal_type,
    output reg  [2:0]   out_temporal_id,
    output reg          nal_end,

    output reg          rbsp_valid,
    input  wire         rbsp_ready,
    output reg  [7:0]   rbsp_byte,
    output reg          rbsp_last
);

    localparam SLICE_B = 2'd0;
    localparam SLICE_P = 2'd1;
    localparam SLICE_I = 2'd2;

    localparam NAL_CRA_NUT = 6'd21;

    // FSM States
    localparam S_IDLE       = 3'd0;
    localparam S_NAL_START  = 3'd1;
    localparam S_HDR_PACK   = 3'd2;
    localparam S_HDR_SEND   = 3'd3;
    localparam S_CTU_SCAN   = 3'd4;
    localparam S_WAIT_NAL_END = 3'd5;
    localparam S_DONE       = 3'd6;

    reg [2:0]  state, next_state;

    // Slice Header Shift Register (up to 64 bits for simplified header)
    reg [63:0] hdr_shift_reg;
    reg [6:0]  hdr_bits_left;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= next_state;
    end

    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE: begin
                if (frame_start) next_state = S_NAL_START;
            end
            S_NAL_START: begin
                next_state = S_HDR_PACK;
            end
            S_HDR_PACK: begin
                next_state = S_HDR_SEND;
            end
            S_HDR_SEND: begin
                if (rbsp_valid && rbsp_ready && hdr_bits_left <= 8) begin
                    next_state = S_CTU_SCAN;
                end
            end
            S_CTU_SCAN: begin
                if (ctu_frame_done) next_state = S_WAIT_NAL_END;
            end
            S_WAIT_NAL_END: begin
                next_state = S_DONE;
            end
            S_DONE: begin
                next_state = S_IDLE;
            end
            default: next_state = S_IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_done       <= 1'b0;
            ctu_frame_start  <= 1'b0;
            nal_start        <= 1'b0;
            nal_end          <= 1'b0;
            out_nal_type     <= 6'd0;
            out_temporal_id  <= 3'd0;
            rbsp_valid       <= 1'b0;
            rbsp_byte        <= 8'd0;
            rbsp_last        <= 1'b0;
            hdr_shift_reg    <= 64'd0;
            hdr_bits_left    <= 7'd0;
        end else begin
            frame_done       <= 1'b0;
            ctu_frame_start  <= 1'b0;
            nal_start        <= 1'b0;
            nal_end          <= 1'b0;
            rbsp_valid       <= 1'b0;
            rbsp_last        <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (frame_start) begin
                        out_nal_type    <= nal_type;
                        out_temporal_id <= temporal_id;
                    end
                end

                S_NAL_START: begin
                    nal_start <= 1'b1;
                end

                S_HDR_PACK: begin
                    // --------------------------------------------------------
                    // SIMPLIFIED SLICE HEADER GENERATOR
                    // --------------------------------------------------------
                    // Bit construction (MSB first):
                    // 1 bit: first_slice_segment_in_pic_flag = 1
                    // 1 bit: no_output_of_prior_pics_flag (only if CRA) = 0
                    // 1 bit: slice_pic_parameter_set_id (ue(v) = 0) -> bits '1'
                    // X bit: slice_type (ue(v) B=1, P=010, I=011)
                    //
                    // To keep things simple, we pack this into the shift register
                    // from left to right (MSB down).
                    // --------------------------------------------------------
                    hdr_shift_reg <= 64'd0; // Clear
                    
                    if (frame_slice_type == SLICE_I && nal_type == NAL_CRA_NUT) begin
                        // CRA I-Slice Header
                        // 1 (first), 0 (no_prior), 1 (pps=0), 011 (type=I), POC[7:0],
                        // 1 (short_term_ref_pic_set_sps_flag), 1 (qp_delta=0),
                        // 1 (byte alignment), 7'd0 (padding)
                        hdr_shift_reg[63:40] <= { 1'b1, 1'b0, 1'b1, 3'b011, frame_poc[7:0], 1'b1, 1'b1, 1'b1, 7'd0 };
                        hdr_bits_left        <= 7'd24;
                    end else begin
                        // B-Slice Header
                        // 1 (first), 1 (pps=0), 1 (type=B), POC[7:0],
                        // 1 (short_term_ref_pic_set_sps_flag), 0 (num_ref_idx_active_override),
                        // 0 (mvd_l1_zero), 1 (five_minus_max_merge_cand=0), 1 (qp_delta=0),
                        // 1 (byte alignment), 7'd0 (padding)
                        hdr_shift_reg[63:40] <= { 1'b1, 1'b1, 1'b1, frame_poc[7:0], 1'b1, 1'b0, 1'b0, 1'b1, 1'b1, 1'b1, 7'd0 };
                        hdr_bits_left        <= 7'd24;
                    end
                end

                S_HDR_SEND: begin
                    rbsp_valid <= 1'b1;
                    
                    // Since it's RBSP, we just take the top 8 bits of the shift register
                    // If we have less than 8 bits left, they will be padded with zeros
                    // (The trailing 1 bit alignment in S_HDR_PACK covers the bitstream requirement)
                    rbsp_byte  <= (rbsp_ready && hdr_bits_left > 8) ? hdr_shift_reg[55:48] : hdr_shift_reg[63:56];
                    
                    if (hdr_bits_left <= 8) begin
                        rbsp_last <= 1'b0; // Wait, nal_end is pulsed at very end of frame!
                        if (rbsp_ready) begin
                            ctu_frame_start <= 1'b1;
                            hdr_bits_left <= 0;
                            rbsp_valid <= 1'b0; // Prevent trailing duplicate byte
                        end
                    end else begin
                        if (rbsp_ready) begin
                            hdr_shift_reg <= hdr_shift_reg << 8;
                            hdr_bits_left <= hdr_bits_left - 7'd8;
                        end
                    end
                end

                S_CTU_SCAN: begin
                    // Wait for the CTU raster scanner to finish all CTUs in the frame
                    // The CABAC engine inside the CTU pipeline will write its data
                    // directly to the bitstream / nal_writer during this state.
                end

                S_WAIT_NAL_END: begin
                    // 1 cycle delay to let the CABAC flush bytes get processed by nal_writer
                end

                S_DONE: begin
                    // Finalize the NAL unit
                    nal_end    <= 1'b1;
                    frame_done <= 1'b1;
                end
            endcase
        end
    end

endmodule
