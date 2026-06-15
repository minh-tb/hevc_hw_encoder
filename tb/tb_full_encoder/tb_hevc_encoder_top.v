`timescale 1ns / 1ps

module tb_hevc_encoder_top;

    //=========================================================================
    // Clocks and Resets
    //=========================================================================
    reg clk;
    reg rst_n;

    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz clock
    end

    initial begin
        rst_n = 0;
        #50 rst_n = 1;
    end

    //=========================================================================
    // DUT Signals
    //=========================================================================
    reg         encode_start;
    reg  [15:0] total_frames;
    wire        encode_done;

    reg         in_valid;
    wire        in_ready;
    reg  [9:0]  in_pixel_y;
    reg  [9:0]  in_pixel_u;
    reg  [9:0]  in_pixel_v;

    wire        out_valid;
    reg         out_ready;
    wire [7:0]  out_byte;

    // AXI4 Master Interfaces (Encoder drives these, TB mocks the Slave)
    wire        axi_awvalid;
    reg         axi_awready;
    wire [32:0] axi_awaddr;
    wire [7:0]  axi_awlen;
    wire [2:0]  axi_awsize;
    wire [1:0]  axi_awburst;
    wire        axi_wvalid;
    reg         axi_wready;
    wire [255:0] axi_wdata;
    wire [31:0] axi_wstrb;
    wire        axi_wlast;
    reg         axi_bvalid;
    wire        axi_bready;
    
    wire        axi_arvalid;
    reg         axi_arready;
    wire [32:0] axi_araddr;
    wire [7:0]  axi_arlen;
    wire [2:0]  axi_arsize;
    wire [1:0]  axi_arburst;
    reg         axi_rvalid;
    wire        axi_rready;
    reg  [255:0] axi_rdata;
    reg         axi_rlast;

    //=========================================================================
    // Instantiate the Top-Level Encoder
    //=========================================================================
    hevc_encoder_top uut (
        .clk(clk),
        .rst_n(rst_n),
        .encode_start(encode_start),
        .total_frames(total_frames),
        .encode_done(encode_done),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_pixel_y(in_pixel_y),
        .in_pixel_u(in_pixel_u),
        .in_pixel_v(in_pixel_v),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_byte(out_byte),
        .axi_awvalid(axi_awvalid),
        .axi_awready(axi_awready),
        .axi_awaddr(axi_awaddr),
        .axi_awlen(axi_awlen),
        .axi_awsize(axi_awsize),
        .axi_awburst(axi_awburst),
        .axi_wvalid(axi_wvalid),
        .axi_wready(axi_wready),
        .axi_wdata(axi_wdata),
        .axi_wstrb(axi_wstrb),
        .axi_wlast(axi_wlast),
        .axi_bvalid(axi_bvalid),
        .axi_bready(axi_bready),
        .axi_arvalid(axi_arvalid),
        .axi_arready(axi_arready),
        .axi_araddr(axi_araddr),
        .axi_arlen(axi_arlen),
        .axi_arsize(axi_arsize),
        .axi_arburst(axi_arburst),
        .axi_rvalid(axi_rvalid),
        .axi_rready(axi_rready),
        .axi_rdata(axi_rdata),
        .axi_rlast(axi_rlast)
    );

    //=========================================================================
    // AXI4 SLAVE MOCK (Dummy external DRAM)
    //=========================================================================
    reg [7:0] rlen_cnt;
    reg       r_active;

    always @(posedge clk) begin
        if (!rst_n) begin
            axi_awready <= 1'b1;
            axi_wready  <= 1'b1;
            axi_bvalid  <= 1'b0;
            axi_arready <= 1'b1;
            axi_rvalid  <= 1'b0;
            axi_rlast   <= 1'b0;
            axi_rdata   <= 256'd0;
            r_active    <= 1'b0;
        end else begin
            // Write Channel Mock (Always ready, ACK bvalid immediately on wlast)
            if (axi_wvalid && axi_wready && axi_wlast) begin
                axi_bvalid <= 1'b1;
            end else if (axi_bvalid && axi_bready) begin
                axi_bvalid <= 1'b0;
            end
            
            // Read Channel Mock (Burst generation)
            if (axi_arvalid && axi_arready) begin
                axi_arready <= 1'b0;
                r_active    <= 1'b1;
                rlen_cnt    <= axi_arlen;
                axi_rvalid  <= 1'b1;
                axi_rlast   <= (axi_arlen == 0);
                axi_rdata   <= 256'hAAAAAAAAAAAAAAAAFFFFFFFFFFFFFFFF; // Dummy ref data
            end else if (r_active && axi_rvalid && axi_rready) begin
                if (rlen_cnt == 0) begin
                    r_active    <= 1'b0;
                    axi_rvalid  <= 1'b0;
                    axi_rlast   <= 1'b0;
                    axi_arready <= 1'b1;
                end else begin
                    rlen_cnt    <= rlen_cnt - 1;
                    axi_rlast   <= (rlen_cnt == 1);
                    axi_rdata   <= ~axi_rdata; // Toggle dummy data
                end
            end
        end
    end

    //=========================================================================
    // Stimulus and Monitoring
    //=========================================================================
    integer fd_out;
    integer i;

    initial begin
        $timeformat(-9, 2, " ns", 20);
        fd_out = $fopen("test_out.bin", "wb");
        
        encode_start = 0;
        total_frames = 1;
        in_valid   = 0;
        in_pixel_y = 0;
        in_pixel_u = 512; // Flat grey UV
        in_pixel_v = 512;
        out_ready  = 1;

        @(posedge rst_n);
        #20;
        
        $display("[%0t] Starting Encoding Sequence...", $time);
        @(posedge clk);
        encode_start = 1;
        total_frames = 3; // 3 frames (1 Intra + 2 Inter)
        @(posedge clk);
        encode_start = 0;

        // The encoder currently defaults to 64x64 frame resolution (4096 pixels)
        // We stream pixels mimicking a gradient pattern
        for (i = 0; i < 4096 * 3; i = i + 1) begin
            in_valid = 1'b1;
            in_pixel_y = (i % 1024); // Ramp pattern
            
            // Handshake synchronization
            wait(in_ready);
            @(posedge clk);
            
            // Add random stalls to verify pipeline backpressure robustness
            if (i % 31 == 0) begin
                in_valid = 0;
                repeat(3) @(posedge clk);
            end
        end
        in_valid = 0;
        $display("[%0t] Input Streaming Complete. Waiting for encode_done...", $time);
    end

    // File Write Monitor
    always @(posedge clk) begin
        if (out_valid && out_ready) begin
            $fwrite(fd_out, "%c", out_byte);
            // Optional: $display("Wrote Byte: %02h", out_byte);
        end
    end

    // Completion Monitor
    always @(posedge clk) begin
        if (encode_done) begin
            $display("[%0t] Encoding Finished Successfully!", $time);
            $fclose(fd_out);
            $finish;
        end
    end

    // Timeout Watchdog
    initial begin
        #500000;
        $display("ERROR: Simulation timeout reached!");
        $finish;
    end

endmodule