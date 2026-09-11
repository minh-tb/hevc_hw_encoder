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
    // DUT Instance
    //=========================================================================
    hevc_encoder_top #(
        .FRAME_WIDTH (64),
        .FRAME_HEIGHT(64)
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

    //=========================================================================
    // AXI4 SLAVE MOCK (REAL SRAM MODEL)
    //=========================================================================
    reg [255:0] dram_mem [0:131071]; // 4MB Memory (131072 * 32 bytes)
    
    // Initialize DRAM to 0
    integer i_mem;
    initial begin
        for (i_mem = 0; i_mem < 131072; i_mem = i_mem + 1) begin
            dram_mem[i_mem] = 256'd0;
        end
    end

    // --- WRITE CHANNEL ---
    reg [31:0] waddr_reg;
    reg        w_active;

    always @(posedge clk) begin
        if (!rst_n) begin
            axi_awready <= 1'b1;
            axi_wready  <= 1'b0;
            axi_bvalid  <= 1'b0;
            w_active    <= 1'b0;
        end else begin
            // Address phase
            if (axi_awvalid && axi_awready) begin
                axi_awready <= 1'b0;
                axi_wready  <= 1'b1;
                waddr_reg   <= axi_awaddr;
                w_active    <= 1'b1;
            end
            
            // Data phase
            if (w_active && axi_wvalid && axi_wready) begin
                dram_mem[waddr_reg[19:5]] <= axi_wdata;
                waddr_reg <= waddr_reg + 32; // 256 bits = 32 bytes

                if (axi_wlast) begin
                    w_active    <= 1'b0;
                    axi_wready  <= 1'b0;
                    axi_awready <= 1'b1;
                    axi_bvalid  <= 1'b1;
                end
            end

            // Response phase
            if (axi_bvalid && axi_bready) begin
                axi_bvalid <= 1'b0;
            end
        end
    end

    // --- READ CHANNEL ---
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

    //=========================================================================
    // Stimulus and Monitoring
    //=========================================================================
    integer fd_out;
    integer i;

    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, tb_hevc_encoder_top);
        $timeformat(-9, 2, " ns", 20);
        fd_out = $fopen("str.bin", "wb");
        
        encode_start = 0;
        total_frames = 2;
        in_valid   = 0;
        in_pixel_y = 0;
        in_pixel_u = 512; // Flat grey UV
        in_pixel_v = 512;
        out_ready  = 1;

        @(posedge rst_n);
        #20;
        
        $display("[%0t] Starting Encoder (2 frames)...", $time);
        @(posedge clk);
        encode_start = 1;
        total_frames = 2;
        @(posedge clk);
        encode_start = 0;
        
        $display("[%0t] Streaming frame 1 of pure red pixels...", $time);
        
        // Stream frame 1: 4096 luma pixels (64x64)
        for (i = 0; i < 4096; i = i + 1) begin
            in_valid = 1'b1;
            in_pixel_y = 10'd76 << 2;   // Y for Pure Red (8-bit 76 -> 10-bit 304)
            in_pixel_u = 10'd85 << 2;   // U for Pure Red (8-bit 85 -> 10-bit 340)
            in_pixel_v = 10'd255 << 2;  // V for Pure Red (8-bit 255 -> 10-bit 1020)
            
            wait(in_ready);
            @(posedge clk);
        end
        in_valid = 0;
        $display("[%0t] Frame 1 pixels streamed. Waiting for frame 1 processing...", $time);
        
        // Wait for frame 1 inloop completion (sync_frame_done_pulse)
        // The encoder will re-assert in_ready when it's ready for frame 2 pixels
        wait(!uut.ctu_frame_active);       // Wait for raster scan to finish
        wait(uut.inloop_ctu_done);         // Wait for inloop to finish  
        @(posedge clk);
        
        // Small delay for frame_done propagation and GOP controller to start frame 2
        repeat(200) @(posedge clk);
        
        $display("[%0t] Streaming frame 2 of pure GREEN pixels...", $time);
        
        // Stream frame 2: 4096 luma pixels — Pure Green
        for (i = 0; i < 4096; i = i + 1) begin
            in_valid = 1'b1;
            in_pixel_y = 10'd150 << 2;  // Y for Pure Green (600)
            in_pixel_u = 10'd44 << 2;   // U for Pure Green (176)
            in_pixel_v = 10'd21 << 2;   // V for Pure Green (84)
            
            wait(in_ready);
            @(posedge clk);
        end
        in_valid = 0;
        $display("[%0t] Input Streaming Complete. Waiting for encode_done...", $time);
    end

    // File Write Monitor
    always @(posedge clk) begin
        if (out_valid && out_ready) begin
            $fwrite(fd_out, "%c", out_byte);
            $fflush(fd_out);
            $display("Time=%0t: [TB_OUT] byte=0x%02x (%0d)", $time, out_byte, out_byte);
        end
    end

    // =========================================================================
    // RECON DEBUG: Display every reconstructed pixel write
    // =========================================================================
    always @(posedge clk) begin
        if (uut.recon_out_valid) begin
            /* $display("# [%0t] RECON: comp=%0d x=%0d y=%0d pred=%0d, res=%0d, out=%0d",
                     $time,
                     uut.recon_out_comp,
                     uut.recon_out_x,
                     uut.recon_out_y,
                     uut.pred_pixel,
                     uut.residual_data,
                     uut.recon_out_pixel); */
        end
    end

    // Recon YUV Dump
    integer fd_recon;
    initial begin
        fd_recon = $fopen("recon_out.yuv", "wb");
    end
    always @(posedge clk) begin
        if (uut.u_inloop_filters.out_valid) begin
            $fwrite(fd_recon, "%c", uut.u_inloop_filters.out_pixel[9:2]);
        end
    end

    // Completion Monitor
    always @(posedge clk) begin
        if (encode_done) begin
            $display("[%0t] Encoding Finished Successfully!", $time);
            $fclose(fd_out);
            $fclose(fd_recon);
            $finish;
        end
    end

    // Timeout Watchdog
    initial begin
        #50000000;
        $display("ERROR: Simulation timeout reached!");
        $finish;
    end

endmodule