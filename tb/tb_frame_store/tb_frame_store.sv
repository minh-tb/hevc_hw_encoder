//=============================================================================
// tb_frame_store.sv
// Testbench for Decoded Picture Buffer (DPB) / Frame Store
//=============================================================================

`timescale 1ns/1ps

module tb_frame_store;

    logic         clk;
    logic         rst_n;

    logic         wr_valid;
    logic         wr_ready;
    logic [9:0]   wr_pixel;
    logic [11:0]  wr_x;
    logic [11:0]  wr_y;
    logic [1:0]   wr_comp;
    logic [2:0]   wr_slot;
    logic         wr_last;

    logic         rd_req_valid;
    logic         rd_req_ready;
    logic [2:0]   rd_slot;
    logic signed [12:0] rd_x;
    logic signed [12:0] rd_y;
    logic [6:0]   rd_blk_w;
    logic [6:0]   rd_blk_h;
    logic [1:0]   rd_comp;

    logic         rd_resp_valid;
    logic         rd_resp_ready;
    logic [9:0]   rd_resp_pixel;
    logic         rd_resp_last;

    logic         alloc_valid;
    logic         alloc_ready;
    logic [9:0]   alloc_poc;
    logic [2:0]   alloc_slot;

    logic         free_valid;
    logic [2:0]   free_slot;

    logic [2:0]   ref_l0 [0:4];
    logic [2:0]   ref_l1 [0:4];
    logic [2:0]   ref_l0_count;
    logic [2:0]   ref_l1_count;

    logic         axi_awvalid, axi_awready;
    logic [32:0]  axi_awaddr;
    logic [7:0]   axi_awlen;
    logic [2:0]   axi_awsize;
    logic [1:0]   axi_awburst;

    logic         axi_wvalid, axi_wready;
    logic [255:0] axi_wdata;
    logic [31:0]  axi_wstrb;
    logic         axi_wlast;

    logic         axi_bvalid, axi_bready;

    logic         axi_arvalid, axi_arready;
    logic [32:0]  axi_araddr;
    logic [7:0]   axi_arlen;
    logic [2:0]   axi_arsize;
    logic [1:0]   axi_arburst;

    logic         axi_rvalid, axi_rready;
    logic [255:0] axi_rdata;
    logic         axi_rlast;

    int total_errors = 0;

    // DUT
    frame_store dut (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(wr_valid), .wr_ready(wr_ready), .wr_pixel(wr_pixel),
        .wr_x(wr_x), .wr_y(wr_y), .wr_comp(wr_comp), .wr_slot(wr_slot), .wr_last(wr_last),
        .rd_req_valid(rd_req_valid), .rd_req_ready(rd_req_ready), .rd_slot(rd_slot),
        .rd_x(rd_x), .rd_y(rd_y), .rd_blk_w(rd_blk_w), .rd_blk_h(rd_blk_h), .rd_comp(rd_comp),
        .rd_resp_valid(rd_resp_valid), .rd_resp_ready(rd_resp_ready),
        .rd_resp_pixel(rd_resp_pixel), .rd_resp_last(rd_resp_last),
        .alloc_valid(alloc_valid), .alloc_ready(alloc_ready), .alloc_poc(alloc_poc), .alloc_slot(alloc_slot),
        .free_valid(free_valid), .free_slot(free_slot),
        .ref_l0(ref_l0), .ref_l1(ref_l1), .ref_l0_count(ref_l0_count), .ref_l1_count(ref_l1_count),
        .axi_awvalid(axi_awvalid), .axi_awready(axi_awready), .axi_awaddr(axi_awaddr),
        .axi_awlen(axi_awlen), .axi_awsize(axi_awsize), .axi_awburst(axi_awburst),
        .axi_wvalid(axi_wvalid), .axi_wready(axi_wready), .axi_wdata(axi_wdata), .axi_wstrb(axi_wstrb), .axi_wlast(axi_wlast),
        .axi_bvalid(axi_bvalid), .axi_bready(axi_bready),
        .axi_arvalid(axi_arvalid), .axi_arready(axi_arready), .axi_araddr(axi_araddr),
        .axi_arlen(axi_arlen), .axi_arsize(axi_arsize), .axi_arburst(axi_arburst),
        .axi_rvalid(axi_rvalid), .axi_rready(axi_rready), .axi_rdata(axi_rdata), .axi_rlast(axi_rlast),
        .cache_valid(), .cache_pixel(), .cache_x(), .cache_y(), .cache_comp()
    );

    // Clock
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk) rd_resp_ready <= ($urandom % 100 < 80);

    //=========================================================================
    // AXI4 SLAVE MEMORY MODEL (Sparse Associative Array)
    //=========================================================================
    logic [255:0] ddr_mem [longint];

    always @(posedge clk) begin
        axi_awready <= 1'b0; axi_wready <= 1'b0; axi_bvalid <= 1'b0;
        if (axi_awvalid) begin
            longint current_addr;
            int burst_len;
            current_addr = axi_awaddr;
            burst_len = axi_awlen;
            axi_awready <= 1'b1;
            @(posedge clk);
            axi_awready <= 1'b0;
            for (int i = 0; i <= burst_len; i++) begin
                axi_wready <= 1'b1;
                do begin @(posedge clk); end while (!axi_wvalid);
                begin
                    logic [255:0] mem_word;
                    if (ddr_mem.exists({current_addr[32:5], 5'd0}))
                        mem_word = ddr_mem[{current_addr[32:5], 5'd0}];
                    else
                        mem_word = 256'd0;
                    for (int b = 0; b < 32; b++) begin
                        if (axi_wstrb[b]) mem_word[b*8 +: 8] = axi_wdata[b*8 +: 8];
                    end
                    ddr_mem[{current_addr[32:5], 5'd0}] = mem_word;
                end
                current_addr = current_addr + 32;
            end
            axi_wready <= 1'b0;
            axi_bvalid <= 1'b1;
            do begin @(posedge clk); end while (!axi_bready);
            axi_bvalid <= 1'b0;
        end
    end

    always @(posedge clk) begin
        axi_arready <= 1'b0; axi_rvalid <= 1'b0;
        if (axi_arvalid) begin
            longint current_addr;
            int burst_len;
            current_addr = axi_araddr;
            burst_len = axi_arlen;
            axi_arready <= 1'b1;
            @(posedge clk);
            axi_arready <= 1'b0;
            for (int i = 0; i <= burst_len; i++) begin
                axi_rvalid <= 1'b1;
                axi_rlast  <= (i == burst_len);
                if (ddr_mem.exists({current_addr[32:5], 5'd0}))
                    axi_rdata <= ddr_mem[{current_addr[32:5], 5'd0}];
                else
                    axi_rdata <= 'hDEADBEEF; // Uninitialized Read
                do begin @(posedge clk); end while (!axi_rready);
                current_addr = current_addr + 32;
            end
            axi_rvalid <= 1'b0;
            axi_rlast  <= 1'b0;
        end
    end

    //=========================================================================
    // Data Generation & Verification
    //=========================================================================
    function automatic logic [9:0] expected_pixel(int x, int y, int comp);
        // Emulate hardware boundary clamping for verification
        int max_x = (comp == 0) ? 3839 : 1919;
        int max_y = (comp == 0) ? 2159 : 1079;
        int clamp_x = (x < 0) ? 0 : (x > max_x) ? max_x : x;
        int clamp_y = (y < 0) ? 0 : (y > max_y) ? max_y : y;
        return ((clamp_x * 13) ^ (clamp_y * 7) ^ (comp * 111)) & 10'h3FF;
    endfunction

    task automatic write_pattern_block(input int start_x, input int start_y, input int w, input int h, input int comp, input int slot);
        // Note: write sizes must be a multiple of 256 pixels to cleanly flush the AXI burst!
        for (int y = 0; y < h; y++) begin
            for (int x = 0; x < w; x++) begin
                wr_valid <= 1'b1;
                wr_x <= start_x + x;
                wr_y <= start_y + y;
                wr_comp <= comp;
                wr_slot <= slot;
                wr_pixel <= expected_pixel(start_x + x, start_y + y, comp);
                wr_last <= (x == w-1 && y == h-1); 
                do begin @(posedge clk); end while (!wr_ready);
            end
        end
        wr_valid <= 1'b0;
        // Wait for AXI pipeline to fully flush the write to DRAM
        repeat (30) @(posedge clk);
    endtask

    task automatic read_and_verify_block(input int start_x, input int start_y, input int w, input int h, input int comp, input int slot);
        rd_req_valid <= 1'b1;
        rd_x <= start_x;
        rd_y <= start_y;
        rd_blk_w <= w;
        rd_blk_h <= h;
        rd_comp <= comp;
        rd_slot <= slot;
        @(posedge clk);
        while (!rd_req_ready) @(posedge clk);
        rd_req_valid <= 1'b0;
        
        for (int y = 0; y < h; y++) begin
            for (int x = 0; x < w; x++) begin
                int expected = expected_pixel(start_x + x, start_y + y, comp);
                do begin @(posedge clk); end while (!rd_resp_valid || !rd_resp_ready);
                
                if (rd_resp_pixel !== expected) begin
                    $display("ERROR [Read] Mismatch at (%0d,%0d) comp %0d. Expected %0x, got %0x", 
                             start_x+x, start_y+y, comp, expected, rd_resp_pixel);
                    total_errors++;
                end
            end
        end
    endtask

    initial begin
        wr_valid = 0; wr_pixel = 0; wr_x = 0; wr_y = 0; wr_comp = 0; wr_slot = 0; wr_last = 0;
        rd_req_valid = 0; rd_slot = 0; rd_x = 0; rd_y = 0; rd_blk_w = 0; rd_blk_h = 0; rd_comp = 0;
        alloc_valid = 0; alloc_poc = 0; free_valid = 0; free_slot = 0;
        rst_n = 0; @(negedge clk); rst_n = 1; @(negedge clk);

        $display("==================================================");
        $display(" Starting frame_store Verification");
        $display("==================================================");

        // Allocate Slot
        alloc_valid <= 1; alloc_poc <= 10'd42; @(posedge clk); alloc_valid <= 0;

        $display("Testing Luma Write/Read...");
        write_pattern_block(128, 128, 16, 16, 0, 0); // Luma, 16x16 = 256px
        read_and_verify_block(128, 128, 16, 16, 0, 0);

        $display("Testing Chroma Write/Read...");
        write_pattern_block(64, 64, 16, 16, 1, 0);   // Cb, 16x16 = 256px
        read_and_verify_block(64, 64, 16, 16, 1, 0);

        $display("Testing Large Coordinates (Y > 256) to verify 33-bit multiplier fix...");
        write_pattern_block(2000, 1000, 16, 16, 0, 0); // Luma at X=2000, Y=1000
        read_and_verify_block(2000, 1000, 16, 16, 0, 0);

        $display("Testing Boundary Padding (Out of bounds read)...");
        // Write the top-left corner first so there is valid data in memory to read!
        write_pattern_block(0, 0, 16, 16, 0, 0);
        // Read overlapping the top-left boundary (x=-4, y=-4)
        read_and_verify_block(-4, -4, 8, 8, 0, 0);

        $display("==================================================");
        if (total_errors == 0) $display(" === ALL TESTS PASSED ===");
        else                   $display(" === TESTS FAILED: %0d Errors ===", total_errors);
        $display("==================================================\n");
        $finish;
    end
endmodule
