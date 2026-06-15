`timescale 1ns / 1ps

module tb_gop_controller();

    reg         clk;
    reg         rst_n;
    reg         encode_start;
    reg  [15:0] total_frames;
    wire        encode_done;
    
    wire        frame_start;
    reg         frame_done;
    wire [9:0]  frame_poc;
    wire [1:0]  frame_slice_type;
    wire [2:0]  temporal_id;
    wire [5:0]  nal_type;

    wire        alloc_valid;
    reg         alloc_ready;
    wire [9:0]  alloc_poc;
    reg  [2:0]  alloc_slot;

    wire        free_valid;
    wire [2:0]  free_slot;

    wire [2:0]  ref_l0 [0:4];
    wire [2:0]  ref_l1 [0:4];
    wire [2:0]  ref_l0_count;
    wire [2:0]  ref_l1_count;

    gop_controller uut (
        .clk(clk),
        .rst_n(rst_n),
        .encode_start(encode_start),
        .total_frames(total_frames),
        .encode_done(encode_done),
        .frame_start(frame_start),
        .frame_done(frame_done),
        .frame_poc(frame_poc),
        .frame_slice_type(frame_slice_type),
        .temporal_id(temporal_id),
        .nal_type(nal_type),
        .alloc_valid(alloc_valid),
        .alloc_ready(alloc_ready),
        .alloc_poc(alloc_poc),
        .alloc_slot(alloc_slot),
        .free_valid(free_valid),
        .free_slot(free_slot),
        // Use individual assignments since SystemVerilog ports into Verilog TB can be tricky, 
        // but since this is just a quick unit test we can rely on standard arrays in Questa.
        .ref_l0(ref_l0),
        .ref_l1(ref_l1),
        .ref_l0_count(ref_l0_count),
        .ref_l1_count(ref_l1_count)
    );

    always #5 clk = ~clk;

    // Mock Frame Store Allocator
    reg [2:0] next_slot = 0;
    always @(posedge clk) begin
        if (alloc_valid && alloc_ready) begin
            alloc_slot <= next_slot;
            next_slot  <= next_slot + 1;
        end
    end

    // Mock Frame Encoding
    always @(posedge clk) begin
        if (frame_start) begin
            // Print the frame details!
            $display("ENCODING FRAME: POC = %0d | Type = %s | TempID = %0d | L0 Cnt = %0d | L1 Cnt = %0d", 
                      frame_poc, (frame_slice_type==2)?"I":(frame_slice_type==1)?"P":"B", 
                      temporal_id, ref_l0_count, ref_l1_count);
            
            // Simulate encoding delay
            repeat(10) @(posedge clk);
            frame_done <= 1'b1;
            @(posedge clk);
            frame_done <= 1'b0;
        end
    end

    initial begin
        clk = 0;
        rst_n = 0;
        encode_start = 0;
        total_frames = 17; // 1 CRA + 16 B-frames
        frame_done = 0;
        alloc_ready = 1;
        
        #20 rst_n = 1;
        #10 encode_start = 1;
        #10 encode_start = 0;

        wait(encode_done);
        #50;
        $display("All frames encoded successfully.");
        $finish;
    end

endmodule
