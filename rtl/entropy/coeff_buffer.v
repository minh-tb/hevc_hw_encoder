`timescale 1ns / 1ps
`include "parameter_pkg.vh"

module coeff_buffer #(
    parameter DATA_W = 16,
    parameter DEPTH  = 1024,
    parameter ADDR_W = 10
)(
    input  wire              clk,
    
    // Write port (from Quantizer)
    input  wire              we,
    input  wire [ADDR_W-1:0] waddr,
    input  wire [DATA_W-1:0] wdata,
    
    // Read port (to CABAC / CG Assembler)
    input  wire              re,
    input  wire [ADDR_W-1:0] raddr,
    output reg  [DATA_W-1:0] rdata
);

    reg [DATA_W-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we) begin
            mem[waddr] <= wdata;
        end
        if (re) begin
            rdata <= mem[raddr];
        end
    end

endmodule
