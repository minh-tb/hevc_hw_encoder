//=============================================================================
// tb_256x256_encoder.v
// Multi-Row CTU Stress Test (256x256 = 16 CTUs per frame, 4x4 grid)
// Tests:
//   - Multi-row raster traversal (4 rows x 4 cols)
//   - Line buffer storage across CTU rows
//   - Spatial MVP across horizontal and vertical CTU seams
//   - CABAC bitstream generation for 16-CTU frames
//=============================================================================

`timescale 1ns / 1ps

module tb_256x256_encoder;

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

    // Instantiate Top-Level with 256x256 Resolution
    hevc_encoder_top #(
        .FRAME_WIDTH (256),
        .FRAME_HEIGHT(256)
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

    // Mock DRAM Memory (8MB)
    reg [255:0] dram_mem [0:262143];
    integer i_mem;
    initial begin
        for (i_mem = 0; i_mem < 262144; i_mem = i_mem + 1) dram_mem[i_mem] = 256'd0;
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
                dram_mem[waddr_reg[20:5]] <= axi_wdata;
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
                axi_rdata   <= dram_mem[axi_araddr[20:5]];
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
        fd_out = $fopen("str_256x256.bin", "wb");
        encode_start = 0;
        total_frames = 2;
        in_valid   = 0;
        in_pixel_y = 0;
        in_pixel_u = 512;
        in_pixel_v = 512;
        out_ready  = 1;

        @(posedge rst_n);
        #20;

        $display("[%0t] Starting Multi-CTU Encoder (256x256, 4x4 = 16 CTUs, 2 frames)...", $time);
        @(posedge clk);
        encode_start = 1;
        total_frames = 2;
        @(posedge clk);
        encode_start = 0;

        // ---------------------------------------------------------------------
        // Frame 0 (I-Slice) — 16 CTUs
        // ---------------------------------------------------------------------
        $display("[%0t] Streaming Frame 0 (I-Slice, 16 CTUs)...", $time);
        for (ctu_idx = 0; ctu_idx < 16; ctu_idx = ctu_idx + 1) begin
            $display("[%0t] Streaming Frame 0 CTU %0d/16...", $time, ctu_idx);
            for (pix_idx = 0; pix_idx < 4096; pix_idx = pix_idx + 1) begin
                in_valid = 1'b1;
                in_pixel_y = (10'd200 + (ctu_idx * 15) + (pix_idx & 10'd31));
                in_pixel_u = 10'd340;
                in_pixel_v = 10'd1020;
                wait(in_ready);
                @(posedge clk);
            end
            in_valid = 0;
            repeat(100) @(posedge clk);
        end

        // Wait for Frame 0 completion
        while (!uut.sync_frame_done_pulse) @(posedge clk);
        @(posedge clk);
        repeat(200) @(posedge clk);

        // ---------------------------------------------------------------------
        // Frame 1 (P-Slice) — 16 CTUs
        // ---------------------------------------------------------------------
        $display("[%0t] Streaming Frame 1 (P-Slice, 16 CTUs)...", $time);
        for (ctu_idx = 0; ctu_idx < 16; ctu_idx = ctu_idx + 1) begin
            $display("[%0t] Streaming Frame 1 CTU %0d/16...", $time, ctu_idx);
            for (pix_idx = 0; pix_idx < 4096; pix_idx = pix_idx + 1) begin
                in_valid = 1'b1;
                in_pixel_y = (10'd500 + (ctu_idx * 8) + (pix_idx & 10'd15));
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
        end
    end

    // Completion Monitor
    always @(posedge clk) begin
        if (encode_done) begin
            $display("[%0t] 256x256 Multi-CTU Encoding Finished Successfully!", $time);
            // Write standard Annex B End of Sequence (EOS) NAL unit: 00 00 00 01 48 01
            $fwrite(fd_out, "%c%c%c%c%c%c", 8'h00, 8'h00, 8'h00, 8'h01, 8'h48, 8'h01);
            $fflush(fd_out);
            $fclose(fd_out);
            $finish;
        end
    end

    // Watchdog
    initial begin
        #500000000;
        $display("ERROR: Simulation timeout reached!");
        $finish;
    end

endmodule
