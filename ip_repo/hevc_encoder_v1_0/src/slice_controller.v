`timescale 1ns / 1ps
//=============================================================================
// slice_controller.v
// Top-Level Slice Controller
//=============================================================================

`include "parameter_pkg.vh"
`include "hevc_interfaces.vh"

module slice_controller #(
    parameter FRAME_WIDTH  = 64,
    parameter FRAME_HEIGHT = 64
)(
    input  wire         clk,
    input  wire         rst_n,

    input  wire         frame_start,
    input  wire [9:0]   frame_poc,
    input  wire [1:0]   frame_slice_type,
    input  wire [5:0]   frame_qp,
    input  wire [2:0]   temporal_id,
    input  wire [5:0]   nal_type,
    output reg          frame_done,

    output reg          ctu_frame_start,
    input  wire         ctu_frame_done,

    output reg          nal_start,
    output reg  [5:0]   out_nal_type,
    output reg  [2:0]   out_temporal_id,
    output reg          nal_end,

    output wire         rbsp_valid,
    input  wire         rbsp_ready,
    output wire [7:0]   rbsp_byte,
    output wire         rbsp_last
);

    localparam SLICE_B = 2'd0;
    localparam SLICE_P = 2'd1;
    localparam SLICE_I = 2'd2;

    localparam S_IDLE         = 5'd0;
    localparam S_VPS_START    = 5'd1;
    localparam S_VPS_SEND     = 5'd2;
    localparam S_VPS_WAIT     = 5'd3;
    localparam S_SPS_START    = 5'd4;
    localparam S_SPS_SEND     = 5'd5;
    localparam S_SPS_WAIT     = 5'd6;
    localparam S_PPS_START    = 5'd7;
    localparam S_PPS_SEND     = 5'd8;
    localparam S_PPS_WAIT     = 5'd9;
    localparam S_NAL_START    = 5'd10;
    localparam S_HDR_PACK     = 5'd11;
    localparam S_HDR_SEND     = 5'd12;
    localparam S_CTU_SCAN     = 5'd13;
    localparam S_WAIT_NAL_END = 5'd14;
    localparam S_DONE         = 5'd15;

    reg [4:0] state, next_state;
    reg [2:0] wait_cnt;

    reg  [63:0] hdr_shift_reg;
    reg  [6:0]  hdr_bits_left;

    // Latched frame parameters (captured at frame_start)
    reg  [1:0]  latched_slice_type;
    reg  [5:0]  latched_nal_type;
    reg  [2:0]  latched_temporal_id;
    reg  [9:0]  latched_poc;

    reg         psw_vps_req;
    reg         psw_sps_req;
    reg         psw_pps_req;
    wire        psw_vps_done;
    wire        psw_sps_done;
    wire        psw_pps_done;

    wire        psw_rbsp_valid;
    wire        psw_rbsp_ready;
    wire [7:0]  psw_rbsp_byte;
    wire        psw_rbsp_last;

    assign psw_rbsp_ready = (state == S_VPS_SEND || state == S_SPS_SEND || state == S_PPS_SEND) ? rbsp_ready : 1'b0;

    param_set_writer #(
        .FRAME_WIDTH  (FRAME_WIDTH),
        .FRAME_HEIGHT (FRAME_HEIGHT)
    ) u_param_set_writer (
        .clk        (clk),
        .rst_n      (rst_n),
        .vps_req    (psw_vps_req),
        .sps_req    (psw_sps_req),
        .pps_req    (psw_pps_req),
        .vps_done   (psw_vps_done),
        .sps_done   (psw_sps_done),
        .pps_done   (psw_pps_done),
        .rbsp_valid (psw_rbsp_valid),
        .rbsp_ready (psw_rbsp_ready),
        .rbsp_byte  (psw_rbsp_byte),
        .rbsp_last  (psw_rbsp_last)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= next_state;
    end

    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE: begin
                if (frame_start) begin
                    // Send VPS/SPS/PPS only before I-frames (CRA)
                    if (frame_slice_type == SLICE_I)
                        next_state = S_VPS_START;
                    else
                        next_state = S_NAL_START;  // P-frame: skip to slice NAL
                end
            end
            S_VPS_START: begin
                next_state = S_VPS_SEND;
            end
            S_VPS_SEND: begin
                if (psw_vps_done) next_state = S_VPS_WAIT;
            end
            S_VPS_WAIT: begin
                if (wait_cnt == 3'd3) next_state = S_SPS_START;
            end
            S_SPS_START: begin
                next_state = S_SPS_SEND;
            end
            S_SPS_SEND: begin
                if (psw_sps_done) next_state = S_SPS_WAIT;
            end
            S_SPS_WAIT: begin
                if (wait_cnt == 3'd3) next_state = S_PPS_START;
            end
            S_PPS_START: begin
                next_state = S_PPS_SEND;
            end
            S_PPS_SEND: begin
                if (psw_pps_done) next_state = S_PPS_WAIT;
            end
            S_PPS_WAIT: begin
                if (wait_cnt == 3'd3) next_state = S_NAL_START;
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

    reg         int_rbsp_valid;
    reg  [7:0]  int_rbsp_byte;
    reg         int_rbsp_last;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_done       <= 1'b0;
            ctu_frame_start  <= 1'b0;
            nal_start        <= 1'b0;
            nal_end          <= 1'b0;
            out_nal_type     <= 6'd0;
            out_temporal_id  <= 3'd0;
            int_rbsp_valid   <= 1'b0;
            int_rbsp_byte    <= 8'd0;
            int_rbsp_last    <= 1'b0;
            hdr_shift_reg    <= 64'd0;
            hdr_bits_left    <= 7'd0;
            psw_vps_req      <= 1'b0;
            psw_sps_req      <= 1'b0;
            psw_pps_req      <= 1'b0;
            wait_cnt         <= 3'd0;
        end else begin
            frame_done       <= 1'b0;
            ctu_frame_start  <= 1'b0;
            nal_start        <= 1'b0;
            nal_end          <= 1'b0;
            int_rbsp_valid   <= 1'b0;
            int_rbsp_last    <= 1'b0;
            psw_vps_req      <= 1'b0;
            psw_sps_req      <= 1'b0;
            psw_pps_req      <= 1'b0;

            case (state)
                S_IDLE: begin
                    wait_cnt <= 3'd0;
                    if (frame_start) begin
                        latched_slice_type  <= frame_slice_type;
                        latched_nal_type    <= nal_type;
                        latched_temporal_id <= temporal_id;
                        latched_poc         <= frame_poc;
                    end
                end
                
                S_VPS_START: begin
                    nal_start       <= 1'b1;
                    psw_vps_req     <= 1'b1;
                    out_nal_type    <= 6'd32; // VPS
                    out_temporal_id <= 3'd0;
                end
                
                S_VPS_SEND: begin
                    out_nal_type    <= 6'd32;
                    out_temporal_id <= 3'd0;
                    if (psw_vps_done) nal_end <= 1'b1;
                end
                
                S_VPS_WAIT: begin
                    wait_cnt <= wait_cnt + 3'd1;
                end

                S_SPS_START: begin
                    wait_cnt        <= 3'd0;
                    nal_start       <= 1'b1;
                    psw_sps_req     <= 1'b1;
                    out_nal_type    <= 6'd33; // SPS
                    out_temporal_id <= 3'd0;
                end
                
                S_SPS_SEND: begin
                    out_nal_type    <= 6'd33;
                    out_temporal_id <= 3'd0;
                    if (psw_sps_done) nal_end <= 1'b1;
                end
                
                S_SPS_WAIT: begin
                    wait_cnt <= wait_cnt + 3'd1;
                end

                S_PPS_START: begin
                    wait_cnt        <= 3'd0;
                    nal_start       <= 1'b1;
                    psw_pps_req     <= 1'b1;
                    out_nal_type    <= 6'd34; // PPS
                    out_temporal_id <= 3'd0;
                end
                
                S_PPS_SEND: begin
                    out_nal_type    <= 6'd34;
                    out_temporal_id <= 3'd0;
                    if (psw_pps_done) nal_end <= 1'b1;
                end
                
                S_PPS_WAIT: begin
                    wait_cnt <= wait_cnt + 3'd1;
                end

                S_NAL_START: begin
                    wait_cnt        <= 3'd0;
                    nal_start       <= 1'b1;
                    out_nal_type    <= latched_nal_type;   // CRA=21 or TRAIL_R=1
                    out_temporal_id <= latched_temporal_id;
                end

                S_HDR_PACK: begin
                    hdr_shift_reg   <= 64'd0;
                    out_nal_type    <= latched_nal_type;
                    out_temporal_id <= latched_temporal_id;

`include "slice_cases.vh"
                end

                S_HDR_SEND: begin
                    int_rbsp_valid <= 1'b1;
                    int_rbsp_byte  <= hdr_shift_reg[63:56];
                    
                    out_nal_type    <= latched_nal_type;
                    out_temporal_id <= latched_temporal_id;
                    
                    if (hdr_bits_left <= 8) begin
                        int_rbsp_last <= 1'b0;
                        if (rbsp_ready) begin
                            ctu_frame_start <= 1'b1;
                            hdr_bits_left <= 0;
                            int_rbsp_valid <= 1'b0;
                        end
                    end else begin
                        if (rbsp_ready) begin
                            hdr_shift_reg <= hdr_shift_reg << 8;
                            hdr_bits_left <= hdr_bits_left - 7'd8;
                        end
                    end
                end

                S_CTU_SCAN: begin
                    out_nal_type    <= latched_nal_type;
                end

                S_WAIT_NAL_END: begin
                    out_nal_type    <= latched_nal_type;
                end

                S_DONE: begin
                    nal_end    <= 1'b1;
                    frame_done <= 1'b1;
                    out_nal_type    <= latched_nal_type;
                end
            endcase
        end
    end

    assign rbsp_valid = (state == S_HDR_SEND) ? int_rbsp_valid :
                        (state == S_VPS_SEND || state == S_SPS_SEND || state == S_PPS_SEND) ? psw_rbsp_valid : 1'b0;
    assign rbsp_byte  = (state == S_HDR_SEND) ? hdr_shift_reg[63:56] :
                        (state == S_VPS_SEND || state == S_SPS_SEND || state == S_PPS_SEND) ? psw_rbsp_byte : 8'd0;
    assign rbsp_last  = (state == S_HDR_SEND) ? int_rbsp_last :
                        (state == S_VPS_SEND || state == S_SPS_SEND || state == S_PPS_SEND) ? psw_rbsp_last : 1'b0;

endmodule
