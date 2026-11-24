`timescale 1ns / 1ps
`include "parameter_pkg.vh"

module coeff_buffer #(
    parameter DATA_W = 16,
    parameter DEPTH  = 4096,
    parameter ADDR_W = 12
)(
    input  wire              clk,
    
    // Even write port (scan_idx[0] == 0, from Quantizer Lane 0)
    input  wire              we0,
    input  wire [ADDR_W-2:0] waddr0,
    input  wire [DATA_W-1:0] wdata0,

    // Odd write port (scan_idx[0] == 1, from Quantizer Lane 1)
    input  wire              we1,
    input  wire [ADDR_W-2:0] waddr1,
    input  wire [DATA_W-1:0] wdata1,
    
    // Read port (to CABAC / CG Assembler)
    input  wire              re,
    input  wire [ADDR_W-1:0] raddr,
    output wire [DATA_W-1:0] rdata
);

    (* ramstyle = "M10K, no_rw_check", ram_style = "block" *) reg [DATA_W-1:0] mem_even [0:(DEPTH/2)-1];
    (* ramstyle = "M10K, no_rw_check", ram_style = "block" *) reg [DATA_W-1:0] mem_odd  [0:(DEPTH/2)-1];
`ifndef SYNTHESIS
    integer cb_i;
    initial begin
        for (cb_i = 0; cb_i < (DEPTH/2); cb_i = cb_i + 1) begin
            mem_even[cb_i] = {DATA_W{1'b0}};
            mem_odd[cb_i]  = {DATA_W{1'b0}};
        end
    end
`endif

    reg [DATA_W-1:0] rdata_even_q, rdata_odd_q;
    reg              raddr_lsb_q;

    always @(posedge clk) begin
        if (we0) begin
            mem_even[waddr0] <= wdata0;
        end
        if (we1) begin
            mem_odd[waddr1] <= wdata1;
        end
        if (re) begin
            rdata_even_q <= mem_even[raddr[ADDR_W-1:1]];
            rdata_odd_q  <= mem_odd[raddr[ADDR_W-1:1]];
            raddr_lsb_q  <= raddr[0];
        end
    end

    assign rdata = raddr_lsb_q ? rdata_odd_q : rdata_even_q;

endmodule
