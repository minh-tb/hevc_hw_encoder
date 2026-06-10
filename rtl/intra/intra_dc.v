//=============================================================================
// intra_dc.v
// Intra DC Prediction
//
// Mapped from HM source:
//   TLibCommon/TComPrediction.cpp
//   Void TComPrediction::xDCPredFiltering()   — post-prediction DC filter
//   predIntraAng() MODE_DC path               — DC value computation
//
// HEVC spec: Section 8.4.4.2.1 (DC prediction)
//
// Algorithm:
//   1. Compute DC value = average of 2N reference samples
//      dcVal = (sum(top[0..N-1]) + sum(left[0..N-1]) + N) / (2N)
//            = (sum_top + sum_left + N) >> (log2(N) + 1)
//      Note: only FIRST N samples of top row and left col used (not 2N)
//
//   2. Fill entire N×N prediction block with dcVal
//
//   3. Apply DC filter on top row and left column of prediction block
//      (luma only, not chroma, only for N < 32 per HEVC Spec)
//      predSamples[x][0] = (p[-1][0] + 3*dcVal + 2) >> 2   for x=0
//      predSamples[0][y] = (p[0][-1] + 3*dcVal + 2) >> 2   for y=0
//      predSamples[0][0] = (p[-1][0] + p[0][-1] + 2*dcVal + 2) >> 2
//
// Reference sample indexing (matches ref_sample_filter output):
//   ref[0]        = corner p[-1][-1]
//   ref[1..2N]    = top row  p[-1][0..2N-1]  (only first N used for DC)
//   ref[2N+1..4N] = left col p[0..2N-1][-1]  (only first N used for DC)
//
// Pipeline:
//   Stage 1: Accumulate sum_top and sum_left (N cycles each, run in parallel)
//   Stage 2: Compute dcVal (1 cycle: sum >> (log2N+1))
//   Stage 3: Output N×N pixels with DC filter on borders (N² cycles)
//   Latency: N + 1 + N² cycles
//   For N=32: 32 + 1 + 1024 = 1057 cycles (acceptable — one TU per ~1K cycles)
//=============================================================================

`include "parameter_pkg.vh"

module intra_dc (
    input  wire         clk,
    input  wire         rst_n,

    // PU context
    input  wire [2:0]   pu_size_log2,   // 2=4×4 .. 5=32×32
    input  wire         is_luma,        // 1=luma (enables DC filter)

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
    output reg  [5:0]   out_x,          // pixel x within PU (0..N-1)
    output reg  [5:0]   out_y,          // pixel y within PU (0..N-1)
    output reg          out_last        // last pixel of PU
);

    //-------------------------------------------------------------------------
    // PU size decode
    //-------------------------------------------------------------------------
    wire [5:0] N         = 6'd1 << pu_size_log2;   // 4,8,16,32
    wire [7:0] ref_count = {1'b0, N, 2'b0} + 8'd1; // 4N+1
    wire [7:0] N2        = {1'b0, N, 1'b0};         // 2N (first top ref idx end)
    // First N top samples: ref[1..N]
    // First N left samples: ref[2N+1..3N]

    //-------------------------------------------------------------------------
    // State machine
    //-------------------------------------------------------------------------
    localparam S_REF_ACC  = 2'd0;  // accumulating reference samples
    localparam S_DC_CALC  = 2'd1;  // computing DC value (1 cycle)
    localparam S_OUTPUT   = 2'd2;  // outputting N×N pixels

    reg [1:0] state;

    //-------------------------------------------------------------------------
    // Reference sample accumulation
    // sum_top:  sum of ref[1..N]   (first N top row samples)
    // sum_left: sum of ref[2N+1..3N] (first N left col samples)
    //-------------------------------------------------------------------------
    // Max sum: N * (2^10 - 1) = 32 * 1023 = 32736 → 15-bit
    // With N=32: 32*1023=32736, fits in 16-bit unsigned
    reg [15:0] sum_top;
    reg [15:0] sum_left;

    // Store first N top and first N left samples for DC filter
    // top[0..N-1] = ref[1..N], left[0..N-1] = ref[2N+1..3N]
    reg [`PIXEL_WIDTH-1:0] ref_top  [0:31];
    reg [`PIXEL_WIDTH-1:0] ref_left [0:31];

    //-------------------------------------------------------------------------
    // DC value register
    //-------------------------------------------------------------------------
    reg [`PIXEL_WIDTH-1:0] dc_val;

    //-------------------------------------------------------------------------
    // Input acceptance
    //-------------------------------------------------------------------------
    assign in_ready = (state == S_REF_ACC) && (out_ready || !out_valid);

    wire fire_in = in_valid && in_ready;

    //-------------------------------------------------------------------------
    // Reference accumulation FSM
    //-------------------------------------------------------------------------
    integer i;

    always @(posedge clk) begin
        if (!rst_n) begin
            state    <= S_REF_ACC;
            sum_top  <= 16'd0;
            sum_left <= 16'd0;
            dc_val   <= {`PIXEL_WIDTH{1'b0}};
            for (i = 0; i < 32; i = i + 1) begin
                ref_top[i]  <= {`PIXEL_WIDTH{1'b0}};
                ref_left[i] <= {`PIXEL_WIDTH{1'b0}};
            end
        end else begin
            case (state)
                //--------------------------------------------------------------
                S_REF_ACC: begin
                    if (fire_in) begin
                        // Top row: ref[1..N] → indices 1 to N
                        if (in_idx >= 8'd1 && in_idx <= {2'b0, N}) begin
                            sum_top  <= sum_top + {6'b0, in_sample};
                            ref_top[in_idx - 8'd1] <= in_sample;
                        end

                        // Left col: ref[2N+1..3N] → indices 2N+1 to 3N
                        if (in_idx >= (N2 + 8'd1) &&
                            in_idx <= ({2'b0, N} + N2)) begin
                            sum_left <= sum_left + {6'b0, in_sample};
                            ref_left[in_idx - N2 - 8'd1] <= in_sample;
                        end

                        if (in_last) begin
                            state <= S_DC_CALC;
                        end
                    end
                end

                //--------------------------------------------------------------
                // DC computation (HM xGetDCVal):
                //   dcVal = (sum_top + sum_left + N) >> (log2N + 1)
                // Rounding: add N (= 2^log2N) before shift of (log2N+1)
                // Equivalent to: (sum_top + sum_left + N) / (2N)
                //--------------------------------------------------------------
                S_DC_CALC: begin
                    dc_val <= ({1'b0, sum_top} + {1'b0, sum_left} + {11'b0, N}) >> ({3'b0, pu_size_log2} + 6'd1);
                    state  <= S_OUTPUT;
                    // Reset accumulators for next block
                    sum_top  <= 16'd0;
                    sum_left <= 16'd0;
                end

                //--------------------------------------------------------------
                S_OUTPUT: begin
                    // Handled in output FSM below
                    if (out_last && out_valid && out_ready)
                        state <= S_REF_ACC;
                end
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // Output pixel generation FSM
    // Outputs pixels in raster scan (row-major) order
    // DC filter applied to top row (y=0) and left col (x=0)
    //
    // HM xDCPredFiltering (luma only, skip for 4×4 blocks):
    //   p[0][0] = (ref_top[0] + ref_left[0] + 2*dcVal + 2) >> 2
    //   p[x][0] = (ref_top[x] + 3*dcVal + 2) >> 2   for x>0
    //   p[0][y] = (ref_left[y] + 3*dcVal + 2) >> 2  for y>0
    //   p[x][y] = dcVal                              elsewhere
    //-------------------------------------------------------------------------
    reg [5:0] px;   // current x within PU
    reg [5:0] py;   // current y within PU

    wire apply_dc_filter = is_luma && (pu_size_log2 < 3'd5);  // N<32 per HM (4, 8, 16)

    // Corner pixel (0,0)
    wire [11:0] dc_corner = {2'b0, ref_top[0]} + {2'b0, ref_left[0]} +
                             {1'b0, dc_val, 1'b0} + 12'd2;  // *2 + 2

    // Top border (y=0, x>0)
    wire [11:0] dc_top_x  = {2'b0, ref_top[px]} +
                             {dc_val, 1'b0} + {1'b0, dc_val} + 12'd2; // 3*dc+2

    // Left border (x=0, y>0)
    wire [11:0] dc_left_y = {2'b0, ref_left[py]} +
                             {dc_val, 1'b0} + {1'b0, dc_val} + 12'd2;

    // Select pixel value
    wire [`PIXEL_WIDTH-1:0] pred_pixel =
        !apply_dc_filter                  ? dc_val :
        (px == 6'd0 && py == 6'd0)        ? dc_corner[11:2] :
        (py == 6'd0)                       ? dc_top_x[11:2]  :
        (px == 6'd0)                       ? dc_left_y[11:2] :
        dc_val;

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
                    out_pixel <= pred_pixel;
                    out_x     <= px;
                    out_y     <= py;
                    out_last  <= (px == N - 6'd1) && (py == N - 6'd1);

                    // Advance raster scan
                    if (px == N - 6'd1) begin
                        px <= 6'd0;
                        py <= py + 6'd1;
                    end else begin
                        px <= px + 6'd1;
                    end

                    // Reset scan on last pixel
                    if ((px == N - 6'd1) && (py == N - 6'd1)) begin
                        px <= 6'd0;
                        py <= 6'd0;
                    end
                end
            end
        end else begin
            out_valid <= 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // Simulation checks
    //-------------------------------------------------------------------------
    // synthesis translate_off
    integer check_dc_done;
    initial check_dc_done = 0;
    always @(posedge clk) begin
        if (rst_n && state == S_DC_CALC && !check_dc_done) begin
            $display("INFO  [intra_dc] dcVal=%0d sum_top=%0d sum_left=%0d N=%0d",
                     (sum_top + sum_left + N) >> (pu_size_log2+1),
                     sum_top, sum_left, N);
            check_dc_done = 1;
        end
    end
    // synthesis translate_on

endmodule