//=============================================================================
// coeff_buffer.v
// Dual-Port SRAM for Coefficient Buffer
//
// Bridges the forward-scan output of the Quantizer and the reverse-scan
// burst reads of the CABAC syntax encoder.
//
// Write Port: Used by fwd_quant
// Read Port: Used by syntax_coeff
// Memory depth: 4096 x 16-bit to accommodate Y (1024), Cb (1024), Cr (1024)
//=============================================================================

module coeff_buffer (
    input  wire        clk,

    // Write Port
    input  wire        we,
    input  wire [11:0] waddr,
    input  wire [15:0] wdata,

    // Read Port
    input  wire        re,
    input  wire [11:0] raddr,
    output reg  [15:0] rdata
);

    // RAM inference
    reg [15:0] mem [0:4095];

    always @(posedge clk) begin
        if (we) begin
            mem[waddr] <= wdata;
        end
        if (re) begin
            rdata <= mem[raddr];
        end
    end

endmodule
