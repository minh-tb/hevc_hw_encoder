//=============================================================================
// tb_spatial_availability.sv
// Exhaustive Unit Testbench for HEVC Spatial Availability Engine
// Standard: ITU-T H.265 Clause 6.4.1 (Z-Scan Availability)
// Tests:
//   - All 340 aligned (x, y, N) block permutations in a 64x64 CTU
//   - All 4 CTU positions in a 128x128 picture (CTU0, CTU1, CTU2, CTU3)
//   - Compares SystemVerilog against golden ITU-T H.265 reference vectors
//=============================================================================

`timescale 1ns / 1ps

module tb_spatial_availability;

    localparam FRAME_WIDTH  = 12'd128;
    localparam FRAME_HEIGHT = 12'd128;

    // Bit-interleaved Morton index for 4x4 blocks in 64x64 CTU
    function automatic [7:0] z_scan_idx_4x4;
        input [3:0] x_blk; // x >> 2
        input [3:0] y_blk; // y >> 2
        begin
            z_scan_idx_4x4 = {y_blk[3], x_blk[3], y_blk[2], x_blk[2], y_blk[1], x_blk[1], y_blk[0], x_blk[0]};
        end
    endfunction

    // Spatial availability for Bottom-Left check sample (x-1, y+N)
    function automatic check_bottom_left_avail;
        input [5:0] x;      // TU origin within CTU
        input [5:0] y;      // TU origin within CTU
        input [5:0] n;      // TU size (4, 8, 16, 32)
        input [11:0] pic_y; // Absolute picture row
        input [5:0] ctu_x;  // CTU col
        reg   [6:0] bl_y;
        begin
            bl_y = {1'b0, y} + {1'b0, n};
            if (pic_y + {6'd0, n} >= FRAME_HEIGHT) begin
                check_bottom_left_avail = 1'b0; // Outside picture bottom
            end else if (bl_y >= 7'd64) begin
                check_bottom_left_avail = 1'b0; // Outside current CTU bottom (not yet coded)
            end else if (x == 6'd0) begin
                check_bottom_left_avail = (ctu_x > 0); // In left CTU (already coded)
            end else begin
                // Inside current CTU: available iff z-scan order is prior to current TU
                check_bottom_left_avail = (z_scan_idx_4x4((x - 6'd1) >> 2, bl_y[5:2]) < z_scan_idx_4x4(x >> 2, y >> 2));
            end
        end
    endfunction

    // Spatial availability for Top-Right check sample (x+N, y-1)
    function automatic check_top_right_avail;
        input [5:0] x;      // TU origin within CTU
        input [5:0] y;      // TU origin within CTU
        input [5:0] n;      // TU size (4, 8, 16, 32)
        input [11:0] pic_x; // Absolute picture col
        input [5:0] ctu_y;  // CTU row
        reg   [6:0] tr_x;
        begin
            tr_x = {1'b0, x} + {1'b0, n};
            if (pic_x + {6'd0, n} >= FRAME_WIDTH) begin
                check_top_right_avail = 1'b0; // Outside picture right
            end else if (y == 6'd0) begin
                // Top CTU boundary: available iff above CTU exists
                check_top_right_avail = (ctu_y > 0);
            end else if (tr_x >= 7'd64) begin
                check_top_right_avail = 1'b0; // Right CTU not yet coded
            end else begin
                // Inside current CTU: available iff z-scan order is prior to current TU
                check_top_right_avail = (z_scan_idx_4x4(tr_x[5:2], (y - 6'd1) >> 2) < z_scan_idx_4x4(x >> 2, y >> 2));
            end
        end
    endfunction

    // Test execution
    integer fd, status;
    integer v_ctu_x, v_ctu_y, v_n, v_x, v_y, v_exp_bl, v_exp_tr;
    integer test_count = 0;
    integer fail_count = 0;
    reg act_bl, act_tr;
    reg [11:0] pic_x, pic_y;

    initial begin
        $display("================================================================");
        $display(" HEVC SPATIAL AVAILABILITY EXHAUSTIVE UNIT TESTBENCH");
        $display(" Standards: ITU-T H.265 Clause 6.4.1 (Morton Z-Scan Availability)");
        $display(" Testing all 340 block permutations x 4 CTUs = 1360 cases...");
        $display("================================================================");

        fd = $fopen("tb/tb_spatial_availability/golden_vectors.txt", "r");
        if (fd == 0) begin
            $display("[FATAL] Could not open golden_vectors.txt");
            $finish;
        end

        while (!$feof(fd)) begin
            status = $fscanf(fd, "%d %d %d %d %d %d %d\n", v_ctu_x, v_ctu_y, v_n, v_x, v_y, v_exp_bl, v_exp_tr);
            if (status == 7) begin
                pic_x = ({6'd0, v_ctu_x[5:0], 6'd0}) + {6'd0, v_x[5:0]};
                pic_y = ({6'd0, v_ctu_y[5:0], 6'd0}) + {6'd0, v_y[5:0]};

                act_bl = check_bottom_left_avail(v_x[5:0], v_y[5:0], v_n[5:0], pic_y, v_ctu_x[5:0]);
                act_tr = check_top_right_avail(v_x[5:0], v_y[5:0], v_n[5:0], pic_x, v_ctu_y[5:0]);

                if (act_bl !== v_exp_bl[0]) begin
                    $display("[FAIL] BL mismatch at CTU=(%0d,%0d) N=%0d x=%0d y=%0d: act=%b exp=%b",
                             v_ctu_x, v_ctu_y, v_n, v_x, v_y, act_bl, v_exp_bl[0]);
                    fail_count = fail_count + 1;
                end
                if (act_tr !== v_exp_tr[0]) begin
                    $display("[FAIL] TR mismatch at CTU=(%0d,%0d) N=%0d x=%0d y=%0d: act=%b exp=%b",
                             v_ctu_x, v_ctu_y, v_n, v_x, v_y, act_tr, v_exp_tr[0]);
                    fail_count = fail_count + 1;
                end

                test_count = test_count + 1;
            end
        end
        $fclose(fd);

        $display("================================================================");
        $display(" SPATIAL AVAILABILITY UNIT TEST SUMMARY:");
        $display("   Total Vector Checks : %0d (BL + TR = %0d checks)", test_count, test_count * 2);
        $display("   Failures            : %0d", fail_count);
        $display("================================================================");
        if (fail_count == 0 && test_count == 1360) begin
            $display("[PASS] *** 100%% CONFORMANT TO ITU-T H.265 CLAUSE 6.4.1 (0 FAILURES) ***");
        end else begin
            $display("[FAIL] *** TESTBENCH FAILED WITH %0d FAILURES ***", fail_count);
        end
        $finish;
    end

endmodule
