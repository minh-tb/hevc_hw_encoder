//=============================================================================
// tb_input_buffer.sv
// Testbench for YUV 4:2:0 Frame Input Buffer
//=============================================================================

`timescale 1ns/1ps
`define PIXEL_WIDTH 10

module tb_input_buffer;

    // -------------------------------------------------------------------------
    // Parameters (Scale down from 4K to 32x32 for fast simulation)
    // -------------------------------------------------------------------------
    parameter FRAME_WIDTH  = 3840;
    parameter FRAME_HEIGHT = 2160;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;

    // Write port
    logic                     wr_valid;
    logic                     wr_ready;
    logic [`PIXEL_WIDTH-1:0]  wr_data;
    logic [11:0]              wr_x, wr_y;
    logic [1:0]               wr_comp;
    logic [9:0]               wr_poc;
    logic                     wr_frame_last;

    // Read port
    logic                     rd_req_valid;
    logic                     rd_req_ready;
    logic [11:0]              rd_x, rd_y;
    logic [6:0]               rd_blk_w, rd_blk_h;
    logic [1:0]               rd_comp;
    logic                     rd_resp_valid;
    logic                     rd_resp_ready;
    logic [`PIXEL_WIDTH-1:0]  rd_resp_data;
    logic                     rd_resp_last;

    // AXI4 Interface
    logic         axi_awvalid, axi_awready;
    logic [32:0]  axi_awaddr;
    logic [7:0]   axi_awlen;
    logic [2:0]   axi_awsize;
    logic [1:0]   axi_awburst;
    logic         axi_wvalid, axi_wready;
    logic [31:0]  axi_wdata;
    logic [3:0]   axi_wstrb;
    logic         axi_wlast;
    logic         axi_bvalid, axi_bready;
    
    logic         axi_arvalid, axi_arready;
    logic [32:0]  axi_araddr;
    logic [7:0]   axi_arlen;
    logic [2:0]   axi_arsize;
    logic [1:0]   axi_arburst;
    logic         axi_rvalid, axi_rready;
    logic [31:0]  axi_rdata;
    logic         axi_rlast;

    // Frame Status
    logic         frame_ready;
    logic [9:0]   buffered_poc;
    logic         frame_consumed;

    // -------------------------------------------------------------------------
    // DUT Instantiation
    // -------------------------------------------------------------------------
    input_buffer #(
        .FRAME_WIDTH(FRAME_WIDTH),
        .FRAME_HEIGHT(FRAME_HEIGHT)
    ) dut (
        .* // Automatically connects all matching signals above
    );

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // -------------------------------------------------------------------------
    // AXI4 DRAM Behavioral Model (Associative Array for large memory)
    // -------------------------------------------------------------------------
    logic [31:0] dram [bit [30:0]];
    logic [32:0] mem_awaddr;
    logic [32:0] mem_araddr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_awready <= 1'b1;
            axi_wready  <= 1'b1;
            axi_arready <= 1'b1;
            axi_bvalid  <= 1'b0;
            axi_rvalid  <= 1'b0;
            dram.delete(); // Clear memory on reset
        end else begin
            // AXI Write Channel
            if (axi_awvalid && axi_awready) mem_awaddr <= axi_awaddr;
            
            if (axi_wvalid && axi_wready) begin
                if (axi_wstrb == 4'b1111) begin
                    dram[mem_awaddr[32:2]] = axi_wdata;
                end
                axi_bvalid <= 1'b1;
            end else if (axi_bvalid && axi_bready) begin
                axi_bvalid <= 1'b0;
            end

            // AXI Read Channel
            if (axi_arvalid && axi_arready) begin
                axi_rvalid <= 1'b1;
                if (dram.exists(axi_araddr[32:2])) begin
                    axi_rdata <= dram[axi_araddr[32:2]];
                end else begin
                    axi_rdata <= 32'h0000_0000;
                end
                axi_rlast  <= 1'b1; // Since axi_arlen is always 0 (single beat)
            end else if (axi_rvalid && axi_rready) begin
                axi_rvalid <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Test Sequence Tasks
    // -------------------------------------------------------------------------
    int errors = 0;

    // Push a single pixel into the buffer
    task write_pixel(int x, int y, int c, int poc, bit is_last);
        #1;
        wr_valid      = 1'b1;
        // Pack x and y into the 10-bit pixel for validation during readout
        wr_data       = (x & 5'h1F) | ((y & 5'h1F) << 5); 
        wr_x          = x;
        wr_y          = y;
        wr_comp       = c;
        wr_poc        = poc;
        wr_frame_last = is_last;
        wait (wr_valid && wr_ready);
        @(posedge clk);
        #1;
        wr_valid      = 1'b0;
    endtask

    // Push a full 32x32 YUV frame
    task write_frame(int poc);
        bit is_last;
        // Y Plane
        for (int py = 0; py < FRAME_HEIGHT; py++)
            for (int px = 0; px < FRAME_WIDTH; px++)
                write_pixel(px, py, 0, poc, 0);
        // Cb Plane
        for (int py = 0; py < FRAME_HEIGHT/2; py++)
            for (int px = 0; px < FRAME_WIDTH/2; px++)
                write_pixel(px, py, 1, poc, 0);
        // Cr Plane
        for (int py = 0; py < FRAME_HEIGHT/2; py++)
            for (int px = 0; px < FRAME_WIDTH/2; px++) begin
                is_last = (py == (FRAME_HEIGHT/2 - 1) && px == (FRAME_WIDTH/2 - 1));
                write_pixel(px, py, 2, poc, is_last);
            end
    endtask

    // Request and read a block of pixels, verifying their contents
    task read_and_verify_block(int x, int y, int w, int h, int c);
        #1;
        rd_req_valid = 1'b1;
        rd_x = x; rd_y = y;
        rd_blk_w = w; rd_blk_h = h; rd_comp = c;
        wait(rd_req_valid && rd_req_ready);
        @(posedge clk);
        #1;
        rd_req_valid = 1'b0;
        
        for (int i = 0; i < w * h; i++) begin
            automatic int exp_y = y + (i / w);
            automatic int exp_x = x + (i % w);
            automatic int exp_data = (exp_x & 5'h1F) | ((exp_y & 5'h1F) << 5);
            automatic int got_data;

            #1;
            rd_resp_ready = 1'b1;
            wait(rd_resp_valid && rd_resp_ready);
            got_data = rd_resp_data;
            @(posedge clk);
            
            // Verify that the data matches what we wrote: `(x & 5'h1F) | ((y & 5'h1F) << 5)`
            if (got_data !== exp_data) begin
                $display("ERROR: Data mismatch at Block(%0d,%0d) Offset(%0d). Exp: %08x, Got: %08x", x, y, i, exp_data, got_data);
                errors++;
            end
            #1;
            rd_resp_ready = 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Main Test Execution
    // -------------------------------------------------------------------------
    initial begin
        // Reset
        rst_n = 0; wr_valid = 0; rd_req_valid = 0; rd_resp_ready = 0; frame_consumed = 0;
        #20 rst_n = 1;
        
        $display("=== Starting input_buffer Testbench ===");
        $display("--- Writing Frame 0 (POC=10) ---");
        write_frame(10);
        wait(frame_ready);
        $display("--- Frame 0 Ready. Testing Block Reads ---");
        read_and_verify_block(0, 0, 8, 8, 0);   // Read 8x8 Luma
        read_and_verify_block(8, 8, 8, 8, 0);   // Read 8x8 Luma
        read_and_verify_block(0, 0, 4, 4, 1);   // Read 4x4 Cb

        if (errors == 0) $display("=== [PASS] All input_buffer tests passed! ===");
        else             $display("=== [FAIL] %0d errors found ===", errors);
        $finish;
    end
endmodule