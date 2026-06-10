//=============================================================================
// dct_top.v
// DCT/IDCT Dispatcher — Routes to dct4/8/16/32 by TU size
//
// Mapped from HM source:
//   TLibCommon/TComTrQuant.cpp  xTrMxN() / xITrMxN()
//   TLibEncoder/TEncSearch.cpp  xIntraSearchChroma() → calls xTrMxN
//
// HM routing logic (xTrMxN):
//   switch(iWidth) {
//     case  4: partialButterfly4 ();  break;
//     case  8: partialButterfly8 ();  break;
//     case 16: partialButterfly16();  break;
//     case 32: partialButterfly32();  break;
//   }
//   // Same switch for inverse (xITrMxN)
//
// Config constraints applied:
//   TU_LOG2_MAX = 5  → max TU = 32×32
//   TU_LOG2_MIN = 2  → min TU = 4×4
//   Valid tu_size_log2 values: 2,3,4,5
//
// Architecture:
//   All four DCT instances are permanently instantiated.
//   Input is steered to the correct instance via mux on in_valid.
//   Output is selected from the active instance.
//   Only ONE instance processes at any time (CTU pipeline sends
//   one TU at a time) — no arbitration needed.
//
//   Data path:
//     - 32-wide input array declared; smaller TUs use [0:N-1][0:N-1] slice
//     - Output registered in a 32×32 holding buffer, masked by tu_size
//
// Handshake:
//   in_valid/in_ready — standard from TU_INFO_BUS
//   out_valid/out_ready — downstream to quant_unit
//
// Pipeline latency: 2 cycles (same as individual DCT modules)
//=============================================================================

`include "parameter_pkg.vh"
`include "hevc_interfaces.vh"

module dct_top (
    input  wire         clk,
    input  wire         rst_n,

    // Control — from tu_info_if
    input  wire         fwd_inv_n,          // 1=forward, 0=inverse
    input  wire [2:0]   tu_size_log2,       // 2=4x4, 3=8x8, 4=16x16, 5=32x32

    // Input — max 32×32, smaller TUs packed in top-left
    // Matches TU_INFO_BUS: data arrives row-major
    input  wire         in_valid,
    output wire         in_ready,
    input  wire signed [`COEFF_WIDTH-1:0] in_data [0:31][0:31],

    // Output — max 32×32, smaller TUs valid in [0:N-1][0:N-1]
    output wire         out_valid,
    input  wire         out_ready,
    output wire signed [`COEFF_WIDTH-1:0] out_data [0:31][0:31],

    // Passthrough size info for downstream quant_unit
    output reg  [2:0]   out_tu_size_log2,
    output reg          out_fwd_inv_n
);

    //-------------------------------------------------------------------------
    // Size decode — one-hot active instance select
    //-------------------------------------------------------------------------
    wire sel4  = (tu_size_log2 == 3'd2);
    wire sel8  = (tu_size_log2 == 3'd3);
    wire sel16 = (tu_size_log2 == 3'd4);
    wire sel32 = (tu_size_log2 == 3'd5);

    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && in_valid) begin
            if (!sel4 && !sel8 && !sel16 && !sel32)
                $display("ERROR [dct_top] invalid tu_size_log2=%0d at time=%0t",
                         tu_size_log2, $time);
        end
    end
    // synthesis translate_on

    //-------------------------------------------------------------------------
    // Input steering — route in_valid to correct DCT instance only
    // in_data is shared (same bus width); each module only reads [0:N-1]
    //-------------------------------------------------------------------------
    wire in_valid4  = in_valid && sel4;
    wire in_valid8  = in_valid && sel8;
    wire in_valid16 = in_valid && sel16;
    wire in_valid32 = in_valid && sel32;

    //-------------------------------------------------------------------------
    // in_ready mux — only the active instance drives in_ready
    //-------------------------------------------------------------------------
    wire in_ready4, in_ready8, in_ready16, in_ready32;

    assign in_ready = (sel4)  ? in_ready4  :
                      (sel8)  ? in_ready8  :
                      (sel16) ? in_ready16 :
                      (sel32) ? in_ready32 :
                      1'b0;

    //-------------------------------------------------------------------------
    // 4×4 input slice — [0:3][0:3]
    //-------------------------------------------------------------------------
    wire signed [`COEFF_WIDTH-1:0] in4 [0:3][0:3];
    genvar gi, gj;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : gen_in4_row
            for (gj = 0; gj < 4; gj = gj + 1) begin : gen_in4_col
                assign in4[gi][gj] = in_data[gi][gj];
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // 8×8 input slice
    //-------------------------------------------------------------------------
    wire signed [`COEFF_WIDTH-1:0] in8 [0:7][0:7];
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : gen_in8_row
            for (gj = 0; gj < 8; gj = gj + 1) begin : gen_in8_col
                assign in8[gi][gj] = in_data[gi][gj];
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // 16×16 input slice
    //-------------------------------------------------------------------------
    wire signed [`COEFF_WIDTH-1:0] in16 [0:15][0:15];
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : gen_in16_row
            for (gj = 0; gj < 16; gj = gj + 1) begin : gen_in16_col
                assign in16[gi][gj] = in_data[gi][gj];
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // DCT4 instance
    //-------------------------------------------------------------------------
    wire                           out_valid4;
    wire signed [`COEFF_WIDTH-1:0] out4 [0:3][0:3];

    dct4 u_dct4 (
        .clk        (clk),
        .rst_n      (rst_n),
        .fwd_inv_n  (fwd_inv_n),
        .in_valid   (in_valid4),
        .in_ready   (in_ready4),
        .in_data    (in4),
        .out_valid  (out_valid4),
        .out_ready  (out_ready),
        .out_data   (out4)
    );

    //-------------------------------------------------------------------------
    // DCT8 instance
    //-------------------------------------------------------------------------
    wire                           out_valid8;
    wire signed [`COEFF_WIDTH-1:0] out8 [0:7][0:7];

    dct8 u_dct8 (
        .clk        (clk),
        .rst_n      (rst_n),
        .fwd_inv_n  (fwd_inv_n),
        .in_valid   (in_valid8),
        .in_ready   (in_ready8),
        .in_data    (in8),
        .out_valid  (out_valid8),
        .out_ready  (out_ready),
        .out_data   (out8)
    );

    //-------------------------------------------------------------------------
    // DCT16 instance
    //-------------------------------------------------------------------------
    wire                           out_valid16;
    wire signed [`COEFF_WIDTH-1:0] out16 [0:15][0:15];

    dct16 u_dct16 (
        .clk        (clk),
        .rst_n      (rst_n),
        .fwd_inv_n  (fwd_inv_n),
        .in_valid   (in_valid16),
        .in_ready   (in_ready16),
        .in_data    (in16),
        .out_valid  (out_valid16),
        .out_ready  (out_ready),
        .out_data   (out16)
    );

    //-------------------------------------------------------------------------
    // DCT32 instance — in_data[0:31][0:31] directly connected
    //-------------------------------------------------------------------------
    wire                           out_valid32;
    wire signed [`COEFF_WIDTH-1:0] out32 [0:31][0:31];

    dct32 u_dct32 (
        .clk        (clk),
        .rst_n      (rst_n),
        .fwd_inv_n  (fwd_inv_n),
        .in_valid   (in_valid32),
        .in_ready   (in_ready32),
        .in_data    (in_data),
        .out_valid  (out_valid32),
        .out_ready  (out_ready),
        .out_data   (out32)
    );

    //-------------------------------------------------------------------------
    // Output valid mux — only one asserts at a time
    //-------------------------------------------------------------------------
    assign out_valid = out_valid4 | out_valid8 | out_valid16 | out_valid32;

    //-------------------------------------------------------------------------
    // Output data mux
    // Smaller TUs write into [0:N-1][0:N-1], zeros elsewhere
    // out_tu_size_log2 is pipelined alongside data (2-cycle delay)
    //
    // Implementation: build 32×32 output combinationally from whichever
    // instance has out_valid asserted
    //-------------------------------------------------------------------------
    generate
        for (gi = 0; gi < 32; gi = gi + 1) begin : gen_out_row
            for (gj = 0; gj < 32; gj = gj + 1) begin : gen_out_col

                assign out_data[gi][gj] =
                    // DCT4 active: only [0:3][0:3] valid
                    (out_valid4  && gi < 4  && gj < 4)  ? out4 [gi][gj] :
                    // DCT8 active: only [0:7][0:7] valid
                    (out_valid8  && gi < 8  && gj < 8)  ? out8 [gi][gj] :
                    // DCT16 active: only [0:15][0:15] valid
                    (out_valid16 && gi < 16 && gj < 16) ? out16[gi][gj] :
                    // DCT32 active: full [0:31][0:31]
                    (out_valid32)                        ? out32[gi][gj] :
                    {`COEFF_WIDTH{1'b0}};

            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // Pipeline: tu_size_log2 and fwd_inv_n delayed 2 cycles to match
    // DCT output latency — identical to fwd_inv_n_s1 pattern in each DCT
    //-------------------------------------------------------------------------
    reg [2:0] size_pipe [0:1];
    reg       dir_pipe  [0:1];

    always @(posedge clk) begin
        if (!rst_n) begin
            stage1_valid <= 1'b0;
            size_s1      <= 3'd2;
            dir_s1       <= 1'b1;
        end else if (!stall) begin
            stage1_valid <= in_valid;
            if (in_valid) begin
                size_s1 <= tu_size_log2;
                dir_s1  <= fwd_inv_n;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            out_tu_size_log2 <= 3'd2;
            out_fwd_inv_n    <= 1'b1;
        end else if (!out_ready) begin
            // Hold state (implicit, explicitly captured by not being in else)
        end else begin
            if (stage1_valid) begin
                out_tu_size_log2 <= size_s1;
                out_fwd_inv_n    <= dir_s1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Simulation: warn if multiple out_valid asserted simultaneously
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n) begin
            if ((out_valid4 + out_valid8 + out_valid16 + out_valid32) > 1)
                $display("ERROR [dct_top] multiple out_valid at time=%0t", $time);
        end
    end
    // synthesis translate_on

endmodule