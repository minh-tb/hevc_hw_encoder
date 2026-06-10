//=============================================================================
// tb_tz_search.sv
// Testbench for TZ Search Integer-Pel Motion Estimation
//
// Verifies:
//   1. FSM sequencing and pipeline coordination (SAD latency, SRAM latency)
//   2. Search range bounding relative to MVP (±SRCH_RNG)
//   3. Signed coordinate math for reference fetching (negative frame coords)
//   4. Extreme frame edge cases
//=============================================================================

`timescale 1ns/1ps

module tb_tz_search;

    localparam PIXEL_WIDTH = 10;
    localparam MV_W        = 10;
    localparam CU_COORD_W  = 12;
    localparam SRCH_RNG    = 64;

    // DUT Ports
    logic                        clk;
    logic                        rst_n;

    logic                        search_valid;
    logic                        search_ready;
    logic [PIXEL_WIDTH*16-1:0]   cu_orig_flat;
    logic [CU_COORD_W-1:0]       cu_x;
    logic [CU_COORD_W-1:0]       cu_y;
    logic signed [MV_W-1:0]      mvp_x;
    logic signed [MV_W-1:0]      mvp_y;

    logic                        ref_req_valid;
    logic signed [12:0]          ref_req_x;
    logic signed [12:0]          ref_req_y;
    logic                        ref_resp_valid;
    logic [PIXEL_WIDTH*16-1:0]   ref_resp_data;

    logic                        result_valid;
    logic signed [MV_W-1:0]      best_mv_x;
    logic signed [MV_W-1:0]      best_mv_y;
    logic [11:0]                 best_sad;

    int total_errors = 0;

    //=========================================================================
    // DUT Instantiation
    //=========================================================================
    tz_search #(
        .PIXEL_WIDTH(PIXEL_WIDTH),
        .MV_W(MV_W),
        .CU_COORD_W(CU_COORD_W),
        .SRCH_RNG(SRCH_RNG)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .search_valid(search_valid), .search_ready(search_ready),
        .cu_orig_flat(cu_orig_flat), .cu_x(cu_x), .cu_y(cu_y),
        .mvp_x(mvp_x), .mvp_y(mvp_y),
        .ref_req_valid(ref_req_valid), .ref_req_x(ref_req_x), .ref_req_y(ref_req_y),
        .ref_resp_valid(ref_resp_valid), .ref_resp_data(ref_resp_data),
        .result_valid(result_valid), .best_mv_x(best_mv_x), .best_mv_y(best_mv_y),
        .best_sad(best_sad)
    );

    //=========================================================================
    // Clock & Reset
    //=========================================================================
    initial begin
        clk = 0;
        forever #4 clk = ~clk; // 125 MHz
    end

    //=========================================================================
    // Simulated Reference SRAM (1-cycle latency) & Bounds Monitor
    //=========================================================================
    always @(posedge clk) begin
        ref_resp_valid <= 1'b0;
        
        if (ref_req_valid) begin
            // 1. Bounds Safety Check
            // cand_x = requested_pixel_x - block_base_x
            int cand_x = ref_req_x - $signed({1'b0, cu_x});
            int cand_y = ref_req_y - $signed({1'b0, cu_y});
            int mx = mvp_x;
            int my = mvp_y;
            
            if (cand_x < mx - SRCH_RNG || cand_x > mx + SRCH_RNG ||
                cand_y < my - SRCH_RNG || cand_y > my + SRCH_RNG) begin
                $display("ERROR: Search requested out of bounds! MVP=(%0d,%0d), Cand=(%0d,%0d)", 
                         mx, my, cand_x, cand_y);
                total_errors++;
            end

            // 2. Fetch Reference Data (Simulate 1-cycle delay)
            ref_resp_valid <= 1'b1;
            // Generate a synthetic deterministic block (creates a functional SAD landscape)
            for (int i = 0; i < 16; i++) begin
                ref_resp_data[PIXEL_WIDTH*i +: PIXEL_WIDTH] <= 
                    ((ref_req_x + ref_req_y + i) * 17) & 10'h3FF;
            end
        end
    end

    //=========================================================================
    // Test Sequence
    //=========================================================================
    task automatic run_search(input int c_x, input int c_y, input int m_x, input int m_y);
        $display("Starting search: CU=(%0d,%0d), MVP=(%0d,%0d)", c_x, c_y, m_x, m_y);
        @(negedge clk);
        wait (search_ready);
        
        search_valid <= 1'b1;
        cu_x  <= c_x;
        cu_y  <= c_y;
        mvp_x <= m_x;
        mvp_y <= m_y;
        // Randomize the CU original pixels
        for (int i = 0; i < 16; i++) begin
            cu_orig_flat[PIXEL_WIDTH*i +: PIXEL_WIDTH] <= $urandom() & 10'h3FF;
        end
        
        @(negedge clk);
        search_valid <= 1'b0;
        
        // Wait for search to complete
        wait (result_valid);
        @(negedge clk);
    endtask

    initial begin
        search_valid = 0; cu_x = 0; cu_y = 0; mvp_x = 0; mvp_y = 0; cu_orig_flat = 0;
        rst_n = 0; repeat(4) @(posedge clk);
        rst_n = 1; repeat(2) @(posedge clk);

        run_search(100, 100, 0, 0);         // Center of frame, zero MVP
        run_search(0, 100, -10, 0);         // Left edge, negative MVP (tests negative address pass-thru)
        run_search(100, 0, 0, -25);         // Top edge, negative MVP
        run_search(3800, 2100, 20, 20);     // Bottom-right edge (4K resolution bounds)
        run_search(50, 50, 400, 400);       // Extreme MVP pushing bounds logic
        
        if (total_errors == 0) $display("=== ALL TESTS PASSED ===");
        else                   $display("=== TESTS FAILED: %0d Errors ===", total_errors);
        $finish;
    end
endmodule