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
    // FSM state encoding
    // =========================================================================
    localparam [3:0]
        S_IDLE       = 4'd0,   // wait for search_valid
        S_INIT       = 4'd1,   // latch inputs, set center = MVP, check center
        S_REQ_REF    = 4'd2,   // assert ref_req to fetch reference block
        S_WAIT_REF   = 4'd3,   // wait 1 cy for ref_resp_valid
        S_SAD_S1     = 4'd4,   // SAD pipeline cycle 1 (valid_in to sad_4x4)
        S_SAD_S2     = 4'd5,   // SAD pipeline cycle 2
        S_SAD_S3     = 4'd6,   // SAD pipeline cycle 3 (valid_out from sad_4x4)
        S_CMP        = 4'd7,   // compare sad_out vs best_sad, update best
        S_NEXT_PT    = 4'd8,   // advance point index (0..7) or next step
        S_NEXT_STEP  = 4'd9,   // decrease step level, re-center on best
        S_REFINE_REQ = 4'd10,  // start diamond refinement (same as REQ_REF)
        S_DONE       = 4'd11;  // assert result_valid, return to IDLE

    reg [3:0] state;

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

    // Current candidate MV being evaluated
    reg signed [MV_W-1:0]     cand_x, cand_y;

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

    // Reference frame pixel address (signed to pass negative coords to buffer for padding)
    wire signed [12:0] ref_x_req = $signed({1'b0, cu_x_r}) + cand_x;
    wire signed [12:0] ref_y_req = $signed({1'b0, cu_y_r}) + cand_y;

    // =========================================================================
    // Main FSM
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            search_ready  <= 1'b1;
            result_valid  <= 1'b0;
            ref_req_valid <= 1'b0;
            sad_valid_in  <= 1'b0;
            best_sad      <= {BEST_SAD_W{1'b1}}; // MAX
            best_mv_x     <= {MV_W{1'b0}};
            best_mv_y     <= {MV_W{1'b0}};
            center_x      <= {MV_W{1'b0}};
            center_y      <= {MV_W{1'b0}};
            step_idx      <= 3'd0;
            pt_idx        <= 4'd0;
            phase_refine  <= 1'b0;
            refine_round  <= 3'd0;
            cand_x        <= {MV_W{1'b0}};
            cand_y        <= {MV_W{1'b0}};
        end else begin
            // Default: deassert pulse outputs
            ref_req_valid <= 1'b0;
            sad_valid_in  <= 1'b0;
            result_valid  <= 1'b0;

            case (state)

            // ---------------------------------------------------------------
            // IDLE — wait for search request
            // ---------------------------------------------------------------
            S_IDLE: begin
                search_ready <= 1'b1;
                if (search_valid) begin
                    search_ready <= 1'b0;
                    state        <= S_INIT;
                    // synthesis translate_off
                    $display("Time=%0t: [tz_search] search_valid accepted, going to S_INIT", $time);
                    // synthesis translate_on
                end
            end

            // ---------------------------------------------------------------
            // INIT — latch all inputs, initialize search
            // HM: rcStruct.uiBestSad = MAX_UINT; iBestX = mvp.x; iBestY = mvp.y
            // ---------------------------------------------------------------
            S_INIT: begin
                orig_r       <= cu_orig_flat;
                cu_x_r       <= cu_x;
                cu_y_r       <= cu_y;
                mvp_x_r      <= mvp_x;
                mvp_y_r      <= mvp_y;
                // Center search at MVP
                center_x     <= mvp_x;
                center_y     <= mvp_y;
                cand_x       <= mvp_x;   // first candidate = MVP
                cand_y       <= mvp_y;
                best_sad     <= {BEST_SAD_W{1'b1}};
                best_mv_x    <= mvp_x;
                best_mv_y    <= mvp_y;
                step_idx     <= 3'd0;     // start at largest step
                pt_idx       <= 4'd9;     // 9 = "center check" sentinel
                phase_refine <= 1'b0;
                refine_round <= 3'd0;
                state        <= S_REQ_REF;
            end

            // ---------------------------------------------------------------
            // REQ_REF — issue reference block fetch for cand_x, cand_y
            // HM: xTZSearchHelp fetches piCur at (cu + mv) offset
            // ---------------------------------------------------------------
            S_REQ_REF: begin
                ref_req_valid <= 1'b1;
                ref_req_x     <= ref_x_req;
                ref_req_y     <= ref_y_req;
                if (ref_req_valid && ref_req_ready) begin
                    // synthesis translate_off
                    $display("Time=%0t: [tz_search] REQ_REF accepted for x=%0d, y=%0d", $time, ref_x_req, ref_y_req);
                    // synthesis translate_on
                    ref_req_valid <= 1'b0;
                    state <= S_WAIT_REF;
                end
            end

            // ---------------------------------------------------------------
            // WAIT_REF — reference block arrives (1-cycle latency assumed)
            // ---------------------------------------------------------------
            S_WAIT_REF: begin
                if (ref_resp_valid) begin
                    // synthesis translate_off
                    $display("Time=%0t: [tz_search] WAIT_REF got resp_valid", $time);
                    // synthesis translate_on
                    sad_ref_flat <= ref_resp_data;
                    sad_valid_in <= 1'b1;    // launch SAD computation
                    state        <= S_SAD_S1;
                end
                // else stay — variable latency ref buffer support
            end

            // ---------------------------------------------------------------
            // SAD pipeline wait — 3 cycles for sad_4x4 (PIPELINED=1)
            // S_SAD_S1 → S_SAD_S2 → S_SAD_S3 → wait for sad_valid_out
            // ---------------------------------------------------------------
            S_SAD_S1: state <= S_SAD_S2;
            S_SAD_S2: state <= S_SAD_S3;
            S_SAD_S3: begin
                if (sad_valid_out)
                    state <= S_CMP;
                // sad_valid_out should fire here; else wait one more cycle
            end

            // ---------------------------------------------------------------
            // CMP — compare with current best
            // HM: if (uiSad < rcStruct.uiBestSad) { update best }
            // ---------------------------------------------------------------
            S_CMP: begin
                if (sad_out < best_sad) begin
                    best_sad  <= sad_out;
                    best_mv_x <= cand_x;
                    best_mv_y <= cand_y;
                    if (sad_out == 0) begin
                        state <= S_DONE;
                    end else begin
                        state <= S_NEXT_PT;
                    end
                end else begin
                    state <= S_NEXT_PT;
                end
            end

            // ---------------------------------------------------------------
            // NEXT_PT — advance to next search point
            // pt_idx == 9: MVP center check done, start 8-point square (pt 0..7)
            // pt_idx == 8: all 8 points done, go to NEXT_STEP
            // ---------------------------------------------------------------
            S_NEXT_PT: begin
                if (pt_idx == 4'd9) begin
                    // Center (MVP) check done — begin 8-point search at step[0]
                    pt_idx <= 4'd0;
                    state  <= S_NEXT_PT; // compute next cand for pt=0
                end else if (pt_idx == 4'd8) begin
                    // All 8 points of this step done
                    if (phase_refine) begin
                        // Diamond refinement
                        if (refine_round == N_REFINE - 1)
                            state <= S_DONE;
                        else begin
                            refine_round <= refine_round + 1;
                            // Re-center on best for next refinement round
                            center_x <= best_mv_x;
                            center_y <= best_mv_y;
                            pt_idx   <= 4'd0;
                            state    <= S_NEXT_PT;
                        end
                    end else begin
                        state <= S_NEXT_STEP;
                    end
                end else begin
                    // Advance to next of 8 points
                    pt_idx <= pt_idx + 4'd1;
                    // Skip if out of search range
                    if (cand_in_range) begin
                        cand_x <= next_cand_x;
                        cand_y <= next_cand_y;
                        state  <= S_REQ_REF;
                    end else begin
                        // Skip this point (out of range) — stay in NEXT_PT
                        state <= S_NEXT_PT;
                    end
                end
            end

            // ---------------------------------------------------------------
            // NEXT_STEP — move to next (smaller) step level
            // HM: re-center on best, halve the step
            // After N_STEPS square search → start diamond refinement
            // ---------------------------------------------------------------
            S_NEXT_STEP: begin
                // Re-center on best position found so far
                center_x <= best_mv_x;
                center_y <= best_mv_y;
                pt_idx   <= 4'd0;

                if (step_idx == N_STEPS - 1) begin
                    // All step levels done — begin diamond refinement
                    phase_refine <= 1'b1;
                    refine_round <= 3'd0;
                    state        <= S_NEXT_PT;
                end else begin
                    step_idx <= step_idx + 3'd1;
                    state    <= S_NEXT_PT;
                end
            end

            // ---------------------------------------------------------------
            // DONE — output best MV, return to idle
            // HM: rcMv = MV(rcStruct.iBestX, rcStruct.iBestY)
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
        if (state == S_CMP) begin
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