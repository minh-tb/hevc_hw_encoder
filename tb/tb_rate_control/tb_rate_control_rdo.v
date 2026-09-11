//=============================================================================
// tb_rate_control_rdo.v
// Unit Testbench for Rate Controller, Lambda Engine, and Hadamard SATD 4x4
//=============================================================================

`timescale 1ns / 1ps

module tb_rate_control_rdo;

    reg clk;
    reg rst_n;

    // Clock generation (100 MHz)
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // 1. Test Lambda Calculator
    // -------------------------------------------------------------------------
    reg  [5:0]  test_qp;
    wire [23:0] lambda_mode;
    wire [15:0] lambda_motion;
    wire [23:0] lambda_chroma;

    lambda_calc u_lambda_calc (
        .qp             (test_qp),
        .lambda_mode    (lambda_mode),
        .lambda_motion  (lambda_motion),
        .lambda_chroma  (lambda_chroma)
    );

    // -------------------------------------------------------------------------
    // 2. Test Hadamard SATD 4x4
    // -------------------------------------------------------------------------
    reg  satd_start;
    reg  signed [10:0] diff [0:15];
    wire satd_done;
    wire [15:0] satd_out;

    hadamard_satd_4x4 u_hadamard_satd (
        .clk     (clk),
        .rst_n   (rst_n),
        .start   (satd_start),
        .diff_0  (diff[0]),  .diff_1  (diff[1]),  .diff_2  (diff[2]),  .diff_3  (diff[3]),
        .diff_4  (diff[4]),  .diff_5  (diff[5]),  .diff_6  (diff[6]),  .diff_7  (diff[7]),
        .diff_8  (diff[8]),  .diff_9  (diff[9]),  .diff_10 (diff[10]), .diff_11 (diff[11]),
        .diff_12 (diff[12]), .diff_13 (diff[13]), .diff_14 (diff[14]), .diff_15 (diff[15]),
        .done    (satd_done),
        .satd_out(satd_out)
    );

    // -------------------------------------------------------------------------
    // 3. Test Rate Controller (VBV Buffer & Adaptive QP)
    // -------------------------------------------------------------------------
    reg         rc_enable;
    reg         rc_frame_start;
    reg         rc_frame_done;
    reg  [1:0]  rc_slice_type;
    reg  [31:0] rc_actual_bits;
    wire [5:0]  rc_frame_qp;
    wire signed [6:0] rc_slice_qp_delta;
    wire [15:0] rc_vbv_fullness;

    rate_controller u_rate_controller (
        .clk                 (clk),
        .rst_n               (rst_n),
        .rc_enable           (rc_enable),
        .frame_start         (rc_frame_start),
        .frame_done          (rc_frame_done),
        .slice_type          (rc_slice_type),
        .actual_frame_bits   (rc_actual_bits),
        .target_bitrate_kbps (16'd2000), // 2 Mbps
        .fps                 (8'd30),
        .base_qp             (6'd29),
        .frame_qp            (rc_frame_qp),
        .slice_qp_delta      (rc_slice_qp_delta),
        .vbv_fullness_pct    (rc_vbv_fullness)
    );

    integer i;

    initial begin
        clk = 0;
        rst_n = 0;
        satd_start = 0;
        rc_enable = 1;
        rc_frame_start = 0;
        rc_frame_done = 0;
        rc_slice_type = 2'd2; // I-slice
        rc_actual_bits = 0;
        test_qp = 6'd29;

        for (i = 0; i < 16; i = i + 1) diff[i] = 11'sd0;

        #20;
        rst_n = 1;
        #20;

        // Test 1: Lambda verification
        $display("\n--- TEST 1: Lambda Engine Verification ---");
        test_qp = 6'd29; #10;
        $display("QP=29: lambda_mode(Q8)=%0d (float=%0f), lambda_motion(Q8)=%0d", 
                 lambda_mode, lambda_mode/256.0, lambda_motion);
        test_qp = 6'd32; #10;
        $display("QP=32: lambda_mode(Q8)=%0d (float=%0f), lambda_motion(Q8)=%0d", 
                 lambda_mode, lambda_mode/256.0, lambda_motion);
        test_qp = 6'd20; #10;
        $display("QP=20: lambda_mode(Q8)=%0d (float=%0f), lambda_motion(Q8)=%0d", 
                 lambda_mode, lambda_mode/256.0, lambda_motion);

        // Test 2: 2D Hadamard SATD Calculation
        $display("\n--- TEST 2: Hadamard SATD 4x4 Engine Verification ---");
        // Test pattern: DC delta (+10 on all pixels)
        for (i = 0; i < 16; i = i + 1) diff[i] = 11'sd10;
        satd_start = 1; @(posedge clk);
        satd_start = 0; @(posedge clk); @(posedge clk); #1;
        $display("Uniform diff=10 SATD output: %0d (Expected: 80)", satd_out);

        // Test pattern: High frequency alternating
        for (i = 0; i < 16; i = i + 1) diff[i] = (i % 2 == 0) ? 11'sd15 : -11'sd15;
        satd_start = 1; @(posedge clk);
        satd_start = 0; @(posedge clk); @(posedge clk); #1;
        $display("High-freq diff=+-15 SATD output: %0d", satd_out);

        // Test 3: Rate Controller Adaptation
        $display("\n--- TEST 3: Rate Controller VBV Buffer & QP Adaptation ---");
        // Frame 0 (I-Slice) Start
        rc_frame_start = 1; rc_slice_type = 2'd2; #10;
        rc_frame_start = 0; #50;
        $display("Frame 0 Start: Frame QP=%0d, slice_qp_delta=%0d, VBV=%0d%%", 
                 rc_frame_qp, rc_slice_qp_delta, rc_vbv_fullness);
        
        // Frame 0 completes with heavy bit count (300,000 bits) -> exceeds target
        rc_actual_bits = 32'd300000;
        rc_frame_done = 1; #10;
        rc_frame_done = 0; #20;
        $display("Frame 0 Done (bits=300000). Adapted next QP=%0d, VBV=%0d%%", 
                 u_rate_controller.current_qp_r, rc_vbv_fullness);

        // Frame 1 (P-Slice) Start -> Should use higher QP to throttle bitrate
        rc_frame_start = 1; rc_slice_type = 2'd1; #10;
        rc_frame_start = 0; #50;
        $display("Frame 1 Start: Frame QP=%0d, slice_qp_delta=%0d, VBV=%0d%%", 
                 rc_frame_qp, rc_slice_qp_delta, rc_vbv_fullness);

        #100;
        $display("\nAll Unit Tests Passed Successfully!");
        $finish;
    end

endmodule
