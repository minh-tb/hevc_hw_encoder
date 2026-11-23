//=============================================================================
// tz_search.v
// TZ (Test Zone) Integer-Pel Motion Estimation
//
// Mapped from HM source:
//   TLibEncoder/TEncSearch.cpp :: TEncSearch::xTZSearch()
//   TLibEncoder/TEncSearch.cpp :: xTZ8PointSquareSearch()
//   TLibEncoder/TEncSearch.cpp :: xTZ8PointDiamondSearch()
//   TLibEncoder/TEncSearch.h   :: IntTZSearchStruct
//
// HM algorithm (hardware-fixed params: bitDepth=10, 4×4 CU, integer-pel):
//
//   IntTZSearchStruct rcStruct;
//   rcStruct.uiBestSad = MAX_UINT;
//
//   Step 1: Check starting point (MVP)
//   xTZSearchHelp(piOrg, rcStruct, mvp_x, mvp_y, 0, 0);
//
//   Step 2: Cross/square search — descending step sizes
//   for (iDist = 1; iDist <= iSearchRange; iDist <<= 1)
//     xTZ8PointSquareSearch(piOrg, rcStruct, mvp_x, mvp_y, iDist);
//     checks 8 points: (±iDist, 0), (0, ±iDist), (±iDist, ±iDist)
//
//   Step 3: Diamond refinement from best position
//   for (Int iRefinement = 0; iRefinement < 4; iRefinement++) {
//     if (rcStruct.uiBestRound < iRefinement) break;
//     xTZ8PointDiamondSearch(piOrg, rcStruct, iBestX, iBestY, 1);
//   }
//
//   rcMv = MV(rcStruct.iBestX, rcStruct.iBestY);
//
// Hardware implementation — FSM with 8-point square search:
//
//   Candidate sequence:
//     [0]   MVP center (1 point)
//     [1-8] Step=32: 8 square offsets × step  (configurable)
//     [9-16] Step=16: 8 square offsets × step from best so far
//     ...
//     [last] Step=1: final diamond from best
//
//   8-point square offset LUT (dx, dy sign pairs):
//     Pt# | dx | dy
//     ----|----+----
//      0  | -1 | -1
//      1  |  0 | -1
//      2  | +1 | -1
//      3  | -1 |  0
//      4  | +1 |  0
//      5  | -1 | +1
//      6  |  0 | +1
//      7  | +1 | +1
//
//   Candidate MV = center_mv + sign(dx,dy) × step
//   Candidates out-of-range (±SRCH_RNG from MVP) are skipped
//   Candidates out-of-frame are clamped via ref_frame_buffer
//
// Pipeline / timing:
//   Each candidate:  1 cycle  ref fetch request
//                  + 1 cycle  ref data available (registered SRAM)
//                  + 3 cycles sad_4x4 pipeline
//                  + 1 cycle  compare/update
//                  = 6 cycles / candidate (worst case)
//   Total candidates: 1 + N_STEPS×8 + 4 = 1 + 6×8 + 4 = 53 max
//   Total cycles:     ~53 × 6 = ~318 cycles / 4×4 CU @ 125 MHz ≈ 2.5 µs
//
// Ports:
//   Search request:  search_valid / search_ready  (handshake)
//   CU pixels:       cu_orig_flat  (held stable during search)
//   CU position:     cu_x, cu_y   (frame coordinates of top-left)
//   MVP:             mvp_x, mvp_y (integer-pel MV, signed)
//   Ref fetch port:  to ref_frame_buffer
//   Result:          best_mv_x, best_mv_y, best_sad, result_valid
//=============================================================================

`include "parameter_pkg.vh"

module tz_search #(
    parameter PIXEL_WIDTH  = `PIXEL_WIDTH,   // 10
    parameter MV_W         = `MV_TOTAL_BITS - `MV_FRAC_BITS,             // signed MV bits, ±512 range
    parameter CU_COORD_W   = `FRAME_DIM_WIDTH,             // frame coordinate bits (4096 max)
    parameter SRCH_RNG     = `ME_SEARCH_RANGE,             // integer-pel search range
    parameter N_STEPS      = 6,             // step levels: 32,16,8,4,2,1
    parameter N_REFINE     = 4,             // diamond refinement rounds (HM default)

    // Derived
    parameter SAD_W        = 12,            // sad_4x4 output (see sad_4x4.v)
    parameter BEST_SAD_W   = SAD_W          // best SAD register width
)(
    input  wire                        clk,
    input  wire                        rst_n,

    // Search request handshake
    input  wire                        search_valid,
    output reg                         search_ready,

    // Current 4×4 CU pixels (row-major, 10-bit/pixel, held stable)
    input  wire [PIXEL_WIDTH*16-1:0]   cu_orig_flat,

    // CU position in current frame
    input  wire [CU_COORD_W-1:0]       cu_x,
    input  wire [CU_COORD_W-1:0]       cu_y,

    // Motion Vector Predictor (integer-pel, signed)
    input  wire signed [MV_W-1:0]      mvp_x,
    input  wire signed [MV_W-1:0]      mvp_y,

    // Reference block fetch port — to ref_frame_buffer
    // Request a 4×4 block at (ref_req_x, ref_req_y) in reference frame
    output reg                         ref_req_valid,
    output reg  signed [11:0]          ref_req_x,
    output reg  signed [11:0]          ref_req_y,
    input  wire                        ref_req_ready,
    input  wire                        ref_resp_valid,  // asserted 1 cy after req
    input  wire [PIXEL_WIDTH*16-1:0]   ref_resp_data,   // 4×4 reference pixels

    // Search result
    output reg                         result_valid,
    output reg  signed [MV_W-1:0]      best_mv_x,
    output reg  signed [MV_W-1:0]      best_mv_y,
    output reg  [BEST_SAD_W-1:0]       best_sad
);

    // =========================================================================
    // FSM state encoding (overlapped ring pipeline)
    // =========================================================================
    localparam [2:0]
        S_IDLE        = 3'd0,   // wait for search_valid
        S_INIT        = 3'd1,   // latch inputs, set center = MVP
        S_CENTER_REQ  = 3'd2,   // issue MVP center ref request
        S_CENTER_WAIT = 3'd3,   // wait for MVP center ref response
        S_RING        = 3'd4,   // overlapped ref fetch + 3-stage sad_4x4 + cmp
        S_DRAIN_ZERO  = 3'd5,   // drain in-flight ref response after sad_out==0
        S_DONE        = 3'd6;   // assert result_valid, return to IDLE

    reg [2:0] state;

    // =========================================================================
    // 8-point square offset LUT
    // Maps point index 0..7 to (dx, dy) ∈ {-1, 0, +1}²\{(0,0)}
    // =========================================================================
    // dx_lut[i], dy_lut[i] encoded as 2-bit signed: 2'b11=-1, 2'b00=0, 2'b01=+1
    wire signed [1:0] dx_lut [0:7];
    wire signed [1:0] dy_lut [0:7];

    assign dx_lut[0] = -2'd1; assign dy_lut[0] = -2'd1; // top-left
    assign dx_lut[1] =  2'd0; assign dy_lut[1] = -2'd1; // top
    assign dx_lut[2] =  2'd1; assign dy_lut[2] = -2'd1; // top-right
    assign dx_lut[3] = -2'd1; assign dy_lut[3] =  2'd0; // left
    assign dx_lut[4] =  2'd1; assign dy_lut[4] =  2'd0; // right
    assign dx_lut[5] = -2'd1; assign dy_lut[5] =  2'd1; // bottom-left
    assign dx_lut[6] =  2'd0; assign dy_lut[6] =  2'd1; // bottom
    assign dx_lut[7] =  2'd1; assign dy_lut[7] =  2'd1; // bottom-right

    // Step sizes (descending): 32, 16, 8, 4, 2, 1
    // Encoded as log2(step) for shift: 5, 4, 3, 2, 1, 0
    wire [2:0] step_log2_lut [0:N_STEPS-1];
    assign step_log2_lut[0] = 3'd5; // step=32
    assign step_log2_lut[1] = 3'd4; // step=16
    assign step_log2_lut[2] = 3'd3; // step=8
    assign step_log2_lut[3] = 3'd2; // step=4
    assign step_log2_lut[4] = 3'd1; // step=2
    assign step_log2_lut[5] = 3'd0; // step=1

    // =========================================================================
    // Internal registers
    // =========================================================================

    // Latched inputs (captured at S_INIT)
    reg [PIXEL_WIDTH*16-1:0]  orig_r;
    reg [CU_COORD_W-1:0]      cu_x_r, cu_y_r;
    reg signed [MV_W-1:0]     mvp_x_r, mvp_y_r;

    // Current search state
    reg signed [MV_W-1:0]     center_x, center_y;   // current search center MV
    reg [2:0]                  step_idx;              // index into step_log2_lut
    reg [3:0]                  pt_idx;               // 0..7 for 8-point search
    reg                        phase_refine;          // 0=square, 1=diamond refine
    reg [2:0]                  refine_round;          // refinement round counter

    // Overlapped request / SAD MV tracking pipeline
    reg signed [MV_W-1:0]     req_mv_x, req_mv_y;
    reg signed [MV_W-1:0]     ref_mv_x, ref_mv_y;
    reg                       ref_in_flight;
    reg                       early_zero;
    reg  [3:0]                sad_pipe_v;
    reg signed [MV_W-1:0]     sad_mv_x [0:3];
    reg signed [MV_W-1:0]     sad_mv_y [0:3];

    // SAD unit interface
    reg                        sad_valid_in;
    reg  [PIXEL_WIDTH*16-1:0]  sad_ref_flat;
    wire                       sad_valid_out;
    wire [SAD_W-1:0]           sad_out;

    // =========================================================================
    // sad_4x4 instance (pipelined, 3-cycle latency)
    // =========================================================================
    sad_4x4 #(
        .PIXEL_WIDTH (PIXEL_WIDTH),
        .PIPELINED   (1)
    ) u_sad (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (sad_valid_in),
        .orig_flat (orig_r),          // held stable during entire search
        .ref_flat  (sad_ref_flat),    // reference block for current candidate
        .valid_out (sad_valid_out),
        .sad_out   (sad_out)
    );

    // =========================================================================
    // Candidate MV generation
    // cand_mv = center + dx_lut[pt_idx] × step
    // step = 1 << step_log2_lut[step_idx]
    // =========================================================================
    wire [2:0]             cur_step_log2 = step_log2_lut[step_idx];
    wire signed [MV_W-1:0] step_val  = ({{(MV_W-1){1'b0}}, 1'b1} << cur_step_log2);

    // dx/dy offset for current point
    wire signed [MV_W-1:0] dx_scaled =
        (dx_lut[pt_idx[2:0]] == -2'sd1) ? -step_val :
        (dx_lut[pt_idx[2:0]] ==  2'sd1) ?  step_val : {MV_W{1'b0}};

    wire signed [MV_W-1:0] dy_scaled =
        (dy_lut[pt_idx[2:0]] == -2'sd1) ? -step_val :
        (dy_lut[pt_idx[2:0]] ==  2'sd1) ?  step_val : {MV_W{1'b0}};

    wire signed [MV_W-1:0] next_cand_x = center_x + dx_scaled;
    wire signed [MV_W-1:0] next_cand_y = center_y + dy_scaled;

    // Search range bounds check (relative to MVP)
    // Sign-extend to MV_W+1 to prevent boundary wrap-around false evaluations
    wire signed [MV_W:0] mvp_x_ext  = mvp_x_r;
    wire signed [MV_W:0] mvp_y_ext  = mvp_y_r;
    wire signed [MV_W:0] next_x_ext = next_cand_x;
    wire signed [MV_W:0] next_y_ext = next_cand_y;

    wire cand_in_range =
        (next_x_ext >= (mvp_x_ext - $signed(SRCH_RNG))) &&
        (next_x_ext <= (mvp_x_ext + $signed(SRCH_RNG))) &&
        (next_y_ext >= (mvp_y_ext - $signed(SRCH_RNG))) &&
        (next_y_ext <= (mvp_y_ext + $signed(SRCH_RNG)));

    wire req_accepted   = ref_req_valid && ref_req_ready;
    wire next_in_flight = (ref_in_flight && !ref_resp_valid) || req_accepted;
    wire zero_sad_hit   = sad_valid_out && sad_pipe_v[3] && !early_zero && (sad_out == {SAD_W{1'b0}});

    // =========================================================================
    // Main FSM (Overlapped Ring Pipeline)
    // =========================================================================
    integer si;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            search_ready  <= 1'b1;
            result_valid  <= 1'b0;
            ref_req_valid <= 1'b0;
            ref_req_x     <= 12'sd0;
            ref_req_y     <= 12'sd0;
            sad_valid_in  <= 1'b0;
            sad_ref_flat  <= {(PIXEL_WIDTH*16){1'b0}};
            orig_r        <= {(PIXEL_WIDTH*16){1'b0}};
            cu_x_r        <= {CU_COORD_W{1'b0}};
            cu_y_r        <= {CU_COORD_W{1'b0}};
            mvp_x_r       <= {MV_W{1'b0}};
            mvp_y_r       <= {MV_W{1'b0}};
            best_sad      <= {BEST_SAD_W{1'b1}}; // MAX
            best_mv_x     <= {MV_W{1'b0}};
            best_mv_y     <= {MV_W{1'b0}};
            center_x      <= {MV_W{1'b0}};
            center_y      <= {MV_W{1'b0}};
            step_idx      <= 3'd0;
            pt_idx        <= 4'd0;
            phase_refine  <= 1'b0;
            refine_round  <= 3'd0;
            req_mv_x      <= {MV_W{1'b0}};
            req_mv_y      <= {MV_W{1'b0}};
            ref_mv_x      <= {MV_W{1'b0}};
            ref_mv_y      <= {MV_W{1'b0}};
            ref_in_flight <= 1'b0;
            early_zero    <= 1'b0;
            sad_pipe_v    <= 4'd0;
            for (si = 0; si < 4; si = si + 1) begin
                sad_mv_x[si] <= {MV_W{1'b0}};
                sad_mv_y[si] <= {MV_W{1'b0}};
            end
        end else begin
            // Default pulse clears & SAD MV shift register
            sad_valid_in  <= 1'b0;
            result_valid  <= 1'b0;
            sad_pipe_v    <= {sad_pipe_v[2:0], 1'b0};
            for (si = 1; si < 4; si = si + 1) begin
                sad_mv_x[si] <= sad_mv_x[si-1];
                sad_mv_y[si] <= sad_mv_y[si-1];
            end

            case (state)

            // ---------------------------------------------------------------
            // IDLE — wait for search request
            // ---------------------------------------------------------------
            S_IDLE: begin
                search_ready  <= 1'b1;
                ref_req_valid <= 1'b0;
                ref_in_flight <= 1'b0;
                sad_pipe_v    <= 4'd0;
                if (search_valid) begin
                    search_ready <= 1'b0;
                    orig_r       <= cu_orig_flat;
                    cu_x_r       <= cu_x;
                    cu_y_r       <= cu_y;
                    mvp_x_r      <= mvp_x;
                    mvp_y_r      <= mvp_y;
                    state        <= S_INIT;
                    // synthesis translate_off
                    $display("Time=%0t: [tz_search] search_valid accepted, going to S_INIT", $time);
                    // synthesis translate_on
                end
            end

            // ---------------------------------------------------------------
            // INIT — issue MVP center ref fetch & initialize search
            // ---------------------------------------------------------------
            S_INIT: begin
                center_x      <= mvp_x_r;
                center_y      <= mvp_y_r;
                req_mv_x      <= mvp_x_r;
                req_mv_y      <= mvp_y_r;
                ref_req_valid <= 1'b1;
                ref_req_x     <= $signed({1'b0, cu_x_r}) + mvp_x_r;
                ref_req_y     <= $signed({1'b0, cu_y_r}) + mvp_y_r;
                best_sad      <= {BEST_SAD_W{1'b1}};
                best_mv_x     <= mvp_x_r;
                best_mv_y     <= mvp_y_r;
                step_idx      <= 3'd0;
                pt_idx        <= 4'd0;
                phase_refine  <= 1'b0;
                refine_round  <= 3'd0;
                early_zero    <= 1'b0;
                ref_in_flight <= 1'b0;
                sad_pipe_v    <= 4'd0;
                state         <= S_CENTER_REQ;
            end

            // ---------------------------------------------------------------
            // CENTER_REQ / CENTER_WAIT — fetch MVP center block
            // ---------------------------------------------------------------
            S_CENTER_REQ: begin
                if (req_accepted) begin
                    ref_req_valid <= 1'b0;
                    ref_mv_x      <= req_mv_x;
                    ref_mv_y      <= req_mv_y;
                    ref_in_flight <= 1'b1;
                    state         <= S_CENTER_WAIT;
                end
            end

            S_CENTER_WAIT: begin
                if (ref_resp_valid) begin
                    sad_ref_flat  <= ref_resp_data;
                    sad_valid_in  <= 1'b1;
                    sad_pipe_v[0] <= 1'b1;
                    sad_mv_x[0]   <= ref_mv_x;
                    sad_mv_y[0]   <= ref_mv_y;
                    ref_in_flight <= 1'b0;
                    state         <= S_RING;
                end
            end

            // ---------------------------------------------------------------
            // RING — overlapped 8-point square / diamond pipeline
            // ---------------------------------------------------------------
            S_RING: begin
                ref_in_flight <= next_in_flight;

                if (ref_resp_valid) begin
                    sad_ref_flat  <= ref_resp_data;
                    sad_valid_in  <= 1'b1;
                    sad_pipe_v[0] <= 1'b1;
                    sad_mv_x[0]   <= ref_mv_x;
                    sad_mv_y[0]   <= ref_mv_y;
                end

                if (req_accepted) begin
                    ref_req_valid <= 1'b0;
                    ref_mv_x      <= req_mv_x;
                    ref_mv_y      <= req_mv_y;
                end else if (!ref_req_valid && (pt_idx < 4'd8) && !early_zero && !zero_sad_hit) begin
                    pt_idx <= pt_idx + 4'd1;
                    if (cand_in_range) begin
                        ref_req_valid <= 1'b1;
                        req_mv_x      <= next_cand_x;
                        req_mv_y      <= next_cand_y;
                        ref_req_x     <= $signed({1'b0, cu_x_r}) + next_cand_x;
                        ref_req_y     <= $signed({1'b0, cu_y_r}) + next_cand_y;
                    end
                end

                if (sad_valid_out && sad_pipe_v[3] && !early_zero) begin
                    if (sad_out < best_sad) begin
                        best_sad  <= sad_out;
                        best_mv_x <= sad_mv_x[3];
                        best_mv_y <= sad_mv_y[3];
                    end
                    if (sad_out == {SAD_W{1'b0}}) begin
                        early_zero <= 1'b1;
                        if (!req_accepted) begin
                            ref_req_valid <= 1'b0;
                        end
                        if (next_in_flight) begin
                            state <= S_DRAIN_ZERO;
                        end else begin
                            state <= S_DONE;
                        end
                    end
                end

                if (!zero_sad_hit && !early_zero &&
                    (pt_idx == 4'd8) && !ref_req_valid && !ref_in_flight && (sad_pipe_v == 4'd0)) begin
                    center_x <= best_mv_x;
                    center_y <= best_mv_y;
                    pt_idx   <= 4'd0;
                    if (phase_refine) begin
                        if ((refine_round == N_REFINE - 1) ||
                            ((best_mv_x == center_x) && (best_mv_y == center_y))) begin
                            state <= S_DONE;
                        end else begin
                            refine_round <= refine_round + 3'd1;
                        end
                    end else begin
                        if (step_idx == N_STEPS - 1) begin
                            if ((best_mv_x == center_x) && (best_mv_y == center_y)) begin
                                state <= S_DONE;
                            end else begin
                                phase_refine <= 1'b1;
                                refine_round <= 3'd0;
                            end
                        end else begin
                            step_idx <= step_idx + 3'd1;
                        end
                    end
                end
            end

            // ---------------------------------------------------------------
            // DRAIN_ZERO — finish any already-accepted cache lookup cleanly
            // ---------------------------------------------------------------
            S_DRAIN_ZERO: begin
                ref_in_flight <= next_in_flight;
                if (!next_in_flight) begin
                    state <= S_DONE;
                end
            end

            // ---------------------------------------------------------------
            // DONE — output best MV, return to idle
            // ---------------------------------------------------------------
            S_DONE: begin
                // synthesis translate_off
                $display("Time=%0t: [tz_search] DONE best_mv=(%0d,%0d) best_sad=%0d", $time, best_mv_x, best_mv_y, best_sad);
                // synthesis translate_on
                result_valid <= 1'b1;
                search_ready <= 1'b1;
                state        <= S_IDLE;
            end

            default: state <= S_IDLE;

            endcase
        end
    end

    // =========================================================================
    // Compute next_cand combinationally for pt_idx+1 lookahead
    // (used in NEXT_PT for range check before issuing REQ_REF)
    // =========================================================================
    // next_cand_x/y already wired above using pt_idx + center_x/y

    // =========================================================================
    // Simulation assertions
    // =========================================================================
    // synthesis translate_off
    always @(posedge clk) begin
        if (state == S_RING && sad_valid_out && sad_pipe_v[3]) begin
            // if (sad_out > 12'd4092)
                // $display("WARN [tz_search] sad_out=%0d at t=%0t — exceeds 4×4 max (4092)", sad_out, $time);
        end
        if (result_valid) begin
            // $display("INFO [tz_search] best_mv=(%0d,%0d) best_sad=%0d at t=%0t",
            //          $signed(best_mv_x), $signed(best_mv_y), best_sad, $time);
        end
    end
    // synthesis translate_on

endmodule