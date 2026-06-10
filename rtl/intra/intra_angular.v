//=============================================================================
// intra_angular.v
// Intra Angular Prediction — All 33 Directional Modes (2..34)
//
// Mapped from HM source:
//   TLibCommon/TComPrediction.cpp
//   Void TComPrediction::xPredIntraAng()
//
// HEVC spec: Section 8.4.4.2.6 (Angular prediction)
//
// Algorithm overview:
//   1. Classify mode as vertical-like (mode >= 18) or horizontal-like (mode <= 17)
//   2. Select main reference: top row for vertical, left col for horizontal
//   3. For negative-angle modes: extend main reference using side reference
//      (invAngle table used to project side ref into extended negative region)
//   4. For each pixel (x,y) compute:
//        deltaPos = (y+1) * intraPredAngle           [vertical mode]
//        or deltaPos = (x+1) * intraPredAngle        [horizontal mode]
//        refIdx = (deltaPos >> 5) + x + 1            [vertical mode]
//        frac   = deltaPos & 31
//        pred   = ((32-frac)*ref[refIdx] + frac*ref[refIdx+1] + 16) >> 5
//   5. For horizontal modes: transpose output
//
// intraPredAngle table (HEVC spec Table 8-1, indexed by mode-2):
//   mode: 2  3  4  5  6  7  8  9 10 11 12 13 14 15 16 17 18
//   ang: 32 26 21 17 13  9  5  2  0 -2 -5 -9-13-17-21-26-32
//   mode:19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34
//   ang:-26-21-17-13 -9 -5 -2  0  2  5  9 13 17 21 26 32
//
// invAngle table (for reference extension, indexed by |angle|-1 for angle 2..32):
//   |ang|: 2     5     9    13    17    21    26    32
//   inv: 4096  1638   910   630   482   390   315   256
//
// Reference buffer layout (from ref_sample_filter output):
//   ref[0]        = corner p[-1][-1]
//   ref[1..2N]    = top row  p[-1][0..2N-1]  (left to right)
//   ref[2N+1..4N] = left col p[0..2N-1][-1]  (top to bottom)
//
// Extended reference buffer:
//   For vertical modes with negative angle: refExt[-N..2N]
//   For horizontal modes: symmetric treatment via transpose
//
// Pipeline:
//   Stage 1: Buffer reference samples (4N+1 cycles)
//   Stage 2: Extend reference if needed (N cycles max)
//   Stage 3: Output N×N pixels (N² cycles, one per cycle)
//
// Note on transposition for horizontal modes (2..17):
//   HM transposes the block computation: treats horizontal mode as vertical
//   by swapping x↔y indices in reference access and output coordinates.
//   Hardware: compute same way as vertical but swap out_x/out_y at output.
//=============================================================================

`include "parameter_pkg.vh"

module intra_angular (
    input  wire         clk,
    input  wire         rst_n,

    // PU context
    input  wire [2:0]   pu_size_log2,
    input  wire [5:0]   intra_mode,     // 2..34
    input  wire         is_luma,        // 1=luma (enables edge filter)

    // Reference samples from ref_sample_filter (serial, ref[0..4N])
    input  wire         in_valid,
    output wire         in_ready,
    input  wire [`PIXEL_WIDTH-1:0] in_sample,
    input  wire [7:0]   in_idx,
    input  wire         in_last,

    // Predicted pixel output (row-major, N×N)
    output reg          out_valid,
    input  wire         out_ready,
    output reg  [`PIXEL_WIDTH-1:0] out_pixel,
    output reg  [5:0]   out_x,
    output reg  [5:0]   out_y,
    output reg          out_last
);

    //-------------------------------------------------------------------------
    // PU size
    //-------------------------------------------------------------------------
    wire [5:0] N      = 6'd1 << pu_size_log2;   // 4,8,16,32
    wire [7:0] N_w    = {2'b0, N};
    wire [7:0] N2_w   = {1'b0, N, 1'b0};        // 2N

    //-------------------------------------------------------------------------
    // intraPredAngle LUT — HEVC spec Table 8-1
    // Indexed by (intra_mode - 2), range 0..32 for modes 2..34
    // Signed 7-bit: range -32..32 (requires 7 bits to store +32)
    //-------------------------------------------------------------------------
    function automatic signed [6:0] pred_angle;
        input [5:0] mode;
        case (mode)
            6'd2:  pred_angle =  7'sd32; 6'd3:  pred_angle =  7'sd26;
            6'd4:  pred_angle =  7'sd21; 6'd5:  pred_angle =  7'sd17;
            6'd6:  pred_angle =  7'sd13; 6'd7:  pred_angle =   7'sd9;
            6'd8:  pred_angle =   7'sd5; 6'd9:  pred_angle =   7'sd2;
            6'd10: pred_angle =   7'sd0; 6'd11: pred_angle =  -7'sd2;
            6'd12: pred_angle =  -7'sd5; 6'd13: pred_angle =  -7'sd9;
            6'd14: pred_angle = -7'sd13; 6'd15: pred_angle = -7'sd17;
            6'd16: pred_angle = -7'sd21; 6'd17: pred_angle = -7'sd26;
            6'd18: pred_angle = -7'sd32; 6'd19: pred_angle = -7'sd26;
            6'd20: pred_angle = -7'sd21; 6'd21: pred_angle = -7'sd17;
            6'd22: pred_angle = -7'sd13; 6'd23: pred_angle =  -7'sd9;
            6'd24: pred_angle =  -7'sd5; 6'd25: pred_angle =  -7'sd2;
            6'd26: pred_angle =   7'sd0; 6'd27: pred_angle =   7'sd2;
            6'd28: pred_angle =   7'sd5; 6'd29: pred_angle =   7'sd9;
            6'd30: pred_angle =  7'sd13; 6'd31: pred_angle =  7'sd17;
            6'd32: pred_angle =  7'sd21; 6'd33: pred_angle =  7'sd26;
            6'd34: pred_angle =  7'sd32;
            default: pred_angle = 7'sd0;
        endcase
    endfunction

    //-------------------------------------------------------------------------
    // invAngle LUT — for reference extension
    // Used when angle < 0 (modes needing cross-reference)
    // invAngle[mode] = round(256/|angle_radians|) approximately
    // Only non-zero for modes with |angle| >= 2
    // HEVC spec Table 8-1
    //-------------------------------------------------------------------------
    function automatic [12:0] inv_angle;
        input [5:0] mode;
        case (mode)
            // Modes 2..9 (angles 32,26,21,17,13,9,5,2)
            6'd2:  inv_angle = 13'd256;  6'd3:  inv_angle = 13'd315;
            6'd4:  inv_angle = 13'd390;  6'd5:  inv_angle = 13'd482;
            6'd6:  inv_angle = 13'd630;  6'd7:  inv_angle = 13'd910;
            6'd8:  inv_angle = 13'd1638; 6'd9:  inv_angle = 13'd4096;
            // Modes 27..34 (same invAngle as mirrored modes 9..2)
            6'd27: inv_angle = 13'd4096; 6'd28: inv_angle = 13'd1638;
            6'd29: inv_angle = 13'd910;  6'd30: inv_angle = 13'd630;
            6'd31: inv_angle = 13'd482;  6'd32: inv_angle = 13'd390;
            6'd33: inv_angle = 13'd315;  6'd34: inv_angle = 13'd256;
            // Modes 11..17 and 19..25 (negative main angle → need extension)
            6'd11: inv_angle = 13'd4096; 6'd12: inv_angle = 13'd1638;
            6'd13: inv_angle = 13'd910;  6'd14: inv_angle = 13'd630;
            6'd15: inv_angle = 13'd482;  6'd16: inv_angle = 13'd390;
            6'd17: inv_angle = 13'd315;  6'd18: inv_angle = 13'd256;
            6'd19: inv_angle = 13'd315;  6'd20: inv_angle = 13'd390;
            6'd21: inv_angle = 13'd482;  6'd22: inv_angle = 13'd630;
            6'd23: inv_angle = 13'd910;  6'd24: inv_angle = 13'd1638;
            6'd25: inv_angle = 13'd4096;
            default: inv_angle = 13'd0;
        endcase
    endfunction

    //-------------------------------------------------------------------------
    // Mode classification
    // bIsVertical = (mode >= 18) — uses top row as main reference
    // Horizontal modes (2..17) use left col as main reference
    // For hardware: always compute as vertical, transpose output if horizontal
    //-------------------------------------------------------------------------
    wire is_vertical    = (intra_mode >= 6'd18);
    wire needs_ext      = (pred_angle(intra_mode) < 7'sd0);  // negative angle needs extension

    //-------------------------------------------------------------------------
    // Reference sample buffers
    // refMain[0..2N]:   main reference (top for vertical, left for horizontal)
    //                   index 0 = corner, 1..2N = main row/col
    // refSide[0..2N]:   side reference (left for vertical, top for horizontal)
    //                   used only for extension
    // refExt[-N..2N]:   extended main reference (built during extend phase)
    //                   stored as refExt[0..3N] with offset N
    //                   refExt[N+i] = refMain[i] for i=0..2N
    //                   refExt[N-1..0] = extended region
    //-------------------------------------------------------------------------
    reg [`PIXEL_WIDTH-1:0] refMain [0:64];   // main ref: index 0..2N (max 65)
    reg [`PIXEL_WIDTH-1:0] refSide [0:64];   // side ref: index 0..2N (max 65)
    reg [`PIXEL_WIDTH-1:0] refExt  [0:127];  // extended: safe bounds up to 4N
    //                                         index 0 = refMain[-N], N = refMain[0]

    //-------------------------------------------------------------------------
    // State machine
    //-------------------------------------------------------------------------
    localparam S_BUF    = 2'd0;  // buffering reference samples
    localparam S_EXTEND = 2'd1;  // building extended reference
    localparam S_OUTPUT = 2'd2;  // outputting pixels

    reg [1:0] state;

    //-------------------------------------------------------------------------
    // Extension build — combinational, registered into refExt on S_EXTEND
    //
    // refExt[N + i] = refMain[i]  for i = 0..2N
    // refExt[N-1-i] = refSide[((i+1)*invAngle + 128) >> 8 - 1]  (clipped to 0..2N)
    //                 for i = 0..N-1 (only when needs_ext)
    //
    // invAngle lookup for current mode
    //-------------------------------------------------------------------------
    wire [12:0] cur_inv_angle = inv_angle(intra_mode);

    //-------------------------------------------------------------------------
    // Reference sample fill
    //-------------------------------------------------------------------------
    assign in_ready = (state == S_BUF);
    wire fire_in = in_valid && in_ready;

    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_BUF;
            for (k = 0; k <= 64; k = k + 1) begin
                refMain[k] <= {`PIXEL_WIDTH{1'b0}};
                refSide[k] <= {`PIXEL_WIDTH{1'b0}};
            end
            for (k = 0; k <= 127; k = k + 1)
                refExt[k] <= {`PIXEL_WIDTH{1'b0}};
        end else begin
            case (state)
                //--------------------------------------------------------------
                // Buffer all 4N+1 reference samples
                // For vertical modes:
                //   refMain = top row:   ref[0..2N]   (corner + 2N top samples)
                //   refSide = left col:  ref[2N..4N]  (corner + 2N left samples)
                //             note: corner at both ends
                // For horizontal modes: swap main/side
                //--------------------------------------------------------------
                S_BUF: begin
                    if (fire_in) begin
                        if (is_vertical) begin
                            // Main: ref[0..2N] = corner + top row
                            if (in_idx <= N2_w)
                                refMain[in_idx] <= in_sample;
                            // Side: ref[2N..4N] = corner + left col
                            // Note: ref[2N] = last top = corner of top-right,
                            // but HM side ref starts at corner ref[0]
                            // Side ref[0] = ref[0] (corner), side ref[1..2N] = ref[2N+1..4N]
                            if (in_idx == 8'd0)
                                refSide[0] <= in_sample;
                            else if (in_idx > N2_w)
                                refSide[in_idx - N2_w] <= in_sample;
                        end else begin
                            // Horizontal: swap main and side
                            // Main: left col  = ref[2N+1..4N] → refMain[1..2N]
                            //       plus corner ref[0] → refMain[0]
                            if (in_idx == 8'd0)
                                refMain[0] <= in_sample;
                            else if (in_idx > N2_w)
                                refMain[in_idx - N2_w] <= in_sample;
                            // Side: top row = ref[0..2N]
                            if (in_idx <= N2_w)
                                refSide[in_idx] <= in_sample;
                        end

                        if (in_last) begin
                            if (needs_ext)
                                state <= S_EXTEND;
                            else begin
                                // Copy refMain to refExt with offset N
                                state <= S_EXTEND; // always go through extend to copy
                            end
                        end
                    end
                end

                //--------------------------------------------------------------
                // Build extended reference into refExt
                // refExt[N + i] = refMain[i]  for i = 0..2N
                // For negative angle modes, also fill refExt[N-1..0]
                // using: refExt[N-1-i] = refSide[((i+1)*invAngle+128)>>8]
                //                                              for i=0..N-1
                //--------------------------------------------------------------
                S_EXTEND: begin
                    for (k = 0; k <= 64; k = k + 1) begin
                        if (k <= N2_w)
                            refExt[N_w + k[7:0]] <= refMain[k];
                    end
                    if (needs_ext) begin
                        for (k = 0; k < 32; k = k + 1) begin
                            if (k < N) begin
                                refExt[N_w - 8'd1 - k[7:0]] <= refSide[ ((((k + 1) * cur_inv_angle + 128) >> 8) > N_w) ? N_w : (((k + 1) * cur_inv_angle + 128) >> 8) ];
                            end
                        end
                    end
                    state <= S_OUTPUT;
                end

                S_OUTPUT: begin
                    if (out_last && out_valid && out_ready)
                        state <= S_BUF;
                end
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // Output FSM — compute and stream N×N pixels
    //
    // For each pixel position (px, py):
    //   Vertical mode:
    //     deltaPos = (py+1) * angle                 [signed multiply]
    //     iIdx     = px + (deltaPos >> 5)           [integer part of projection]
    //     frac     = deltaPos & 31                  [fractional part, 0..31]
    //     refAccess= refExt[N + 1 + iIdx]           [apply N offset + 1 for pSrc[1]]
    //
    //   pred = frac==0 ? ref[refAccess]
    //              : ((32-frac)*ref[refAccess] + frac*ref[refAccess+1] + 16) >> 5
    //
    // For horizontal mode: swap px↔py in deltaPos calculation,
    //   and swap out_x/out_y at output register
    //
    // Pure horizontal/vertical modes (angle=0): pred = refMain[px+1 or py+1]
    //-------------------------------------------------------------------------
    reg [5:0] px;
    reg [5:0] py;

    wire signed [6:0]  angle     = pred_angle(intra_mode);
    wire               pure_mode = (angle == 7'sd0);

    // Transpose is handled cleanly by mapping out_x=py, out_y=px later
    wire [5:0]  delta_driver  = py;
    wire [5:0]  ref_selector  = px;

    // deltaPos = (delta_driver+1) * angle  — signed multiply, 14-bit result
    // angle range: -32..32 (7-bit signed)
    // delta_driver+1 range: 1..32 (7-bit signed)
    // product range: -1024..1024 → 14-bit signed
    wire signed [13:0] deltaPos = $signed({1'b0, delta_driver + 6'd1}) * angle;

    // Integer part of displacement (arithmetic right shift by 5)
    wire signed [8:0]  iDeltaInt = deltaPos >>> 5;   // signed >>5

    // Fractional part (0..31)
    wire [4:0]  frac     = deltaPos[4:0];             // low 5 bits
    wire        is_int   = (frac == 5'd0);            // no interpolation needed

    // Reference index into refExt
    // refExt is centered at N (refMain[0] = refExt[N])
    // pSrc[0] = refMain[0] = refExt[N] = corner
    // pSrc[1] = refMain[1] = refExt[N+1] = first active sample
    // For vertical mode: access pSrc[x + iDeltaInt + 1]
    //   = refExt[N + 1 + x + iDeltaInt]
    wire signed [9:0] base_idx  = $signed({2'b0, N_w}) + 10'sd1 +
                                   $signed({4'b0, ref_selector}) +
                                   $signed({{1{iDeltaInt[8]}}, iDeltaInt});
    wire [7:0]  ref_idx0 = base_idx[7:0];
    wire [7:0]  ref_idx1 = base_idx[7:0] + 8'd1;

    // Reference sample read
    wire [`PIXEL_WIDTH-1:0] s0 = refExt[ref_idx0];
    wire [`PIXEL_WIDTH-1:0] s1 = refExt[ref_idx1];

    // Pure horizontal/vertical edge filtering (Luma only, N<32, x=0 or y=0)
    wire apply_edge_filter = is_luma && (pu_size_log2 < 3'd5) && pure_mode && (px == 6'd0);
    wire signed [11:0] edge_diff = $signed({1'b0, refSide[py + 6'd1]}) - $signed({1'b0, refSide[0]});
    wire signed [11:0] edge_val  = $signed({1'b0, refMain[1]}) + (edge_diff >>> 1);
    wire [`PIXEL_WIDTH-1:0] edge_pred = (edge_val < 0) ? {`PIXEL_WIDTH{1'b0}} :
                                        (edge_val > ((1<<`PIXEL_WIDTH)-1)) ? ((1<<`PIXEL_WIDTH)-1) :
                                        edge_val[`PIXEL_WIDTH-1:0];

    wire [`PIXEL_WIDTH-1:0] pure_pred = apply_edge_filter ? edge_pred : refMain[{2'b0, ref_selector} + 8'd1];

    // Fractional interpolation: ((32-frac)*s0 + frac*s1 + 16) >> 5
    wire [14:0] interp_sum = {5'b0, (6'd32 - {1'b0, frac})} * {5'b0, s0} +
                              {5'b0, {1'b0, frac}}           * {5'b0, s1} +
                              15'd16;
    wire [`PIXEL_WIDTH-1:0] interp_pred = interp_sum[14:5];  // >> 5

    wire [`PIXEL_WIDTH-1:0] ang_pred = pure_mode ? pure_pred :
                                        is_int    ? s0        :
                                        interp_pred;

    //-------------------------------------------------------------------------
    // Output register
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_pixel <= {`PIXEL_WIDTH{1'b0}};
            out_x     <= 6'd0;
            out_y     <= 6'd0;
            out_last  <= 1'b0;
            px        <= 6'd0;
            py        <= 6'd0;
        end else if (state == S_OUTPUT) begin
            if (out_ready || !out_valid) begin
                if (out_last && out_valid) begin
                    out_valid <= 1'b0;
                    out_last  <= 1'b0;
                end else begin
                    out_valid <= 1'b1;
                    out_pixel <= ang_pred;

                    // Horizontal modes: transpose output coordinates
                    out_x     <= is_vertical ? px : py;
                    out_y     <= is_vertical ? py : px;
                    out_last  <= (px == N - 6'd1) && (py == N - 6'd1);

                    // Raster scan advance
                    if (px == N - 6'd1) begin
                        px <= 6'd0;
                        py <= py + 6'd1;
                    end else begin
                        px <= px + 6'd1;
                    end

                    if ((px == N - 6'd1) && (py == N - 6'd1)) begin
                        px <= 6'd0;
                        py <= 6'd0;
                    end
                end
            end
        end else begin
            out_valid <= 1'b0;
            px <= 6'd0;
            py <= 6'd0;
        end
    end

    //-------------------------------------------------------------------------
    // Simulation checks
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && in_valid && !in_ready)
            $display("WARN  [intra_angular] stall mode=%0d size=%0d time=%0t",
                     intra_mode, pu_size_log2, $time);
        if (rst_n && fire_in && in_last)
            $display("INFO  [intra_angular] refs buffered mode=%0d N=%0d angle=%0d",
                     intra_mode, N, pred_angle(intra_mode));
    end
    // synthesis translate_on

endmodule