//=============================================================================
// clk_gate.v
// Clock Gating Cell Wrapper — Integrated Clock Gate (ICG)
//
// Used throughout the encoder to reduce dynamic power by disabling
// clock to idle pipeline stages.
//
// Key usage sites:
//   dct4/8/16/32.v  — gate clock when no valid data in pipeline
//   intra_pred_top  — gate inactive predictor instances
//   me_top.v        — gate ME when processing intra CTUs
//   cabac_enc_top   — gate CABAC when no bins pending
//
// Architecture:
//   Latch-based ICG (industry standard):
//     1. Enable is latched on falling clock edge (avoids glitches)
//     2. Gated clock = latched_enable AND clock
//
//   FPGA target:
//     On Xilinx/Intel FPGAs, clock gating is implemented via
//     clock enable (CE) inputs on flip-flops, NOT by gating the clock.
//     On FPGAs: this module instantiates a simple AND gate, and the
//     synthesis tool converts it to CE signals automatically.
//     The (* keep *) attribute prevents the AND from being optimised away.
//
// Ports:
//   clk_in   — ungated clock
//   enable   — active-high enable (from functional logic)
//   test_en  — scan test enable (always pass clock in test mode)
//   clk_out  — gated clock output
//
// Timing:
//   enable must be stable BEFORE the falling edge of clk_in
//   (setup time on the latch). This is a standard ICG constraint.
//=============================================================================

module clk_gate (
    input  wire clk_in,
    input  wire enable,
    input  wire test_en,   // scan enable — bypass gate in test mode
    output wire clk_out
);

    //-------------------------------------------------------------------------
    // FPGA: simple AND — synthesis tool converts to flip-flop CE inputs
    // (* keep *) prevents AND from being merged into other logic
    //-------------------------------------------------------------------------
    (* keep = "true" *)
    assign clk_out = clk_in & (enable | test_en);

    //-------------------------------------------------------------------------
    // Simulation assertion: enable must not change while clk_in=1
    // (setup/hold violation on the ICG latch)
    //-------------------------------------------------------------------------
    // synthesis translate_off
    reg prev_enable;
    always @(posedge clk_in) prev_enable <= enable;

    always @(enable) begin
        if (clk_in === 1'b1 && enable !== prev_enable)
            $display("WARN  [clk_gate] enable toggled while clk_in=1 at time=%0t — ICG glitch risk",
                     $time);
    end
    // synthesis translate_on

endmodule