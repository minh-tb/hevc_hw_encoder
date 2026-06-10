//=============================================================================
// tb_mc_unit.sv
// Testbench for Motion Compensation Unit
//
// Reads test vectors generated from HM Reference Software.
// File format (199 decimal integers per line):
// CU_X CU_Y MV_X MV_Y
// [121 Luma Ext Pixels (11x11)]
// [25 Cb Ext Pixels (5x5)]
// [25 Cr Ext Pixels (5x5)]
// [16 Expected Pred Luma (4x4)]
// [4 Expected Pred Cb (2x2)]
// [4 Expected Pred Cr (2x2)]
//=============================================================================

`timescale 1ns/1ps
`include "parameter_pkg.vh"

module tb_mc_unit;

    // TB Parameters
    parameter BLK_SIZE = 4;
    parameter BLK_C    = 2;
    parameter BLK_EXT_Y= 11;
    parameter BLK_EXT_C= 5;
    
    parameter PX_Y     = `PIXEL_WIDTH * BLK_SIZE * BLK_SIZE;
    parameter PX_C     = `PIXEL_WIDTH * BLK_C * BLK_C;
    parameter PX_EXT_Y = `PIXEL_WIDTH * BLK_EXT_Y * BLK_EXT_Y;
    parameter PX_EXT_C = `PIXEL_WIDTH * BLK_EXT_C * BLK_EXT_C;

    logic clk;
    logic rst_n;

    // DUT Inputs
    logic        mc_start;
    logic [2:0]  mc_ref_slot;
    logic [11:0] mc_cu_x;
    logic [11:0] mc_cu_y;
    logic signed [13:0] mc_mv_x;
    logic signed [13:0] mc_mv_y;

    // DUT Outputs
    logic        mc_ready;
    logic        mc_done;
    logic [PX_Y-1:0] pred_y_flat;
    logic [PX_C-1:0] pred_cb_flat;
    logic [PX_C-1:0] pred_cr_flat;

    // Memory Interface
    logic        ref_req_valid;
    logic [1:0]  ref_req_comp;
    logic [2:0]  ref_req_slot;
    logic [11:0] ref_req_x;
    logic [11:0] ref_req_y;
    
    logic        ref_resp_valid;
    logic [PX_EXT_Y-1:0] ref_resp_y_flat;
    logic [PX_EXT_C-1:0] ref_resp_cb_flat;
    logic [PX_EXT_C-1:0] ref_resp_cr_flat;

    // DUT Instantiation
    mc_unit #(
        .PIXEL_WIDTH(`PIXEL_WIDTH),
        .BLK_SIZE(BLK_SIZE),
        .MV_QP_W(14),
        .CU_COORD_W(12)
    ) dut (.*);

    // Clock Generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100 MHz
    end

    // Memory Mock-up state variables
    logic [PX_EXT_Y-1:0] mem_y_ext;
    logic [PX_EXT_C-1:0] mem_cb_ext;
    logic [PX_EXT_C-1:0] mem_cr_ext;

    // Simulate Memory Latency
    always @(posedge clk) begin
        if (!rst_n) begin
            ref_resp_valid <= 0;
        end else begin
            ref_resp_valid <= 0;
            if (ref_req_valid) begin
                // Introduce random memory read latency (1 to 5 cycles)
                repeat ($urandom_range(1, 5)) @(posedge clk);
                
                ref_resp_valid <= 1;
                if (ref_req_comp == 2'd0)      ref_resp_y_flat  <= mem_y_ext;
                else if (ref_req_comp == 2'd1) ref_resp_cb_flat <= mem_cb_ext;
                else if (ref_req_comp == 2'd2) ref_resp_cr_flat <= mem_cr_ext;
            end
        end
    end

    // Stimulus and Checking Variables
    int fd, scan_ret;
    int f_cux, f_cuy, f_mvx, f_mvy;
    int f_ref_y[121], f_ref_cb[25], f_ref_cr[25];
    int f_exp_y[16],  f_exp_cb[4],  f_exp_cr[4];

    int total_tested = 0;
    int total_errors = 0;
    int val;

    // Main Test Sequence
    initial begin
        mc_start = 0;
        mc_ref_slot = 0;
        rst_n = 0;
        
        fd = $fopen("mc_tv.txt", "r");
        if (fd == 0) begin
            $display("ERROR: Could not open mc_tv.txt. Please extract from HM TComPrediction.cpp");
            $finish;
        end

        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        $display("=== STARTING MOTION COMPENSATION TESTS ===");

        while (!$feof(fd)) begin
            scan_ret = $fscanf(fd, "%d %d %d %d", f_cux, f_cuy, f_mvx, f_mvy);
            if (scan_ret != 4) break;
            
            // Read Luma Ext (11x11 = 121)
            for (int i=0; i<121; i++) begin scan_ret = $fscanf(fd, "%d", f_ref_y[i]); end
            // Read Cb Ext (5x5 = 25)
            for (int i=0; i<25; i++)  begin scan_ret = $fscanf(fd, "%d", f_ref_cb[i]); end
            // Read Cr Ext (5x5 = 25)
            for (int i=0; i<25; i++)  begin scan_ret = $fscanf(fd, "%d", f_ref_cr[i]); end
            
            // Read Expected Luma Pred (4x4 = 16)
            for (int i=0; i<16; i++)  begin scan_ret = $fscanf(fd, "%d", f_exp_y[i]); end
            // Read Expected Cb Pred (2x2 = 4)
            for (int i=0; i<4; i++)   begin scan_ret = $fscanf(fd, "%d", f_exp_cb[i]); end
            // Read Expected Cr Pred (2x2 = 4)
            for (int i=0; i<4; i++)   begin scan_ret = $fscanf(fd, "%d", f_exp_cr[i]); end

            // Pack 1D test vectors into flat buses for memory
            for (int i=0; i<121; i++) mem_y_ext[i*`PIXEL_WIDTH +: `PIXEL_WIDTH]  = f_ref_y[i];
            for (int i=0; i<25; i++)  mem_cb_ext[i*`PIXEL_WIDTH +: `PIXEL_WIDTH] = f_ref_cb[i];
            for (int i=0; i<25; i++)  mem_cr_ext[i*`PIXEL_WIDTH +: `PIXEL_WIDTH] = f_ref_cr[i];

            // Wait until DUT is ready to accept a new command
            while (!mc_ready) @(posedge clk);

            // Fire MC Start
            mc_start <= 1;
            mc_cu_x  <= f_cux;
            mc_cu_y  <= f_cuy;
            mc_mv_x  <= f_mvx;
            mc_mv_y  <= f_mvy;
            
            @(posedge clk);
            mc_start <= 0;

            // Wait for MC processing to finish
            while (!mc_done) @(posedge clk);

            // Check Results
            total_tested++;
            
            // Check Luma
            for (int i=0; i<16; i++) begin
                val = pred_y_flat[i*`PIXEL_WIDTH +: `PIXEL_WIDTH];
                if (val !== f_exp_y[i]) begin
                    $display("ERROR [Luma] Test %0d (x:%0d, y:%0d | mv:%0d,%0d) | Index %0d | Expected: %0d, Got: %0d", 
                             total_tested, f_cux, f_cuy, f_mvx, f_mvy, i, f_exp_y[i], val);
                    total_errors++;
                end
            end

            // Check Cb
            for (int i=0; i<4; i++) begin
                val = pred_cb_flat[i*`PIXEL_WIDTH +: `PIXEL_WIDTH];
                if (val !== f_exp_cb[i]) begin
                    $display("ERROR [Cb] Test %0d (x:%0d, y:%0d) | Index %0d | Expected: %0d, Got: %0d", 
                             total_tested, f_cux, f_cuy, i, f_exp_cb[i], val);
                    total_errors++;
                end
            end

            // Check Cr
            for (int i=0; i<4; i++) begin
                val = pred_cr_flat[i*`PIXEL_WIDTH +: `PIXEL_WIDTH];
                if (val !== f_exp_cr[i]) begin
                    $display("ERROR [Cr] Test %0d (x:%0d, y:%0d) | Index %0d | Expected: %0d, Got: %0d", 
                             total_tested, f_cux, f_cuy, i, f_exp_cr[i], val);
                    total_errors++;
                end
            end

        end
        
        $display("============================================");
        if (total_errors == 0) 
            $display("=== ALL %0d TESTS PASSED SUCCESSFULLY! ===", total_tested);
        else                   
            $display("=== TESTS FAILED: %0d Errors ===", total_errors);
        $display("============================================");
        
        $fclose(fd);
        $finish;
    end
endmodule