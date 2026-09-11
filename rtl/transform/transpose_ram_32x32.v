//=============================================================================
// transpose_ram_32x32.v
// Dual-Port Transpose Buffer for 2D Transform Engine
// Allows writing in row-order and reading in column-order
// Capacity: 32x32 = 1024 x 16-bit entries (16 kbits, fits in 1 single M10K)
//=============================================================================

`timescale 1ns / 1ps
`include "parameter_pkg.vh"

module transpose_ram_32x32 (
    input  wire        clk,
    
    // Write Port (Row-wise write)
    input  wire        wr_en,
    input  wire [4:0]  wr_row,
    input  wire [511:0] wr_vec,       // 32 samples in one row
    
    // Read Port (Column-wise read)
    input  wire [4:0]  rd_col,
    output reg  [511:0] rd_vec        // 32 samples in one column
);

    // 32 independent banks for conflict-free row-write / col-read
    reg signed [15:0] mem [0:31][0:31];
    integer i, j;

    // Write Row
    always @(posedge clk) begin
        if (wr_en) begin
            for (j = 0; j < 32; j = j + 1) begin
                mem[wr_row][j] <= wr_vec[j*16 +: 16];
            end
        end
    end

    // Read Column (Transposed)
    always @(posedge clk) begin
        for (i = 0; i < 32; i = i + 1) begin
            rd_vec[i*16 +: 16] <= mem[i][rd_col];
        end
    end

endmodule
