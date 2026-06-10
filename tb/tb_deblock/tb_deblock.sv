//=============================================================================
// tb_deblock.sv
// Self-checking unit testbench for Deblocking Top Orchestrator
//=============================================================================

`timescale 1ns/1ps
`include "parameter_pkg.vh"

// Fallbacks just in case parameter_pkg.vh is minimal
`ifndef PIXEL_WIDTH
`define PIXEL_WIDTH 10
`endif

module tb_deblock;

    // DUT Ports
    logic         clk;
    logic         rst_n;

    // CTU control
    logic         ctu_valid;
    logic         ctu_ready;
    logic [15:0]  ctu_addr;
    logic [9:0]   ctu_x;
    logic [9:0]   ctu_y;
    logic [11:0]  frame_width_px;
    logic [11:0]  frame_height_px;

    // CU info shadow map
    logic         cu_map_pred_mode  [0:15][0:15];
    logic         cu_map_cbf_luma   [0:15][0:15];
    logic         cu_map_cbf_chroma [0:15][0:15];
    logic [2:0]   cu_map_ref_l0     [0:15][0:15];
    logic [2:0]   cu_map_ref_l1     [0:15][0:15];
    logic         cu_map_bi_pred    [0:15][0:15];
    logic signed [15:0] cu_map_mvx_l0 [0:15][0:15];
    logic signed [15:0] cu_map_mvy_l0 [0:15][0:15];
    logic signed [15:0] cu_map_mvx_l1 [0:15][0:15];
    logic signed [15:0] cu_map_mvy_l1 [0:15][0:15];
    logic [5:0]   cu_map_qp         [0:15][0:15];

    // Pixel Read I/F
    logic         pix_rd_valid;
    logic         pix_rd_ready;
    logic [5:0]   pix_rd_x;
    logic [5:0]   pix_rd_y;
    logic [1:0]   pix_rd_comp;

    logic         pix_resp_valid;
    logic         pix_resp_ready;
    logic [`PIXEL_WIDTH-1:0] pix_resp_data;

    // Pixel Write I/F
    logic         pix_wr_valid;
    logic         pix_wr_ready;
    logic [5:0]   pix_wr_x;
    logic [5:0]   pix_wr_y;
    logic [1:0]   pix_wr_comp;
    logic [`PIXEL_WIDTH-1:0] pix_wr_data;

    logic         ctu_done;

    // Instantiation
    deblock_top dut (.*);

    // Clock Generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    //-------------------------------------------------------------------------
    // Mock CTU Pixel Memory Model
    // 0: Luma (64x64), 1: Cb (32x32), 2: Cr (32x32)
    //-------------------------------------------------------------------------
    logic [`PIXEL_WIDTH-1:0] ctu_mem        [0:2][0:63][0:63];
    logic [`PIXEL_WIDTH-1:0] ctu_mem_golden [0:2][0:63][0:63];

    // Read Request Queue
    typedef struct {
        logic [5:0] x;
        logic [5:0] y;
        logic [1:0] comp;
    } rd_req_t;
    rd_req_t rd_queue[$];

    // Mock Read Responder (Handles Backpressure and Latency)
    always @(posedge clk) begin
        if (!rst_n) begin
            pix_rd_ready   <= 1'b0;
            pix_resp_valid <= 1'b0;
            pix_resp_data  <= 0;
            rd_queue.delete();
        end else begin
            // Randomize ready to stress FSM
            pix_rd_ready <= ($urandom_range(0, 100) > 20); // 80% ready rate
            
            if (pix_rd_valid && pix_rd_ready) begin
                rd_req_t req;
                req.x    = pix_rd_x;
                req.y    = pix_rd_y;
                req.comp = pix_rd_comp;
                rd_queue.push_back(req);
            end
            
            // Provide response 
            if (rd_queue.size() > 0 && (!pix_resp_valid || pix_resp_ready) && ($urandom_range(0, 100) > 10)) begin
                rd_req_t r;
                r = rd_queue.pop_front();
                pix_resp_valid <= 1'b1;
                pix_resp_data  <= ctu_mem[r.comp][r.y][r.x];
            end else if (pix_resp_valid && pix_resp_ready) begin
                pix_resp_valid <= 1'b0;
            end
        end
    end

    // Mock Write Responder
    always @(posedge clk) begin
        if (!rst_n) begin
            pix_wr_ready <= 1'b0;
        end else begin
            pix_wr_ready <= ($urandom_range(0, 100) > 30); // 70% ready rate
            
            if (pix_wr_valid && pix_wr_ready) begin
                ctu_mem[pix_wr_comp][pix_wr_y][pix_wr_x] <= pix_wr_data;
            end
        end
    end

    //-------------------------------------------------------------------------
    // File I/O Tasks
    //-------------------------------------------------------------------------
    task automatic load_ctu_from_file(string filename);
        int fd, r;
        fd = $fopen(filename, "r");
        if (!fd) begin
            $display("WARNING: Could not open %s. Using random data.", filename);
            generate_random_ctu();
            return;
        end
        
        $display("Reading inputs from %s...", filename);
        // 1. Read 16x16 CU Map
        for (int r_idx = 0; r_idx < 16; r_idx++) begin
            for (int c_idx = 0; c_idx < 16; c_idx++) begin
                int mode, cbfl, cbfc, refl0, refl1, bip, mvl0x, mvl0y, mvl1x, mvl1y, qp;
                r = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d\n", 
                            mode, cbfl, cbfc, refl0, refl1, bip, mvl0x, mvl0y, mvl1x, mvl1y, qp);
                cu_map_pred_mode[r_idx][c_idx]  = mode;
                cu_map_cbf_luma[r_idx][c_idx]   = cbfl;
                cu_map_cbf_chroma[r_idx][c_idx] = cbfc;
                cu_map_ref_l0[r_idx][c_idx]     = refl0;
                cu_map_ref_l1[r_idx][c_idx]     = refl1;
                cu_map_bi_pred[r_idx][c_idx]    = bip;
                cu_map_mvx_l0[r_idx][c_idx]     = mvl0x;
                cu_map_mvy_l0[r_idx][c_idx]     = mvl0y;
                cu_map_mvx_l1[r_idx][c_idx]     = mvl1x;
                cu_map_mvy_l1[r_idx][c_idx]     = mvl1y;
                cu_map_qp[r_idx][c_idx]         = qp;
            end
        end
        
        // 2. Read Luma Pixels (64x64)
        for (int y = 0; y < 64; y++) begin
            for (int x = 0; x < 64; x++) begin
                int p; r = $fscanf(fd, "%d", p);
                ctu_mem[0][y][x] = p;
            end
        end
        
        // 3. Read Cb Pixels (32x32)
        for (int y = 0; y < 32; y++) begin
            for (int x = 0; x < 32; x++) begin
                int p; r = $fscanf(fd, "%d", p);
                ctu_mem[1][y][x] = p;
            end
        end
        
        // 4. Read Cr Pixels (32x32)
        for (int y = 0; y < 32; y++) begin
            for (int x = 0; x < 32; x++) begin
                int p; r = $fscanf(fd, "%d", p);
                ctu_mem[2][y][x] = p;
            end
        end
        $fclose(fd);
    endtask

    task automatic check_ctu_to_file(string filename);
        int fd, r, mismatch_cnt = 0, match_cnt = 0;
        fd = $fopen(filename, "r");
        if (!fd) begin
            $display("WARNING: Could not open golden file %s. Skipping check.", filename);
            return;
        end
        
        $display("Comparing outputs against %s...", filename);
        
        // Read & Check Luma
        for (int y = 0; y < 64; y++) begin
            for (int x = 0; x < 64; x++) begin
                int exp_p; r = $fscanf(fd, "%d", exp_p);
                if (ctu_mem[0][y][x] !== exp_p) begin
                    mismatch_cnt++;
                    $display("Mismatch Luma (x=%0d,y=%0d): Exp=%0d, Got=%0d", x, y, exp_p, ctu_mem[0][y][x]);
                end else begin
                    match_cnt++;
                    $display("Match Luma (x=%0d,y=%0d): Val=%0d", x, y, exp_p);
                end
            end
        end
        
        // Read & Check Chroma
        for (int c = 1; c <= 2; c++) begin
            for (int y = 0; y < 32; y++) begin
                for (int x = 0; x < 32; x++) begin
                    int exp_p; r = $fscanf(fd, "%d", exp_p);
                    if (ctu_mem[c][y][x] !== exp_p) begin
                        mismatch_cnt++;
                        $display("Mismatch Chroma%0d (x=%0d,y=%0d): Exp=%0d, Got=%0d", c, x, y, exp_p, ctu_mem[c][y][x]);
                    end else begin
                        match_cnt++;
                        $display("Match Chroma%0d (x=%0d,y=%0d): Val=%0d", c, x, y, exp_p);
                    end
                end
            end
        end
        
        $fclose(fd);
        if (mismatch_cnt == 0) $display("[PASS] Memory perfectly matches Golden HM Reference. (%0d matches)", match_cnt);
        else                   $display("[FAIL] Found %0d mismatches and %0d matches in output.", mismatch_cnt, match_cnt);
    endtask

    // Fallback Randomizer
    task automatic generate_random_ctu();
        for (int r_idx = 0; r_idx < 16; r_idx++) begin
            for (int c_idx = 0; c_idx < 16; c_idx++) begin
                cu_map_pred_mode[r_idx][c_idx]  = $urandom_range(0, 1);
                cu_map_cbf_luma[r_idx][c_idx]   = $urandom_range(0, 1);
                cu_map_cbf_chroma[r_idx][c_idx] = $urandom_range(0, 1);
                cu_map_ref_l0[r_idx][c_idx]     = $urandom_range(0, 4);
                cu_map_ref_l1[r_idx][c_idx]     = $urandom_range(0, 4);
                cu_map_bi_pred[r_idx][c_idx]    = $urandom_range(0, 1);
                cu_map_mvx_l0[r_idx][c_idx]     = $urandom_range(0, 100) - 50;
                cu_map_mvy_l0[r_idx][c_idx]     = $urandom_range(0, 100) - 50;
                cu_map_mvx_l1[r_idx][c_idx]     = 0;
                cu_map_mvy_l1[r_idx][c_idx]     = 0;
                cu_map_qp[r_idx][c_idx]         = $urandom_range(20, 40);
            end
        end
        for (int c = 0; c < 3; c++) begin
            int limit = (c == 0) ? 64 : 32;
            for (int y = 0; y < limit; y++) begin
                for (int x = 0; x < limit; x++) begin
                    ctu_mem[c][y][x] = $urandom_range(100, 900);
                end
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Main Test Sequence
    //-------------------------------------------------------------------------
    initial begin
        // Init
        rst_n = 0;
        ctu_valid = 0;
        ctu_addr = 0;
        ctu_x = 64; // arbitrary internal CTU (not frame boundary)
        ctu_y = 64;
        frame_width_px = 1920;
        frame_height_px = 1080;
        
        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        $display("=== Starting Deblock_Top Orchestrator Unit Test ===");

        // 1. Load inputs (Will fallback to random if file not present)
        load_ctu_from_file("deblock_in.dat");
        
        // 2. Trigger Deblocking FSM
        @(posedge clk);
        while (!ctu_ready) @(posedge clk);
        
        ctu_valid <= 1'b1;
        @(posedge clk);
        ctu_valid <= 1'b0;
        
        $display("Waiting for CTU to finish deblocking...");
        
        // 3. Wait for Done
        while (!ctu_done) @(posedge clk);
        $display("CTU Deblocking FSM Completed!");
        
        // 4. Check outputs
        check_ctu_to_file("deblock_out_golden.dat");
        
        $finish;
    end

endmodule