//=============================================================================
// decoder_inloop_filters.v
// Decoder In-loop Filters (Deblock & SAO)
//
// Structural placeholder. Acts as a pass-through for the PoC.
//=============================================================================

module decoder_inloop_filters (
    input  wire         clk,
    input  wire         rst_n,

    // Input from Reconstruction Unit
    input  wire         in_valid,
    input  wire [9:0]   in_pixel,
    input  wire [5:0]   in_x,
    input  wire [5:0]   in_y,

    // Output to DPB (Frame Store)
    output reg          out_valid,
    output reg [9:0]    out_pixel,
    output reg [11:0]   out_abs_x,
    output reg [11:0]   out_abs_y
);

    // For structural proof of concept, we just pipe the output.
    // In a real system, there's a CTU delay and line buffers.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_pixel <= 10'd0;
            out_abs_x <= 12'd0;
            out_abs_y <= 12'd0;
        end else begin
            out_valid <= in_valid;
            out_pixel <= in_pixel;
            // Assuming for PoC we're just doing CTU 0,0
            out_abs_x <= {6'd0, in_x};
            out_abs_y <= {6'd0, in_y};
        end
    end

endmodule
