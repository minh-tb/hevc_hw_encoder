//=============================================================================
// pipeline_reg.v
// Generic Pipeline Register Stage
//
// Used throughout the encoder pipeline to:
//   1. Add registered pipeline stages between combinational blocks
//      (meets timing without manual flop insertion everywhere)
//   2. Carry sideband signals (valid, last, position) alongside data
//   3. Implement configurable pipeline depth (STAGES parameter)
//
// Used by:
//   dct_top.v       — tu_size_log2 / fwd_inv_n delay matching
//   fwd_quant.v     — QP/context sideband delay
//   recon_unit.v    — coordinate sideband through computation
//   Any module needing N-cycle registered delay on a bus
//
// Features:
//   - Fully registered (no combinational paths in output)
//   - Supports stall via en (pipeline enable, active high)
//     When en=0: all stages hold their current value
//   - Asynchronous reset to 0 (matches rst_n convention)
//   - Parameterizable width and depth
//
// Parameters:
//   WIDTH  — data bus width in bits
//   STAGES — number of pipeline stages (1 = single register)
//=============================================================================

`include "parameter_pkg.vh"

module pipeline_reg #(
    parameter WIDTH  = 1,
    parameter STAGES = 1
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             en,         // 1=advance, 0=stall (hold)

    input  wire [WIDTH-1:0] din,
    output wire [WIDTH-1:0] dout
);

    generate
        if (STAGES == 0) begin : gen_passthrough
            // Zero stages: wire through (purely combinational)
            assign dout = din;

        end else if (STAGES == 1) begin : gen_single
            reg [WIDTH-1:0] stage;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    stage <= {WIDTH{1'b0}};
                else if (en)
                    stage <= din;
            end

            assign dout = stage;

        end else begin : gen_multi
            // Shift register chain
            reg [WIDTH-1:0] stages [0:STAGES-1];
            integer si;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    for (si = 0; si < STAGES; si = si + 1)
                        stages[si] <= {WIDTH{1'b0}};
                end else if (en) begin
                    stages[0] <= din;
                    for (si = 1; si < STAGES; si = si + 1)
                        stages[si] <= stages[si-1];
                end
            end

            assign dout = stages[STAGES-1];
        end
    endgenerate

endmodule