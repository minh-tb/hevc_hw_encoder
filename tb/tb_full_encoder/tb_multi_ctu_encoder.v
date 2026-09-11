//=============================================================================
// tb_multi_ctu_encoder.v
// Multi-CTU Benchmark & System Validation Testbench
// Resolution: 128x128 (2x2 = 4 CTUs per frame)
// Tests:
//   - Multi-CTU raster traversal
//   - Cross-CTU spatial motion vector prediction (MVP) & Merge candidates
//   - In-loop Deblocking & SAO seam filtering across CTU boundaries
//   - Multi-frame IPPP sequence generation
//=============================================================================

`timescale 1ns / 1ps

module tb_multi_ctu_encoder;

    reg clk;
    reg rst_n;

    // Clock generation (100 MHz)
    always #5 clk = ~clk;

    // Reset generation
    initial begin
        clk = 0;
        rst_n = 0;
        #50;
        rst_n = 1;
    end

    // Interface signals
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

    // Instantiate Top-Level with 128x128 Resolution
    hevc_encoder_top #(
        .FRAME_WIDTH (128),
        .FRAME_HEIGHT(128)
    ) uut (
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

    // Mock DRAM Memory (4MB)
    reg [255:0] dram_mem [0:131071];
    integer i_mem;
    initial begin
        for (i_mem = 0; i_mem < 131072; i_mem = i_mem + 1) dram_mem[i_mem] = 256'd0;
    end

    // AXI Write Channel
    reg [31:0] waddr_reg;
    reg        w_active;
    always @(posedge clk) begin
        if (!rst_n) begin
            axi_awready <= 1'b1;
            axi_wready  <= 1'b0;
            axi_bvalid  <= 1'b0;
            w_active    <= 1'b0;
        end else begin
            if (axi_awvalid && axi_awready) begin
                axi_awready <= 1'b0;
                axi_wready  <= 1'b1;
                waddr_reg   <= axi_awaddr;
                w_active    <= 1'b1;
            end
            if (w_active && axi_wvalid && axi_wready) begin
                dram_mem[waddr_reg[19:5]] <= axi_wdata;
                waddr_reg <= waddr_reg + 32;
                if (axi_wlast) begin
                    w_active    <= 1'b0;
                    axi_wready  <= 1'b0;
                    axi_awready <= 1'b1;
                    axi_bvalid  <= 1'b1;
                end
            end
            if (axi_bvalid && axi_bready) axi_bvalid <= 1'b0;
        end
    end

    // AXI Read Channel
    reg [7:0] rlen_cnt;
    reg       r_active;
    reg [31:0] raddr_reg;
    always @(posedge clk) begin
        if (!rst_n) begin
            axi_arready <= 1'b1;
            axi_rvalid  <= 1'b0;
            axi_rlast   <= 1'b0;
            axi_rdata   <= 256'd0;
            r_active    <= 1'b0;
        end else begin
            if (axi_arvalid && axi_arready) begin
                axi_arready <= 1'b0;
                r_active    <= 1'b1;
                rlen_cnt    <= axi_arlen;
                raddr_reg   <= axi_araddr;
                axi_rvalid  <= 1'b1;
                axi_rlast   <= (axi_arlen == 0);
                axi_rdata   <= dram_mem[axi_araddr[19:5]];
            end else if (r_active && axi_rvalid && axi_rready) begin
                if (rlen_cnt == 0) begin
                    r_active    <= 1'b0;
                    axi_rvalid  <= 1'b0;
                    axi_arready <= 1'b1;
                end else begin
                    rlen_cnt    <= rlen_cnt - 1;
                    raddr_reg   <= raddr_reg + 32;
                    axi_rdata   <= dram_mem[(raddr_reg + 32) >> 5];
                    axi_rlast   <= (rlen_cnt == 1);
                end
            end
        end
    end

    // File Output Stream
    integer fd_out;
    integer ctu_idx, pix_idx;
    initial begin
        fd_out = $fopen("str_128x128.bin", "wb");
        encode_start = 0;
        total_frames = 2;
        in_valid   = 0;
        in_pixel_y = 0;
        in_pixel_u = 512;
        in_pixel_v = 512;
        out_ready  = 1;

        @(posedge rst_n);
        #20;

        $display("[%0t] Starting Multi-CTU Encoder (128x128, 2x2 CTUs, 2 frames)...", $time);
        @(posedge clk);
        encode_start = 1;
        total_frames = 2;
        @(posedge clk);
        encode_start = 0;

        // ---------------------------------------------------------------------
        // Frame 0 (I-Slice) — 4 CTUs
        // ---------------------------------------------------------------------
        $display("[%0t] Streaming Frame 0 (I-Slice, 4 CTUs)...", $time);
        for (ctu_idx = 0; ctu_idx < 4; ctu_idx = ctu_idx + 1) begin
            $display("[%0t] Streaming Frame 0 CTU %0d/4...", $time, ctu_idx);
            for (pix_idx = 0; pix_idx < 4096; pix_idx = pix_idx + 1) begin
                in_valid = 1'b1;
                // Gradual gradient across CTUs to test spatial prediction
                in_pixel_y = (10'd300 + (ctu_idx * 20) + (pix_idx & 10'd15));
                in_pixel_u = 10'd340;
                in_pixel_v = 10'd1020;
                wait(in_ready);
                @(posedge clk);
            end
            in_valid = 0;
            // Wait for CTU processing before feeding next CTU if needed
            repeat(100) @(posedge clk);
        end

        // Wait for Frame 0 completion
        wait(uut.sync_frame_done_pulse);
        @(posedge clk);
        repeat(2000) @(posedge clk);

        // ---------------------------------------------------------------------
        // Frame 1 (P-Slice) — 4 CTUs
        // ---------------------------------------------------------------------
        $display("[%0t] Streaming Frame 1 (P-Slice, 4 CTUs)...", $time);
        for (ctu_idx = 0; ctu_idx < 4; ctu_idx = ctu_idx + 1) begin
            $display("[%0t] Streaming Frame 1 CTU %0d/4...", $time, ctu_idx);
            for (pix_idx = 0; pix_idx < 4096; pix_idx = pix_idx + 1) begin
                in_valid = 1'b1;
                in_pixel_y = (10'd600 + (ctu_idx * 10) + (pix_idx & 10'd7));
                in_pixel_u = 10'd176;
                in_pixel_v = 10'd84;
                wait(in_ready);
                @(posedge clk);
            end
            in_valid = 0;
            repeat(100) @(posedge clk);
        end

        $display("[%0t] Input Streaming Complete. Waiting for encode_done...", $time);
    end

    // File Output Monitor
    always @(posedge clk) begin
        if (out_valid && out_ready) begin
            $fwrite(fd_out, "%c", out_byte);
            $fflush(fd_out);
            $display("Time=%0t: [TB_OUT] byte=0x%02x (%0d)", $time, out_byte, out_byte);
        end
    end

    // Completion Monitor
    always @(posedge clk) begin
        if (encode_done) begin
            $display("[%0t] 128x128 Multi-CTU Encoding Finished Successfully!", $time);
            $fclose(fd_out);
            $finish;
        end
    end

    // Watchdog
    initial begin
        #100000000;
        $display("ERROR: Simulation timeout reached!");
        $finish;
    end

endmodule
