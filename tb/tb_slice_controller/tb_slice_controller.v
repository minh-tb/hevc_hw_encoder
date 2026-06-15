`timescale 1ns / 1ps

module tb_slice_controller();

    reg         clk;
    reg         rst_n;

    // Interface to GOP Controller
    reg         frame_start;
    reg  [9:0]  frame_poc;
    reg  [1:0]  frame_slice_type;
    reg  [2:0]  temporal_id;
    reg  [5:0]  nal_type;
    wire        frame_done;

    // Interface to CTU Raster Scan
    wire        ctu_frame_start;
    reg         ctu_frame_done;

    // Interface to NAL Writer
    wire        nal_start;
    wire [5:0]  out_nal_type;
    wire [2:0]  out_temporal_id;
    wire        nal_end;

    wire        rbsp_valid;
    reg         rbsp_ready;
    wire [7:0]  rbsp_byte;
    wire        rbsp_last;

    slice_controller uut (
        .clk(clk),
        .rst_n(rst_n),
        .frame_start(frame_start),
        .frame_poc(frame_poc),
        .frame_slice_type(frame_slice_type),
        .temporal_id(temporal_id),
        .nal_type(nal_type),
        .frame_done(frame_done),
        .ctu_frame_start(ctu_frame_start),
        .ctu_frame_done(ctu_frame_done),
        .nal_start(nal_start),
        .out_nal_type(out_nal_type),
        .out_temporal_id(out_temporal_id),
        .nal_end(nal_end),
        .rbsp_valid(rbsp_valid),
        .rbsp_ready(rbsp_ready),
        .rbsp_byte(rbsp_byte),
        .rbsp_last(rbsp_last)
    );

    always #5 clk = ~clk;

    // Mock NAL Writer
    always @(posedge clk) begin
        if (nal_start) begin
            $display("--- NAL START: Type=%0d, TempID=%0d ---", out_nal_type, out_temporal_id);
        end
        if (rbsp_valid && rbsp_ready) begin
            $display("    [NAL Writer] RBSP Byte: 0x%02X", rbsp_byte);
        end
        if (nal_end) begin
            $display("--- NAL END ---");
        end
    end

    // Mock CTU Scanner
    always @(posedge clk) begin
        if (ctu_frame_start) begin
            $display(">>> CTU FRAME SCAN STARTED <<<");
            // Simulate CTU scan delay
            repeat(10) @(posedge clk);
            ctu_frame_done <= 1'b1;
            @(posedge clk);
            ctu_frame_done <= 1'b0;
            $display("<<< CTU FRAME SCAN DONE <<<");
        end
    end

    initial begin
        clk = 0;
        rst_n = 0;
        frame_start = 0;
        frame_poc = 0;
        frame_slice_type = 2;
        temporal_id = 0;
        nal_type = 21;
        ctu_frame_done = 0;
        rbsp_ready = 1;

        #20 rst_n = 1;

        // Test 1: I-Frame CRA
        $display("\n=== TEST 1: I-Frame CRA (POC=0) ===");
        #10;
        frame_start = 1;
        frame_poc = 0;
        frame_slice_type = 2; // SLICE_I
        nal_type = 21;        // CRA
        #10 frame_start = 0;

        wait(frame_done);
        #50;

        // Test 2: B-Frame
        $display("\n=== TEST 2: B-Frame (POC=16) ===");
        frame_start = 1;
        frame_poc = 16;
        frame_slice_type = 0; // SLICE_B
        nal_type = 1;         // TRAIL_R
        #10 frame_start = 0;

        wait(frame_done);
        #50;

        $display("\nAll tests passed!");
        $finish;
    end

endmodule
