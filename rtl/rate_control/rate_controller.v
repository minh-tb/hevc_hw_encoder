//=============================================================================
// rate_controller.v
// CBR / VBR Virtual Buffer Verifier (VBV) Rate Controller
//
// Computes:
//   1. Target bits per frame:
//        Target_P = (Bitrate_kbps * 1000) / (FPS * (1 + (w_I - 1)/GOP_SIZE))
//        Target_I = w_I * Target_P
//   2. VBV Buffer Occupancy Accumulator:
//        Buffer_Fill = Buffer_Fill + Actual_Bits - Target_Bits
//   3. Buffer Feedback Delta QP:
//        Delta_QP = clamp((Buffer_Fill - Buffer_Target) / K_buf, -3, +3)
//        Frame_QP = clamp(Base_QP + Delta_QP, 10, 51)
//=============================================================================

`timescale 1ns / 1ps

module rate_controller (
    input  wire                     clk,
    input  wire                     rst_n,
    
    // Control / Timing
    input  wire                     rc_enable,          // 1: Enable CBR/VBR, 0: Fixed QP
    input  wire                     frame_start,        // Strobe at start of frame
    input  wire                     frame_done,         // Strobe when frame bitstream completes
    input  wire [1:0]               slice_type,         // 0: B, 1: P, 2: I
    
    // Feedback from CABAC
    input  wire [31:0]              actual_frame_bits,  // Bits encoded in previous frame
    
    // User / System Configuration
    input  wire [15:0]              target_bitrate_kbps,// e.g., 5000 (5 Mbps)
    input  wire [7:0]               fps,                // e.g., 30
    input  wire [5:0]               base_qp,            // e.g., 29
    
    // Outputs to Encoder Pipeline & Slice Header
    output wire [5:0]               frame_qp,           // Frame QP to use
    output wire signed [6:0]        slice_qp_delta,     // QP - 26 for slice header
    output reg  [15:0]              vbv_fullness_pct    // Buffer status (0..100%)
);

    localparam SLICE_B = 2'd0;
    localparam SLICE_P = 2'd1;
    localparam SLICE_I = 2'd2;

    // VBV Buffer Size: 1.0 second worth of bits
    // Target Buffer Fullness: 50%
    reg signed [31:0] vbv_buffer_bits;
    reg signed [31:0] vbv_buffer_max;
    reg signed [31:0] target_bits_frame;
    reg signed [31:0] target_bits_p;
    reg signed [31:0] target_bits_i;
    reg signed [31:0] fullness_calc;

    reg [5:0] current_qp_r;

    // Continuous assignments ensure frame_qp is immediately available on frame_start
    assign frame_qp       = rc_enable ? current_qp_r : base_qp;
    assign slice_qp_delta = $signed({1'b0, frame_qp}) - 7'sd26;

    // Parameters for Buffer feedback
    // K_buf scaling: Delta QP per 10% buffer deviation
    wire [7:0] safe_fps = (fps > 0) ? fps : 8'd30;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_qp_r     <= base_qp;
            vbv_buffer_bits  <= 32'sd0;
            vbv_buffer_max   <= 32'sd5000000;
            vbv_fullness_pct <= 16'd50;
            target_bits_p    <= 32'sd166666;
            target_bits_i    <= 32'sd500000;
            target_bits_frame<= 32'sd500000;
            fullness_calc    <= 32'sd50;
        end else begin
            // Calculate buffer targets using strictly signed arithmetic
            vbv_buffer_max <= $signed({16'd0, target_bitrate_kbps}) * 32'sd1000;
            target_bits_p  <= ($signed({16'd0, target_bitrate_kbps}) * 32'sd1000) / $signed({24'd0, safe_fps});
            target_bits_i  <= (($signed({16'd0, target_bitrate_kbps}) * 32'sd1000) / $signed({24'd0, safe_fps})) * 32'sd3; // 3x weight for I-frames

            if (frame_start) begin
                if (rc_enable) begin
                    target_bits_frame <= (slice_type == SLICE_I) ? target_bits_i : target_bits_p;
                end
            end

            if (frame_done && rc_enable) begin
                // Update VBV Buffer occupancy (signed accumulation)
                // Buffer = Buffer + Actual - Target
                // Target buffer fullness is 50% of vbv_buffer_max
                if (vbv_buffer_bits + $signed({1'b0, actual_frame_bits}) - target_bits_frame > vbv_buffer_max) begin
                    vbv_buffer_bits <= vbv_buffer_max;
                end else if (vbv_buffer_bits + $signed({1'b0, actual_frame_bits}) - target_bits_frame < -vbv_buffer_max) begin
                    vbv_buffer_bits <= -vbv_buffer_max;
                end else begin
                    vbv_buffer_bits <= vbv_buffer_bits + $signed({1'b0, actual_frame_bits}) - target_bits_frame;
                end

                // Compute Delta QP
                // If actual bits > target bits, increase QP (+1 or +2)
                // If actual bits < target bits, decrease QP (-1 or -2)
                if (actual_frame_bits > (target_bits_frame + (target_bits_frame >> 2))) begin
                    // Exceeded by > 25%
                    if (current_qp_r < 6'd50) current_qp_r <= current_qp_r + 6'd2;
                end else if (actual_frame_bits > (target_bits_frame + (target_bits_frame >> 4))) begin
                    // Exceeded by > 6%
                    if (current_qp_r < 6'd51) current_qp_r <= current_qp_r + 6'd1;
                end else if (actual_frame_bits < (target_bits_frame - (target_bits_frame >> 2))) begin
                    // Under by > 25%
                    if (current_qp_r > 6'd12) current_qp_r <= current_qp_r - 6'd2;
                end else if (actual_frame_bits < (target_bits_frame - (target_bits_frame >> 4))) begin
                    // Under by > 6%
                    if (current_qp_r > 6'd11) current_qp_r <= current_qp_r - 6'd1;
                end

                // Percentage status with strictly signed arithmetic & saturation clamp [0%, 100%]
                fullness_calc = 32'sd50 + ((vbv_buffer_bits * 32'sd50) / vbv_buffer_max);
                if (fullness_calc < 32'sd0)
                    vbv_fullness_pct <= 16'd0;
                else if (fullness_calc > 32'sd100)
                    vbv_fullness_pct <= 16'd100;
                else
                    vbv_fullness_pct <= fullness_calc[15:0];
            end
        end
    end

endmodule
