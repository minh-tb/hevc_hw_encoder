//=============================================================================
// tb_ctu_raster_scan.sv
// Testbench for CTU Address Generator (Raster Scan)
//
// Verifies:
//   1. Full 4K (3840x2160) frame generation sequence without dropping CTUs.
//   2. Correct 2D coordinate calculation (X, Y) and 1D address mapping.
//   3. Boundary flags: is_first_in_row, is_last_in_row, is_last_ctu.
//   4. Robustness against pipeline stalls (randomizing ctu_ready).
//=============================================================================

`timescale 1ns/1ps

module tb_ctu_raster_scan;

    // Configuration: 4K UHD dimensions
    localparam FRAME_WIDTH  = 3840; 
    localparam FRAME_HEIGHT = 2160;
    localparam CTU_SIZE     = 64;
    
    // Expected parameters for self-checking
    localparam W_CTUS       = (FRAME_WIDTH + CTU_SIZE - 1) / CTU_SIZE;
    localparam H_CTUS       = (FRAME_HEIGHT + CTU_SIZE - 1) / CTU_SIZE;
    localparam TOTAL_CTUS   = W_CTUS * H_CTUS;

    logic clk;
    logic rst_n;
    
    logic frame_start;
    logic [9:0] frame_poc;
    logic [1:0] frame_slice_type;

    logic ctu_valid;
    logic ctu_ready;

    logic [15:0] ctu_addr;
    logic [9:0]  ctu_x;
    logic [9:0]  ctu_y;
    logic [13:0] frame_width_px;
    logic [13:0] frame_height_px;
    logic [9:0]  poc;
    logic [1:0]  slice_type;
    logic [5:0]  qp;

    logic is_first_in_row;
    logic is_last_in_row;
    logic is_last_ctu;

    logic frame_active;
    logic frame_done;

    int total_errors = 0;
    int ctus_received = 0;

    //=========================================================================
    // DUT Instantiation
    //=========================================================================
    ctu_raster_scan #(
        .FRAME_WIDTH(FRAME_WIDTH),
        .FRAME_HEIGHT(FRAME_HEIGHT)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .frame_start(frame_start), .frame_poc(frame_poc), .frame_slice_type(frame_slice_type),
        .ctu_valid(ctu_valid), .ctu_ready(ctu_ready),
        .ctu_addr(ctu_addr), .ctu_x(ctu_x), .ctu_y(ctu_y),
        .frame_width_px(frame_width_px), .frame_height_px(frame_height_px),
        .poc(poc), .slice_type(slice_type), .qp(qp),
        .is_first_in_row(is_first_in_row), .is_last_in_row(is_last_in_row), .is_last_ctu(is_last_ctu),
        .frame_active(frame_active), .frame_done(frame_done)
    );

    initial begin
        clk = 0;
        forever #4 clk = ~clk; // 125 MHz
    end

    //=========================================================================
    // Scoreboard / Checker
    //=========================================================================
    always @(posedge clk) begin
        if (ctu_valid && ctu_ready && frame_active) begin
            int exp_x;
            int exp_y;
            bit exp_first;
            bit exp_last_row;
            bit exp_last_ctu;
            
            exp_x        = ctus_received % W_CTUS;
            exp_y        = ctus_received / W_CTUS;
            exp_first    = (exp_x == 0);
            exp_last_row = (exp_x == W_CTUS - 1);
            exp_last_ctu = (ctus_received == TOTAL_CTUS - 1);

            if (ctu_x !== exp_x || ctu_y !== exp_y || ctu_addr !== ctus_received ||
                is_first_in_row !== exp_first || is_last_in_row !== exp_last_row ||
                is_last_ctu !== exp_last_ctu) begin
                
                $display("ERROR at CTU %0d: Expected (%0d,%0d) flags(f:%0d,lr:%0d,lc:%0d), got (%0d,%0d) flags(f:%0d,lr:%0d,lc:%0d)",
                         ctus_received, exp_x, exp_y, exp_first, exp_last_row, exp_last_ctu,
                         ctu_x, ctu_y, is_first_in_row, is_last_in_row, is_last_ctu);
                total_errors++;
            end
            ctus_received++;
        end
    end

    //=========================================================================
    // Test Sequence
    //=========================================================================
    initial begin
        rst_n = 0; frame_start = 0; frame_poc = 0; frame_slice_type = 0; ctu_ready = 0;
        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        $display("================================================================");
        $display("Starting 4K Frame Scan Test (W_CTUS=%0d, H_CTUS=%0d, TOTAL=%0d)", W_CTUS, H_CTUS, TOTAL_CTUS);
        $display("================================================================");
        
        @(negedge clk);
        frame_start      <= 1'b1;
        frame_poc        <= 10'd5;
        frame_slice_type <= 2'b01; // SLICE_P
        @(negedge clk);
        frame_start      <= 1'b0;

        // Randomly assert ctu_ready to heavily test pipeline stall back-pressure
        while (!frame_done) begin
            @(negedge clk);
            ctu_ready <= ($urandom() % 100 < 80); // 80% ready probability
        end
        
        // Wait a few cycles to ensure the module cleanly transitions to IDLE
        ctu_ready <= 1'b0;
        repeat(10) @(posedge clk);

        if (total_errors == 0 && ctus_received == TOTAL_CTUS)
            $display("=== TEST PASSED! All %0d CTUs cleanly scanned & flagged. ===", ctus_received);
        else
            $display("=== TEST FAILED! Errors: %0d, CTUs received: %0d/%0d ===", total_errors, ctus_received, TOTAL_CTUS);
        
        $finish;
    end
endmodule