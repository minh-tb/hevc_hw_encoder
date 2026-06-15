`include "parameter_pkg.vh"

module mc_p2s #(
    parameter PIXEL_WIDTH = `PIXEL_WIDTH
)(
    input  wire                        clk,
    input  wire                        rst_n,
    
    input  wire                        mc_done,
    input  wire [PIXEL_WIDTH*16-1:0]   mc_pred_y_flat,
    
    output reg                         pred_valid,
    output reg  [PIXEL_WIDTH-1:0]      pred_pixel,
    output reg  [9:0]                  out_x,
    output reg  [9:0]                  out_y,
    output reg                         out_last
);

    reg [4:0] count;
    reg [PIXEL_WIDTH*16-1:0] shift_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pred_valid <= 1'b0;
            pred_pixel <= {PIXEL_WIDTH{1'b0}};
            count      <= 5'd0;
            shift_reg  <= {PIXEL_WIDTH*16{1'b0}};
            out_x      <= 10'd0;
            out_y      <= 10'd0;
            out_last   <= 1'b0;
        end else begin
            if (mc_done) begin
                count <= 5'd15;
                shift_reg <= mc_pred_y_flat >> PIXEL_WIDTH;
                pred_valid <= 1'b1;
                pred_pixel <= mc_pred_y_flat[PIXEL_WIDTH-1:0];
                out_x <= 10'd0;
                out_y <= 10'd0;
                out_last <= 1'b0;
            end else if (count > 5'd0) begin
                count <= count - 5'd1;
                shift_reg <= shift_reg >> PIXEL_WIDTH;
                pred_valid <= 1'b1;
                pred_pixel <= shift_reg[PIXEL_WIDTH-1:0];
                if (out_x == 10'd3) begin
                    out_x <= 10'd0;
                    out_y <= out_y + 10'd1;
                end else begin
                    out_x <= out_x + 10'd1;
                end
                out_last <= (count == 5'd1);
            end else begin
                count <= 5'd0;
                pred_valid <= 1'b0;
                pred_pixel <= {PIXEL_WIDTH{1'b0}};
                out_last <= 1'b0;
            end
        end
    end

endmodule
