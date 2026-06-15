`timescale 1ns / 1ps

module tb_nal_parser;
    reg clk;
    reg rst_n;
    reg in_valid;
    wire in_ready;
    reg [7:0] in_byte;
    reg in_last;
    
    wire out_valid;
    reg out_ready;
    wire [7:0] out_byte;
    wire out_last;

    nal_parser dut (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_byte(in_byte),
        .in_last(in_last),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_byte(out_byte),
        .out_last(out_last)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    task send_byte(input [7:0] b, input last);
    begin
        in_valid = 1;
        in_byte = b;
        in_last = last;
        wait(in_ready);
        @(posedge clk);
        in_valid = 0;
        @(posedge clk);
    end
    endtask

    initial begin
        rst_n = 0;
        in_valid = 0;
        in_byte = 0;
        in_last = 0;
        out_ready = 1;
        #20 rst_n = 1;
        
        // Send: 00 00 00 01 (SC)  42  00 00 03 01 (EPB)  FF (Last)
        send_byte(8'h00, 0);
        send_byte(8'h00, 0);
        send_byte(8'h00, 0);
        send_byte(8'h01, 0);
        
        send_byte(8'h42, 0);
        
        send_byte(8'h00, 0);
        send_byte(8'h00, 0);
        send_byte(8'h03, 0);
        send_byte(8'h01, 0);
        
        send_byte(8'hFF, 1);
        
        #100;
        $finish;
    end

    always @(posedge clk) begin
        if (out_valid && out_ready) begin
            $display("RBSP Byte: %h (Last: %b)", out_byte, out_last);
        end
    end

endmodule
