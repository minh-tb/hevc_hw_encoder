//=============================================================================
// tb_ref_frame_buffer.sv
// Testbench for Decoded Reference Frame Buffer
//=============================================================================

`timescale 1ns/1ps

module tb_ref_frame_buffer;

    // -------------------------------------------------------------------------
    // Parameters 
    // -------------------------------------------------------------------------
    parameter PIXEL_WIDTH  = 10;
    parameter BLK_SIZE     = 4;
    parameter BLK_EXT_Y    = 11;
    parameter BLK_EXT_C    = 5;
    
    // Scaled down dimensions for faster simulation
    parameter FRAME_W_Y    = 64; 
    parameter FRAME_H_Y    = 64;
    parameter FRAME_W_C    = 32;
    parameter FRAME_H_C    = 32;
    
    parameter AXI_DW       = 256;
    parameter AXI_AW       = 33;
    parameter PX_EXT_Y     = PIXEL_WIDTH * BLK_EXT_Y * BLK_EXT_Y;
    parameter PX_EXT_C     = PIXEL_WIDTH * BLK_EXT_C * BLK_EXT_C;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic                 clk;
    logic                 rst_n;

    logic                 ref_req_valid;
    logic                 ref_req_ready;
    logic [1:0]           ref_req_comp;
    logic [2:0]           ref_req_slot;
    logic [11:0]          ref_req_x;
    logic [11:0]          ref_req_y;

    logic                 ref_resp_valid;
    logic [PX_EXT_Y-1:0]  ref_resp_y_flat;
    logic [PX_EXT_C-1:0]  ref_resp_cb_flat;
    logic [PX_EXT_C-1:0]  ref_resp_cr_flat;

    logic                 axi_arvalid;
    logic                 axi_arready;
    logic [AXI_AW-1:0]    axi_araddr;
    logic [7:0]           axi_arlen;
    logic [2:0]           axi_arsize;
    logic [1:0]           axi_arburst;
    
    logic                 axi_rvalid;
    logic                 axi_rready;
    logic [AXI_DW-1:0]    axi_rdata;
    logic                 axi_rlast;

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    ref_frame_buffer #(
        .PIXEL_WIDTH(PIXEL_WIDTH),
        .BLK_SIZE(BLK_SIZE),
        .FRAME_W_Y(FRAME_W_Y),
        .FRAME_H_Y(FRAME_H_Y),
        .FRAME_W_C(FRAME_W_C),
        .FRAME_H_C(FRAME_H_C)
    ) dut (.*);

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // -------------------------------------------------------------------------
    // AXI Memory Model (Associative Array)
    // -------------------------------------------------------------------------
    logic [AXI_DW-1:0] dram [int];
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_arready <= 1'b1;
            axi_rvalid  <= 1'b0;
            axi_rdata   <= '0;
            axi_rlast   <= 1'b0;
        end else begin
            if (axi_arvalid && axi_arready) begin
                automatic int beat_addr = axi_araddr >> 5; // Address divided by 32 bytes (256 bits)
                axi_rvalid <= 1'b1;
                if (dram.exists(beat_addr)) axi_rdata <= dram[beat_addr];
                else                        axi_rdata <= '0;
                axi_rlast <= 1'b1;
            end else if (axi_rvalid && axi_rready) begin
                axi_rvalid <= 1'b0;
            end
        end
    end

    // Initialize DRAM with gradient patterns
    function automatic void init_dram();
        // Luma Frame (comp 0)
        for (int y = 0; y < FRAME_H_Y; y++) begin
            for (int x = 0; x < FRAME_W_Y; x += 16) begin
                logic [255:0] beat = '0;
                for (int p = 0; p < 16; p++) begin
                    logic [9:0] val = (y * FRAME_W_Y + x + p) & 10'h3FF;
                    if (p % 2 == 0) beat[(p/2)*32 +: 10] = val;
                    else            beat[(p/2)*32 + 16 +: 10] = val;
                end
                dram[(y * FRAME_W_Y * 2 + x * 2) >> 5] = beat;
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // Tasks
    // -------------------------------------------------------------------------
    task request_block(input logic [1:0] comp, input int x, input int y);
        #1;
        ref_req_valid = 1'b1;
        ref_req_comp  = comp;
        ref_req_slot  = 0;
        ref_req_x     = x[11:0];
        ref_req_y     = y[11:0];
        wait(ref_req_valid && ref_req_ready);
        @(posedge clk);
        #1;
        ref_req_valid = 1'b0;
        wait(ref_resp_valid);
    endtask

    // -------------------------------------------------------------------------
    // Main Test Sequence
    // -------------------------------------------------------------------------
    int errors = 0;

    initial begin
        rst_n = 0;
        ref_req_valid = 0;
        
        #20 rst_n = 1;
        init_dram();
        @(posedge clk);

        $display("=== Starting ref_frame_buffer Testbench ===");

        // Test 1: Luma fetch with negative coordinates to trigger edge clamping
        $display("--- Test 1: Luma fetch with negative coordinates (clamping) ---");
        request_block(0, -3, -3);
        
        begin
            logic [9:0] act, exp;
            for (int r = 0; r < BLK_EXT_Y; r++) begin
                for (int c = 0; c < BLK_EXT_Y; c++) begin
                    automatic int px = -3 + c;
                    automatic int py = -3 + r;
                    automatic int cx = px < 0 ? 0 : (px > FRAME_W_Y-1 ? FRAME_W_Y-1 : px);
                    automatic int cy = py < 0 ? 0 : (py > FRAME_H_Y-1 ? FRAME_H_Y-1 : py);
                    
                    exp = (cy * FRAME_W_Y + cx) & 10'h3FF;
                    act = ref_resp_y_flat[(r * BLK_EXT_Y + c) * 10 +: 10];
                    
                    if (act !== exp) begin
                        $display("ERROR: Luma Mismatch at local(%0d,%0d) frame(%0d,%0d). Exp: %0d, Got: %0d", c, r, px, py, exp, act);
                        errors++;
                    end
                end
            end
        end

        // Test 2: Luma fetch that spans across an AXI 32-byte boundary
        $display("--- Test 2: Luma fetch spanning AXI beat boundaries ---");
        request_block(0, 10, 10);
        
        begin
            logic [9:0] act, exp;
            for (int r = 0; r < BLK_EXT_Y; r++) begin
                for (int c = 0; c < BLK_EXT_Y; c++) begin
                    automatic int px = 10 + c;
                    automatic int py = 10 + r;
                    exp = (py * FRAME_W_Y + px) & 10'h3FF;
                    act = ref_resp_y_flat[(r * BLK_EXT_Y + c) * 10 +: 10];
                    if (act !== exp) begin
                        $display("ERROR: Luma Mismatch at frame(%0d,%0d). Exp: %0d, Got: %0d", px, py, exp, act);
                        errors++;
                    end
                end
            end
        end

        if (errors == 0) $display("=== [PASS] All ref_frame_buffer tests passed! ===");
        else             $display("=== [FAIL] %0d errors found ===", errors);
        $finish;
    end
endmodule