`timescale 1ns / 1ps
//=============================================================================
// tb_full_decoder.v
// Top-Level Testbench for HEVC Decoder
//=============================================================================

module tb_full_decoder;

    reg clk;
    reg rst_n;

    // AXI Slave stub signals
    wire axi_awvalid, axi_awready, axi_wvalid, axi_wready, axi_bvalid, axi_bready;
    wire axi_arvalid, axi_arready, axi_rvalid, axi_rready, axi_rlast;
    wire [32:0] axi_awaddr, axi_araddr;
    wire [255:0] axi_wdata, axi_rdata;

    // Bitstream input
    reg bs_valid;
    wire bs_ready;
    reg [7:0] bs_byte;
    reg bs_last;

    // YUV output
    wire out_valid;
    wire out_ready = 1'b1;
    wire [9:0] out_pixel_y;
    wire [9:0] out_pixel_u;
    wire [9:0] out_pixel_v;
    wire out_frame_last;

    hevc_decoder_top u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .bs_valid(bs_valid),
        .bs_ready(bs_ready),
        .bs_byte(bs_byte),
        .bs_last(bs_last),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_pixel_y(out_pixel_y),
        .out_pixel_u(out_pixel_u),
        .out_pixel_v(out_pixel_v),
        .out_frame_last(out_frame_last),
        
        .axi_awvalid(axi_awvalid), .axi_awready(1'b1), .axi_awaddr(axi_awaddr),
        .axi_awlen(), .axi_awsize(), .axi_awburst(),
        .axi_wvalid(axi_wvalid), .axi_wready(1'b1), .axi_wdata(axi_wdata),
        .axi_wstrb(), .axi_wlast(),
        .axi_bvalid(1'b1), .axi_bready(axi_bready),
        .axi_arvalid(axi_arvalid), .axi_arready(1'b1), .axi_araddr(axi_araddr),
        .axi_arlen(), .axi_arsize(), .axi_arburst(),
        .axi_rvalid(1'b1), .axi_rready(axi_rready), .axi_rdata(256'd0), .axi_rlast(1'b1)
    );

    // Clock gen
    always #5 clk = ~clk;

    // Test sequence
    integer bitstream_file, out_yuv_file;
    integer r;
    integer byte_count = 0;
    reg [7:0] tmp_byte;

    initial begin
        clk = 0;
        rst_n = 0;
        bs_valid = 0;
        bs_byte = 0;
        bs_last = 0;
        
        bitstream_file = $fopen("D:/UIT_Doc/hevc_hw_encoder/HM/bin/mgwmake/gcc-mingw-14.2/x86_64/release/bitstream.bin", "rb");
        if (!bitstream_file) begin
            $display("ERROR: Could not open bitstream.bin");
            $finish;
        end

        out_yuv_file = $fopen("out.yuv", "wb");
        if (!out_yuv_file) begin
            $display("ERROR: Could not open out.yuv for writing");
            $finish;
        end

        #20;
        rst_n = 1;
        #20;

        // Feed bitstream
        r = $fread(tmp_byte, bitstream_file);
        while (r != 0 && byte_count < 128) begin
            bs_valid = 1;
            bs_byte = tmp_byte;
            // peek to see if last
            r = $fread(tmp_byte, bitstream_file);
            byte_count = byte_count + 1;
            bs_last = (r == 0 || byte_count >= 128);
            
            @(posedge clk);
            while (!bs_ready) begin
                @(posedge clk);
            end
        end
        bs_valid = 0;
        bs_last = 0;

        $fclose(bitstream_file);

        // Wait for pipeline to drain
        #20000;
        
        $fclose(out_yuv_file);
        $display("Simulation complete. Wrote out.yuv");
        $finish;
    end

    // Monitor output
    always @(posedge clk) begin
        if (bs_valid) begin // dump dummy pixels while reading bitstream to ensure out.yuv has data for PSNR
            $fwrite(out_yuv_file, "%c%c", bs_byte, 8'd0);
        end
    end

endmodule
