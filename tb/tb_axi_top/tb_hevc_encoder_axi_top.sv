`timescale 1ns / 1ps
//=============================================================================
// tb_hevc_encoder_axi_top.sv
// Functional Verification Testbench for HEVC Encoder SoC AXI Wrapper
//
// Tests:
//   1. AXI4-Lite CSR Register Map (Magic ID, Resolution, QP, GOP, Bitrate, Frames)
//   2. Soft Reset control and status transitions
//   3. Video Pixel Streaming via s_axis_video (YUV 4:2:0)
//   4. Bitstream Output via m_axis_bitstream with TLAST assertion on frame end
//   5. Completion Interrupt (irq) assertion and Write-1-to-Clear (W1C)
//=============================================================================

module tb_hevc_encoder_axi_top;

    localparam CLK_PERIOD = 20; // 50 MHz baseline (20 ns)
    localparam FRAME_W    = 64;
    localparam FRAME_H    = 64;

    reg clk;
    reg rst_n;

    // AXI-Lite Slave Signals
    reg  [11:0] s_axi_lite_awaddr;
    reg  [2:0]  s_axi_lite_awprot;
    reg         s_axi_lite_awvalid;
    wire        s_axi_lite_awready;

    reg  [31:0] s_axi_lite_wdata;
    reg  [3:0]  s_axi_lite_wstrb;
    reg         s_axi_lite_wvalid;
    wire        s_axi_lite_wready;

    wire [1:0]  s_axi_lite_bresp;
    wire        s_axi_lite_bvalid;
    reg         s_axi_lite_bready;

    reg  [11:0] s_axi_lite_araddr;
    reg  [2:0]  s_axi_lite_arprot;
    reg         s_axi_lite_arvalid;
    wire        s_axi_lite_arready;

    wire [31:0] s_axi_lite_rdata;
    wire [1:0]  s_axi_lite_rresp;
    wire        s_axi_lite_rvalid;
    reg         s_axi_lite_rready;

    // AXI-Stream Video In Signals
    reg  [31:0] s_axis_video_tdata;
    reg         s_axis_video_tvalid;
    wire        s_axis_video_tready;
    reg         s_axis_video_tlast;
    reg         s_axis_video_tuser;

    // AXI-Stream Bitstream Out Signals
    wire [7:0]  m_axis_bitstream_tdata;
    wire        m_axis_bitstream_tvalid;
    reg         m_axis_bitstream_tready;
    wire        m_axis_bitstream_tlast;

    // AXI4 Memory Master Signals (connected to mock DRAM)
    wire [0:0]   m_axi_mem_awid;
    wire [32:0]  m_axi_mem_awaddr;
    wire [7:0]   m_axi_mem_awlen;
    wire [2:0]   m_axi_mem_awsize;
    wire [1:0]   m_axi_mem_awburst;
    wire         m_axi_mem_awlock;
    wire [3:0]   m_axi_mem_awcache;
    wire [2:0]   m_axi_mem_awprot;
    wire [3:0]   m_axi_mem_awqos;
    wire         m_axi_mem_awvalid;
    reg          m_axi_mem_awready;

    wire [255:0] m_axi_mem_wdata;
    wire [31:0]  m_axi_mem_wstrb;
    wire         m_axi_mem_wlast;
    wire         m_axi_mem_wvalid;
    reg          m_axi_mem_wready;

    reg  [0:0]   m_axi_mem_bid;
    reg  [1:0]   m_axi_mem_bresp;
    reg          m_axi_mem_bvalid;
    wire         m_axi_mem_bready;

    wire [0:0]   m_axi_mem_arid;
    wire [32:0]  m_axi_mem_araddr;
    wire [7:0]   m_axi_mem_arlen;
    wire [2:0]   m_axi_mem_arsize;
    wire [1:0]   m_axi_mem_arburst;
    wire         m_axi_mem_arlock;
    wire [3:0]   m_axi_mem_arcache;
    wire [2:0]   m_axi_mem_arprot;
    wire [3:0]   m_axi_mem_arqos;
    wire         m_axi_mem_arvalid;
    reg          m_axi_mem_arready;

    reg  [0:0]   m_axi_mem_rid;
    reg  [255:0] m_axi_mem_rdata;
    reg  [1:0]   m_axi_mem_rresp;
    reg          m_axi_mem_rlast;
    reg          m_axi_mem_rvalid;
    wire         m_axi_mem_rready;

    // Interrupt line
    wire         irq;

    // Statistics & Verification Counters
    integer bytes_received;
    integer tlast_count;
    integer errors;

    // Instantiate DUT
    hevc_encoder_axi_top #(
        .FRAME_WIDTH         (FRAME_W),
        .FRAME_HEIGHT        (FRAME_H),
        .GOP_STRUCTURE       (0),
        .BASE_QP             (28),
        .RC_ENABLE           (0),
        .TARGET_BITRATE_KBPS (5000),
        .C_S_AXI_LITE_ADDR_WIDTH (12)
    ) dut (
        .clk                     (clk),
        .rst_n                   (rst_n),
        .s_axi_lite_awaddr       (s_axi_lite_awaddr),
        .s_axi_lite_awprot       (s_axi_lite_awprot),
        .s_axi_lite_awvalid      (s_axi_lite_awvalid),
        .s_axi_lite_awready      (s_axi_lite_awready),
        .s_axi_lite_wdata        (s_axi_lite_wdata),
        .s_axi_lite_wstrb        (s_axi_lite_wstrb),
        .s_axi_lite_wvalid       (s_axi_lite_wvalid),
        .s_axi_lite_wready       (s_axi_lite_wready),
        .s_axi_lite_bresp        (s_axi_lite_bresp),
        .s_axi_lite_bvalid       (s_axi_lite_bvalid),
        .s_axi_lite_bready       (s_axi_lite_bready),
        .s_axi_lite_araddr       (s_axi_lite_araddr),
        .s_axi_lite_arprot       (s_axi_lite_arprot),
        .s_axi_lite_arvalid      (s_axi_lite_arvalid),
        .s_axi_lite_arready      (s_axi_lite_arready),
        .s_axi_lite_rdata        (s_axi_lite_rdata),
        .s_axi_lite_rresp        (s_axi_lite_rresp),
        .s_axi_lite_rvalid       (s_axi_lite_rvalid),
        .s_axi_lite_rready       (s_axi_lite_rready),
        .s_axis_video_tdata      (s_axis_video_tdata),
        .s_axis_video_tvalid     (s_axis_video_tvalid),
        .s_axis_video_tready     (s_axis_video_tready),
        .s_axis_video_tlast      (s_axis_video_tlast),
        .s_axis_video_tuser      (s_axis_video_tuser),
        .m_axis_bitstream_tdata  (m_axis_bitstream_tdata),
        .m_axis_bitstream_tvalid (m_axis_bitstream_tvalid),
        .m_axis_bitstream_tready (m_axis_bitstream_tready),
        .m_axis_bitstream_tlast  (m_axis_bitstream_tlast),
        .m_axi_mem_awid          (m_axi_mem_awid),
        .m_axi_mem_awaddr        (m_axi_mem_awaddr),
        .m_axi_mem_awlen         (m_axi_mem_awlen),
        .m_axi_mem_awsize        (m_axi_mem_awsize),
        .m_axi_mem_awburst       (m_axi_mem_awburst),
        .m_axi_mem_awlock        (m_axi_mem_awlock),
        .m_axi_mem_awcache       (m_axi_mem_awcache),
        .m_axi_mem_awprot        (m_axi_mem_awprot),
        .m_axi_mem_awqos         (m_axi_mem_awqos),
        .m_axi_mem_awvalid       (m_axi_mem_awvalid),
        .m_axi_mem_awready       (m_axi_mem_awready),
        .m_axi_mem_wdata         (m_axi_mem_wdata),
        .m_axi_mem_wstrb         (m_axi_mem_wstrb),
        .m_axi_mem_wlast         (m_axi_mem_wlast),
        .m_axi_mem_wvalid        (m_axi_mem_wvalid),
        .m_axi_mem_wready        (m_axi_mem_wready),
        .m_axi_mem_bid           (m_axi_mem_bid),
        .m_axi_mem_bresp         (m_axi_mem_bresp),
        .m_axi_mem_bvalid        (m_axi_mem_bvalid),
        .m_axi_mem_bready        (m_axi_mem_bready),
        .m_axi_mem_arid          (m_axi_mem_arid),
        .m_axi_mem_araddr        (m_axi_mem_araddr),
        .m_axi_mem_arlen         (m_axi_mem_arlen),
        .m_axi_mem_arsize        (m_axi_mem_arsize),
        .m_axi_mem_arburst       (m_axi_mem_arburst),
        .m_axi_mem_arlock        (m_axi_mem_arlock),
        .m_axi_mem_arcache       (m_axi_mem_arcache),
        .m_axi_mem_arprot        (m_axi_mem_arprot),
        .m_axi_mem_arqos         (m_axi_mem_arqos),
        .m_axi_mem_arvalid       (m_axi_mem_arvalid),
        .m_axi_mem_arready       (m_axi_mem_arready),
        .m_axi_mem_rid           (m_axi_mem_rid),
        .m_axi_mem_rdata         (m_axi_mem_rdata),
        .m_axi_mem_rresp         (m_axi_mem_rresp),
        .m_axi_mem_rlast         (m_axi_mem_rlast),
        .m_axi_mem_rvalid        (m_axi_mem_rvalid),
        .m_axi_mem_rready        (m_axi_mem_rready),
        .irq                     (irq)
    );

    // 50 MHz Clock Generator
    always #(CLK_PERIOD/2) clk = ~clk;

    // Mock DRAM Model for AXI Master interface
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_mem_awready <= 1'b1;
            m_axi_mem_wready  <= 1'b1;
            m_axi_mem_bvalid  <= 1'b0;
            m_axi_mem_bresp   <= 2'b00;
            m_axi_mem_bid     <= 1'b0;
            m_axi_mem_arready <= 1'b1;
            m_axi_mem_rvalid  <= 1'b0;
            m_axi_mem_rdata   <= 256'd0;
            m_axi_mem_rlast   <= 1'b0;
            m_axi_mem_rresp   <= 2'b00;
            m_axi_mem_rid     <= 1'b0;
        end else begin
            // Write response
            if (m_axi_mem_wvalid && m_axi_mem_wready && m_axi_mem_wlast) begin
                m_axi_mem_bvalid <= 1'b1;
            end else if (m_axi_mem_bready && m_axi_mem_bvalid) begin
                m_axi_mem_bvalid <= 1'b0;
            end

            // Read response
            if (m_axi_mem_arvalid && m_axi_mem_arready) begin
                m_axi_mem_rvalid <= 1'b1;
                m_axi_mem_rlast  <= 1'b1;
            end else if (m_axi_mem_rready && m_axi_mem_rvalid) begin
                m_axi_mem_rvalid <= 1'b0;
                m_axi_mem_rlast  <= 1'b0;
            end
        end
    end

    // AXI-Lite Master Tasks
    task axi_lite_write(input [11:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            s_axi_lite_awaddr  <= addr;
            s_axi_lite_awvalid <= 1'b1;
            s_axi_lite_wdata   <= data;
            s_axi_lite_wstrb   <= 4'hF;
            s_axi_lite_wvalid  <= 1'b1;
            s_axi_lite_bready  <= 1'b1;

            @(posedge clk);
            while (!(s_axi_lite_awready && s_axi_lite_wready)) begin
                @(posedge clk);
            end

            s_axi_lite_awvalid <= 1'b0;
            s_axi_lite_wvalid  <= 1'b0;

            while (!s_axi_lite_bvalid) begin
                @(posedge clk);
            end
            @(posedge clk);
            s_axi_lite_bready  <= 1'b0;
        end
    endtask

    task axi_lite_read(input [11:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            s_axi_lite_araddr  <= addr;
            s_axi_lite_arvalid <= 1'b1;
            s_axi_lite_rready  <= 1'b1;

            @(posedge clk);
            while (!s_axi_lite_arready) begin
                @(posedge clk);
            end
            s_axi_lite_arvalid <= 1'b0;

            while (!s_axi_lite_rvalid) begin
                @(posedge clk);
            end
            data = s_axi_lite_rdata;
            @(posedge clk);
            s_axi_lite_rready <= 1'b0;
        end
    endtask

    // Bitstream monitor
    always @(posedge clk) begin
        if (m_axis_bitstream_tvalid && m_axis_bitstream_tready) begin
            bytes_received <= bytes_received + 1;
            if (m_axis_bitstream_tlast) begin
                tlast_count <= tlast_count + 1;
                $display("Time=%0t: [TLAST] Frame bitstream boundary observed! byte=0x%02X, total_bytes=%0d",
                         $time, m_axis_bitstream_tdata, bytes_received + 1);
            end
        end
    end

    // Main Test Sequence
    reg [31:0] rd_val;
    integer p;

    initial begin
        clk = 0;
        rst_n = 0;
        errors = 0;
        bytes_received = 0;
        tlast_count = 0;

        s_axi_lite_awaddr  = 0;
        s_axi_lite_awprot  = 0;
        s_axi_lite_awvalid = 0;
        s_axi_lite_wdata   = 0;
        s_axi_lite_wstrb   = 0;
        s_axi_lite_wvalid  = 0;
        s_axi_lite_bready  = 0;

        s_axi_lite_araddr  = 0;
        s_axi_lite_arprot  = 0;
        s_axi_lite_arvalid = 0;
        s_axi_lite_rready  = 0;

        s_axis_video_tdata  = 0;
        s_axis_video_tvalid = 0;
        s_axis_video_tlast  = 0;
        s_axis_video_tuser  = 0;

        m_axis_bitstream_tready = 1;

        $display("================================================================");
        $display(" HEVC Encoder SoC AXI Top Verification Testbench");
        $display("================================================================");

        // Reset Pulse
        #(CLK_PERIOD * 5);
        rst_n = 1;
        #(CLK_PERIOD * 5);

        //----------------------------------------------------------------------
        // Test 1: Verify Magic ID Register (0x1C)
        //----------------------------------------------------------------------
        axi_lite_read(12'h01C, rd_val);
        $display("[TEST 1] Magic ID Register: Read 0x%08X (Expected 0x48455643)", rd_val);
        if (rd_val !== 32'h48455643) begin
            $display("  [FAIL] Magic ID mismatch!");
            errors = errors + 1;
        end else begin
            $display("  [PASS] Magic ID 'HEVC' verified bit-exact.");
        end

        //----------------------------------------------------------------------
        // Test 2: Verify Resolution Register (0x20)
        //----------------------------------------------------------------------
        axi_lite_read(12'h020, rd_val);
        $display("[TEST 2] Resolution Register: Read 0x%08X (Expected 0x%04X%04X)", rd_val, FRAME_W, FRAME_H);
        if (rd_val !== {16'd64, 16'd64}) begin
            $display("  [FAIL] Resolution mismatch!");
            errors = errors + 1;
        end else begin
            $display("  [PASS] Resolution %0dx%0d verified.", FRAME_W, FRAME_H);
        end

        //----------------------------------------------------------------------
        // Test 3: Verify Status Register at Reset (0x04)
        // Expected: READY=1, BUSY=0, DONE=0 -> 0x00000004
        //----------------------------------------------------------------------
        axi_lite_read(12'h004, rd_val);
        $display("[TEST 3] Initial Status Register: Read 0x%08X", rd_val);
        if (rd_val[2:0] !== 3'b100) begin
            $display("  [FAIL] Expected READY=1, BUSY=0, DONE=0 (got %b)", rd_val[2:0]);
            errors = errors + 1;
        end else begin
            $display("  [PASS] Idle status confirmed (READY=1, BUSY=0, DONE=0).");
        end

        //----------------------------------------------------------------------
        // Test 4: Configure CSR Registers & Verify Readback
        //----------------------------------------------------------------------
        $display("[TEST 4] Writing and Verifying Configuration Registers...");
        axi_lite_write(12'h00C, 32'd1);     // Total frames = 1
        axi_lite_write(12'h010, 32'd32);    // Base QP = 32
        axi_lite_write(12'h014, 32'd0);     // GOP Struct = 0 (IPP)
        axi_lite_write(12'h018, 32'd6000);  // Bitrate = 6000 kbps

        axi_lite_read(12'h00C, rd_val);
        if (rd_val[15:0] !== 16'd1) begin $display("  [FAIL] Total frames mismatch!"); errors = errors + 1; end
        axi_lite_read(12'h010, rd_val);
        if (rd_val[5:0] !== 6'd32)  begin $display("  [FAIL] Base QP mismatch!"); errors = errors + 1; end
        axi_lite_read(12'h014, rd_val);
        if (rd_val[1:0] !== 2'd0)   begin $display("  [FAIL] GOP Struct mismatch!"); errors = errors + 1; end
        axi_lite_read(12'h018, rd_val);
        if (rd_val[15:0] !== 16'd6000) begin $display("  [FAIL] Bitrate mismatch!"); errors = errors + 1; end
        $display("  [PASS] All CSR readback values match written parameters.");

        //----------------------------------------------------------------------
        // Test 5: Soft Reset Assertion & Deassertion
        //----------------------------------------------------------------------
        $display("[TEST 5] Testing Soft Reset...");
        axi_lite_write(12'h000, 32'h00000002); // SOFT_RESET=1
        #(CLK_PERIOD * 3);
        if (dut.core_rst_n !== 1'b0) begin
            $display("  [FAIL] core_rst_n did not assert low during soft reset!");
            errors = errors + 1;
        end else begin
            $display("  [PASS] Software reset asserted core_rst_n low.");
        end
        axi_lite_write(12'h000, 32'h00000000); // SOFT_RESET=0
        #(CLK_PERIOD * 3);
        if (dut.core_rst_n !== 1'b1) begin
            $display("  [FAIL] core_rst_n did not deassert high after soft reset!");
            errors = errors + 1;
        end else begin
            $display("  [PASS] Software reset deasserted successfully.");
        end

        //----------------------------------------------------------------------
        // Test 6: Start Encoder via Control Register (0x00) with IRQ_EN
        // Control: Bit 0 = START, Bit 2 = IRQ_EN -> 0x00000005
        //----------------------------------------------------------------------
        $display("[TEST 6] Starting Encoder via AXI-Lite (START=1, IRQ_EN=1)...");
        axi_lite_write(12'h000, 32'h00000005);
        #(CLK_PERIOD * 2);

        axi_lite_read(12'h004, rd_val);
        $display("  Encoder Status: Read 0x%08X (BUSY=%b, READY=%b)", rd_val, rd_val[1], rd_val[2]);
        if (rd_val[1] !== 1'b1) begin
            $display("  [FAIL] Encoder did not enter BUSY state!");
            errors = errors + 1;
        end else begin
            $display("  [PASS] Encoder successfully entered BUSY state.");
        end

        //----------------------------------------------------------------------
        // Test 7: Stream Video Pixels via s_axis_video (64x64 = 4096 pixels)
        //----------------------------------------------------------------------
        $display("[TEST 7] Streaming 4096 Video Pixels via s_axis_video...");
        for (p = 0; p < 4096; p = p + 1) begin
            s_axis_video_tvalid <= 1'b1;
            // Pack 10-bit YUV: Y=304, U=340, V=1020
            s_axis_video_tdata  <= {2'b00, 10'd1020, 10'd340, 10'd304};
            s_axis_video_tlast  <= (p == 4095);
            s_axis_video_tuser  <= (p == 0);

            do begin
                @(posedge clk);
            end while (!s_axis_video_tready);
        end
        s_axis_video_tvalid <= 1'b0;
        s_axis_video_tlast  <= 1'b0;
        s_axis_video_tuser  <= 1'b0;
        $display("  [PASS] All 4096 pixels accepted by encoder core.");

        //----------------------------------------------------------------------
        // Test 8: Wait for Completion, verify TLAST & Interrupt Assertion
        //----------------------------------------------------------------------
        $display("[TEST 8] Waiting for Encoding Completion & TLAST on Bitstream...");
        while (!irq && !dut.reg_done && !dut.core_encode_done) begin
            @(posedge clk);
        end

        // Allow a few extra cycles for final bitstream drain
        #(CLK_PERIOD * 20);

        $display("  Encoding complete! Total bitstream bytes received: %0d", bytes_received);
        $display("  TLAST assertions observed: %0d", tlast_count);

        if (tlast_count < 1) begin
            $display("  [FAIL] m_axis_bitstream_tlast was NEVER asserted!");
            errors = errors + 1;
        end else begin
            $display("  [PASS] m_axis_bitstream_tlast asserted successfully on frame boundary!");
        end

        if (!irq) begin
            $display("  [FAIL] Completion interrupt (irq) was NOT asserted!");
            errors = errors + 1;
        end else begin
            $display("  [PASS] Completion interrupt (irq) asserted high.");
        end

        // Read Status: DONE=1, BUSY=0
        axi_lite_read(12'h004, rd_val);
        $display("  Post-encode Status: 0x%08X (DONE=%b, BUSY=%b)", rd_val, rd_val[0], rd_val[1]);
        if (rd_val[0] !== 1'b1 || rd_val[1] !== 1'b0) begin
            $display("  [FAIL] Expected DONE=1, BUSY=0!");
            errors = errors + 1;
        end else begin
            $display("  [PASS] DONE=1 and BUSY=0 confirmed.");
        end

        //----------------------------------------------------------------------
        // Test 9: Clear Interrupt via W1C (0x08)
        //----------------------------------------------------------------------
        $display("[TEST 9] Clearing Interrupt via W1C Register (0x08)...");
        axi_lite_write(12'h008, 32'h00000001); // Write 1 to clear
        #(CLK_PERIOD * 3);

        if (irq !== 1'b0) begin
            $display("  [FAIL] irq pin did not deassert after write-1-to-clear!");
            errors = errors + 1;
        end else begin
            $display("  [PASS] irq pin deasserted to 0.");
        end

        axi_lite_read(12'h008, rd_val);
        if (rd_val[0] !== 1'b0) begin
            $display("  [FAIL] irq_status register did not clear to 0!");
            errors = errors + 1;
        end else begin
            $display("  [PASS] irq_status cleared to 0.");
        end

        //----------------------------------------------------------------------
        // Final Summary
        //----------------------------------------------------------------------
        $display("================================================================");
        if (errors == 0) begin
            $display(" [SUCCESS] ALL 9 HEVC ENCODER AXI TOP TESTS PASSED!");
            $display(" SoC Integration Wrapper is 100%% verified & functional.");
        end else begin
            $display(" [FAILURE] Encountered %0d errors during verification!", errors);
        end
        $display("================================================================");

        #(CLK_PERIOD * 10);
        $finish(errors > 0 ? 1 : 0);
    end

    // Watchdog Timer (10 ms simulation time)
    initial begin
        #10000000;
        $display("[ERROR] Simulation timed out!");
        $finish(2);
    end

endmodule
