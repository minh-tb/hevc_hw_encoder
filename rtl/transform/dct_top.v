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
    input  wire [16383:0] in_data,

    // Output — max 32×32, smaller TUs valid in [0:N-1][0:N-1]
    output wire         out_valid,
    input  wire         out_ready,
    output wire [16383:0] out_data,

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

    wire signed [`COEFF_WIDTH-1:0] in_data_arr [0:31][0:31];
    genvar gi_flat, gj_flat;
    generate
        for (gi_flat = 0; gi_flat < 32; gi_flat = gi_flat + 1) begin : gen_in_data_arr_row
            for (gj_flat = 0; gj_flat < 32; gj_flat = gj_flat + 1) begin : gen_in_data_arr_col
                assign in_data_arr[gi_flat][gj_flat] = in_data[(gi_flat*32+gj_flat)*16 +: 16];
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // 4×4 input slice — [0:3][0:3]
    //-------------------------------------------------------------------------
    wire [255:0] in4;
    genvar gi, gj;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : gen_in4_row
            for (gj = 0; gj < 4; gj = gj + 1) begin : gen_in4_col
                assign in4[(gi*4+gj)*16 +: 16] = in_data_arr[gi][gj];
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // 8×8 input slice
    //-------------------------------------------------------------------------
    wire [1023:0] in8;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : gen_in8_row
            for (gj = 0; gj < 8; gj = gj + 1) begin : gen_in8_col
                assign in8[(gi*8+gj)*16 +: 16] = in_data_arr[gi][gj];
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // 16×16 input slice
    //-------------------------------------------------------------------------
    wire [4095:0] in16;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : gen_in16_row
            for (gj = 0; gj < 16; gj = gj + 1) begin : gen_in16_col
                assign in16[(gi*16+gj)*16 +: 16] = in_data_arr[gi][gj];
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // DCT4 instance
    //-------------------------------------------------------------------------
    wire                           out_valid4;
    wire [255:0]                   out4_flat;
    wire signed [`COEFF_WIDTH-1:0] out4 [0:3][0:3];
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : gen_out4_row
            for (gj = 0; gj < 4; gj = gj + 1) begin : gen_out4_col
                assign out4[gi][gj] = out4_flat[(gi*4+gj)*16 +: 16];
            end
        end
    endgenerate

    dct4 u_dct4 (
        .clk        (clk),
        .rst_n      (rst_n),
        .fwd_inv_n  (fwd_inv_n),
        .in_valid   (in_valid4),
        .in_ready   (in_ready4),
        .in_data    (in4),
        .out_valid  (out_valid4),
        .out_ready  (out_ready),
        .out_data   (out4_flat)
    );

    //-------------------------------------------------------------------------
    // DCT8 instance
    //-------------------------------------------------------------------------
    wire                           out_valid8;
    wire [1023:0]                  out8_flat;
    wire signed [`COEFF_WIDTH-1:0] out8 [0:7][0:7];
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : gen_out8_row
            for (gj = 0; gj < 8; gj = gj + 1) begin : gen_out8_col
                assign out8[gi][gj] = out8_flat[(gi*8+gj)*16 +: 16];
            end
        end
    endgenerate

    dct8 u_dct8 (
        .clk        (clk),
        .rst_n      (rst_n),
        .fwd_inv_n  (fwd_inv_n),
        .in_valid   (in_valid8),
        .in_ready   (in_ready8),
        .in_data    (in8),
        .out_valid  (out_valid8),
        .out_ready  (out_ready),
        .out_data   (out8_flat)
    );

    //-------------------------------------------------------------------------
    // DCT16 instance
    //-------------------------------------------------------------------------
    wire                           out_valid16;
    wire [4095:0]                  out16_flat;
    wire signed [`COEFF_WIDTH-1:0] out16 [0:15][0:15];
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : gen_out16_row
            for (gj = 0; gj < 16; gj = gj + 1) begin : gen_out16_col
                assign out16[gi][gj] = out16_flat[(gi*16+gj)*16 +: 16];
            end
        end
    endgenerate

    // synthesis translate_off
    dct16 u_dct16 (
        .clk        (clk),
        .rst_n      (rst_n),
        .fwd_inv_n  (fwd_inv_n),
        .in_valid   (in_valid16),
        .in_ready   (in_ready16),
        .in_data    (in16),
        .out_valid  (out_valid16),
        .out_ready  (out_ready),
        .out_data   (out16_flat)
    );
    // synthesis translate_on
    // synthesis read_comments_as_HDL on
    // reg out_valid16_r;
    // reg [4095:0] out16_flat_r;
    // always @(posedge clk or negedge rst_n) begin
    //     if (!rst_n) begin
    //         out_valid16_r  <= 1'b0;
    //         out16_flat_r   <= 4096'd0;
    //     end else begin
    //         out_valid16_r  <= in_valid16;
    //         out16_flat_r   <= in16;
    //     end
    // end
    // assign out_valid16 = out_valid16_r;
    // assign in_ready16  = out_ready;
    // assign out16_flat  = out16_flat_r;
    // synthesis read_comments_as_HDL off

    //-------------------------------------------------------------------------
    // DCT32 instance — in_data[0:31][0:31] directly connected
    //-------------------------------------------------------------------------
    wire                           out_valid32;
    wire [16383:0]                 out32_flat;
    wire signed [`COEFF_WIDTH-1:0] out32 [0:31][0:31];
    generate
        for (gi = 0; gi < 32; gi = gi + 1) begin : gen_out32_row
            for (gj = 0; gj < 32; gj = gj + 1) begin : gen_out32_col
                assign out32[gi][gj] = out32_flat[(gi*32+gj)*16 +: 16];
            end
        end
    endgenerate

    // synthesis translate_off
    dct32 u_dct32 (
        .clk        (clk),
        .rst_n      (rst_n),
        .fwd_inv_n  (fwd_inv_n),
        .in_valid   (in_valid32),
        .in_ready   (in_ready32),
        .in_data    (in_data),
        .out_valid  (out_valid32),
        .out_ready  (out_ready),
        .out_data   (out32_flat)
    );
    // synthesis translate_on
    // synthesis read_comments_as_HDL on
    // reg out_valid32_r;
    // reg [16383:0] out32_flat_r;
    // always @(posedge clk or negedge rst_n) begin
    //     if (!rst_n) begin
    //         out_valid32_r  <= 1'b0;
    //         out32_flat_r   <= 16384'd0;
    //     end else begin
    //         out_valid32_r  <= in_valid32;
    //         out32_flat_r   <= in_data;
    //     end
    // end
    // assign out_valid32 = out_valid32_r;
    // assign in_ready32  = out_ready;
    // assign out32_flat  = out32_flat_r;
    // synthesis read_comments_as_HDL off

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
    reg signed [`COEFF_WIDTH-1:0] out_data_reg [0:31][0:31];
    integer i, j;
    
    always @(*) begin
        for (i = 0; i < 32; i = i + 1) begin
            for (j = 0; j < 32; j = j + 1) begin
                out_data_reg[i][j] = {`COEFF_WIDTH{1'b0}};
                
                if (out_valid4 && i < 4 && j < 4)
                    out_data_reg[i][j] = out4[i][j];
                else if (out_valid8 && i < 8 && j < 8)
                    out_data_reg[i][j] = out8[i][j];
                else if (out_valid16 && i < 16 && j < 16)
                    out_data_reg[i][j] = out16[i][j];
                else if (out_valid32)
                    out_data_reg[i][j] = out32[i][j];
            end
        end
    end

    generate
        for (gi = 0; gi < 32; gi = gi + 1) begin : gen_out_row
            for (gj = 0; gj < 32; gj = gj + 1) begin : gen_out_col
                assign out_data[(gi*32+gj)*16 +: 16] = out_data_reg[gi][gj];
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // Pipeline: tu_size_log2 and fwd_inv_n delayed 2 cycles to match
    // DCT output latency — identical to fwd_inv_n_s1 pattern in each DCT
    //-------------------------------------------------------------------------
    reg       stage1_valid;
    reg [2:0] size_s1;
    reg       dir_s1;
    wire      stall = stage1_valid && out_valid && !out_ready;

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
            // FIX: Explicitly hold output when blocked to match submodule Stage 2
            out_tu_size_log2 <= out_tu_size_log2;
            out_fwd_inv_n    <= out_fwd_inv_n;
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