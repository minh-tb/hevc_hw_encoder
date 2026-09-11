//=============================================================================
// sao_window_buffer.v
// 3x3 Window Generator for SAO Statistics
// Generates a 3x3 window of pixels by streaming through two line buffers.
// line_width must be set to 64 (luma) or 32 (chroma) before each component.
//=============================================================================

`include "parameter_pkg.vh"

module sao_window_buffer (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         clear,        // Clears the buffer for a new component
    input  wire [5:0]   line_width,   // 63 for luma (64-1), 31 for chroma (32-1)
    input  wire         in_valid,
    input  wire [`PIXEL_WIDTH-1:0] in_pixel,

    output reg          out_valid,
    output reg  [`PIXEL_WIDTH-1:0] p_cc, // Center (x, y)
    output reg  [`PIXEL_WIDTH-1:0] p_tl, // Top-Left (x-1, y-1)
    output reg  [`PIXEL_WIDTH-1:0] p_tc, // Top-Center (x, y-1)
    output reg  [`PIXEL_WIDTH-1:0] p_tr, // Top-Right (x+1, y-1)
    output reg  [`PIXEL_WIDTH-1:0] p_cl, // Center-Left (x-1, y)
    output reg  [`PIXEL_WIDTH-1:0] p_cr, // Center-Right (x+1, y)
    output reg  [`PIXEL_WIDTH-1:0] p_bl, // Bottom-Left (x-1, y+1)
    output reg  [`PIXEL_WIDTH-1:0] p_bc, // Bottom-Center (x, y+1)
    output reg  [`PIXEL_WIDTH-1:0] p_br  // Bottom-Right (x+1, y+1)
);

    // Two line buffers of 64 pixels each (only [0:line_width] used per component)
    reg [`PIXEL_WIDTH-1:0] line0 [0:63];
    reg [`PIXEL_WIDTH-1:0] line1 [0:63];
    
    reg [5:0] wr_ptr;
    
    // Shift registers for the 3 rows
    reg [`PIXEL_WIDTH-1:0] row0_reg [0:2];
    reg [`PIXEL_WIDTH-1:0] row1_reg [0:2];
    reg [`PIXEL_WIDTH-1:0] row2_reg [0:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 6'd0;
            out_valid <= 1'b0;
            
            p_cc <= 0; p_tl <= 0; p_tc <= 0; p_tr <= 0;
            p_cl <= 0; p_cr <= 0; p_bl <= 0; p_bc <= 0; p_br <= 0;
        end else if (clear) begin
            wr_ptr <= 6'd0;
            out_valid <= 1'b0;
        end else if (in_valid) begin
            // Read from line buffers BEFORE writing new pixel
            row0_reg[2] <= line0[wr_ptr];
            row1_reg[2] <= line1[wr_ptr];
            row2_reg[2] <= in_pixel;
            
            // Write new pixel and shift line buffers up
            line0[wr_ptr] <= line1[wr_ptr];
            line1[wr_ptr] <= in_pixel;
            
            // Wrap write pointer at component width (64 for luma, 32 for chroma)
            if (wr_ptr == line_width)
                wr_ptr <= 6'd0;
            else
                wr_ptr <= wr_ptr + 6'd1;
            
            // Shift pipeline
            row0_reg[1] <= row0_reg[2]; row0_reg[0] <= row0_reg[1];
            row1_reg[1] <= row1_reg[2]; row1_reg[0] <= row1_reg[1];
            row2_reg[1] <= row2_reg[2]; row2_reg[0] <= row2_reg[1];
            
            // Output mapping
            // row0 = Top (y-1)
            // row1 = Center (y)
            // row2 = Bottom (y+1)
            p_tl <= row0_reg[0]; p_tc <= row0_reg[1]; p_tr <= row0_reg[2];
            p_cl <= row1_reg[0]; p_cc <= row1_reg[1]; p_cr <= row1_reg[2];
            p_bl <= row2_reg[0]; p_bc <= row2_reg[1]; p_br <= row2_reg[2];
            
            out_valid <= 1'b1;
        end else begin
            out_valid <= 1'b0;
        end
    end

endmodule

