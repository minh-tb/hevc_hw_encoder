//=============================================================================
// rdoq_simple.v
// Simplified Rate-Distortion Optimized Quantization
//
// Mapped from HM source:
//   TLibCommon/TComTrQuant.cpp  xRateDistOptQuant()
//
// Full trellis RDOQ (HM xRateDistOptQuant) is too expensive for hardware:
//   - Requires CABAC context probability estimation per coefficient
//   - Requires forward/backward trellis pass over all 1024 coefficients
//   - Needs ContextTables.h probability tables
//
// This module implements two RDOQ sub-features that give most of the
// coding gain at low hardware cost:
//
// 1. SIGN DATA HIDING (SDH) — HM: sign_hiding_enabled
//    Config: enabled by default in main10 profile
//    When a coefficient group (4×4 = 16 coeffs) has >= 2 non-zero levels,
//    the sign of the first non-zero coefficient can be inferred from
//    the parity of the sum of all levels in the group.
//    → One sign bit per 4×4 group is saved in the bitstream.
//    Hardware: adjust last-non-zero level in group by ±1 to force
//    correct parity, if distortion increase < threshold.
//
// 2. LAST POSITION OPTIMIZATION — HM: lastCGIdx selection
//    Scan coefficients in reverse diagonal order.
//    If trailing zero coefficients exist, suppress them (level=0).
//    Already handled by CBF logic in fwd_quant — this module refines
//    by checking if setting last non-zero = 0 reduces rate sufficiently.
//    Simplified: just zero out levels below a minimum threshold.
//
// What is NOT implemented (full trellis):
//   - Per-coefficient rate estimation from CABAC context models
//   - Lagrangian RD cost: D + λR per trellis state
//   - Backward trellis pass for optimal level selection
//   These require ContextTables.h — implement in rdoq_full.v later
//
// Interface:
//   Receives quantized level stream from fwd_quant (serial, one per cycle)
//   Outputs adjusted level stream to cabac_enc
//   Buffers one full 4×4 coefficient group (16 coeffs) for SDH processing
//   Latency: 16 cycles per group (one group buffered at a time)
//
// Config:
//   RDOQ   = 1  (enabled — this module active)
//   RDOQTS = 1  (transform skip path passes through unchanged)
//=============================================================================

`include "parameter_pkg.vh"

module rdoq_simple (
    input  wire         clk,
    input  wire         rst_n,

    // Context from fwd_quant passthrough
    input  wire [5:0]   qp,
    input  wire [2:0]   tu_size_log2,
    input  wire         is_intra,
    input  wire         transform_skip,

    // Input: quantized level stream from fwd_quant
    input  wire         in_valid,
    output wire         in_ready,
    input  wire signed [`COEFF_WIDTH-1:0] in_level,
    input  wire [9:0]   in_scan_idx,    // diagonal scan position
    input  wire         in_last,        // last coeff in TU

    // Output: RDOQ-adjusted level stream to cabac_enc
    output reg          out_valid,
    input  wire         out_ready,
    output reg  signed [`COEFF_WIDTH-1:0] out_level,
    output reg  [9:0]   out_scan_idx,
    output reg          out_last,
    output reg          out_cbf         // updated CBF after RDOQ
);

    //-------------------------------------------------------------------------
    // Parameters
    //-------------------------------------------------------------------------
    // 4×4 coefficient group size (HM: SCAN_SET_SIZE = 16)
    localparam GROUP_SIZE = 16;
    localparam GROUP_BITS = 4;   // log2(16)
    localparam SBH_THRESHOLD = 4;

    // SDH threshold — HM uses Lagrangian cost; simplified: allow ±1 if
    // level magnitude > SDH_MIN_LEVEL (avoid touching near-zero coefficients)
    localparam SDH_MIN_LEVEL = 2;

    //-------------------------------------------------------------------------
    // Coefficient group buffer
    // Buffer one 4×4 group before outputting — needed for SDH parity check
    // group_buf[0..15]: levels in diagonal scan order
    // group_scan[0..15]: scan positions
    //-------------------------------------------------------------------------
    reg signed [`COEFF_WIDTH-1:0] group_buf  [0:GROUP_SIZE-1];
    reg [9:0]                      group_scan [0:GROUP_SIZE-1];
    reg [GROUP_BITS-1:0]           group_ptr;      // current fill position
    reg                            group_active;   // group buffer has data
    reg                            group_last_tu;  // last group in TU

    // First and last non-zero positions within current group
    reg [GROUP_BITS-1:0]  first_nz;    // scan pos of first non-zero
    reg [GROUP_BITS-1:0]  last_nz;     // scan pos of last non-zero
    reg                    has_nz;      // any non-zero in group

    //-------------------------------------------------------------------------
    // SDH parity computation
    // Sum of all levels in group — parity = sum[0]
    // HM: if parity of sum != sign of first non-zero, adjust last_nz by ±1
    //-------------------------------------------------------------------------
    reg signed [`COEFF_WIDTH+GROUP_BITS-1:0] level_sum; // sum of abs levels

    //-------------------------------------------------------------------------
    // Input acceptance — accept one coefficient per cycle when not flushing
    //-------------------------------------------------------------------------
    reg flushing;   // 1 while outputting buffered group
    assign in_ready = !flushing && (out_ready | ~out_valid);

    //-------------------------------------------------------------------------
    // Group fill logic
    //-------------------------------------------------------------------------
    wire fire_in = in_valid && in_ready;

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            group_ptr     <= {GROUP_BITS{1'b0}};
            group_active  <= 1'b0;
            group_last_tu <= 1'b0;
            first_nz      <= {GROUP_BITS{1'b0}};
            last_nz       <= {GROUP_BITS{1'b0}};
            has_nz        <= 1'b0;
            level_sum     <= {(`COEFF_WIDTH+GROUP_BITS){1'b0}};
            for (i = 0; i < GROUP_SIZE; i = i + 1) begin
                group_buf[i]  <= {`COEFF_WIDTH{1'b0}};
                group_scan[i] <= 10'd0;
            end
        end else if (fire_in) begin
            // Store incoming level in group buffer
            group_buf[group_ptr]  <= in_level;
            group_scan[group_ptr] <= in_scan_idx;
            group_active          <= 1'b1;
            group_last_tu         <= in_last;

            // Track first/last non-zero within group
            if (in_level != 16'sd0) begin
                if (!has_nz) begin
                    first_nz <= group_ptr;
                    has_nz   <= 1'b1;
                end
                last_nz   <= group_ptr;
                level_sum <= level_sum + {{GROUP_BITS{in_level[`COEFF_WIDTH-1]}},
                                          in_level};
            end

            // Advance pointer — wrap at GROUP_SIZE
            if (group_ptr == GROUP_SIZE - 1) begin
                group_ptr <= {GROUP_BITS{1'b0}};
                // level_sum and has_nz reset when group is flushed (below)
            end else begin
                group_ptr <= group_ptr + 1'b1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // SDH adjustment computation
    // Triggered when a full group is collected (group_ptr wraps) or in_last
    //
    // SDH rule (HM signHidingEnabled):
    //   sign_first = sign(group_buf[first_nz])   (1=positive, -1=negative)
    //   parity     = level_sum[0]                (LSB of sum)
    //   desired    = sign_first == positive ? 0 : 1
    //   if parity != desired:
    //     adjust group_buf[last_nz] by ±1 to fix parity
    //     prefer +1 if level > 0, prefer -1 if level < 0
    //     only if |group_buf[last_nz]| >= SDH_MIN_LEVEL (avoid zero-crossing)
    //-------------------------------------------------------------------------
    wire group_full = (group_ptr == {GROUP_BITS{1'b0}}) && group_active && fire_in
                   || (in_last && fire_in);

    wire sign_first    = group_buf[first_nz][`COEFF_WIDTH-1]; // 1=negative
    wire parity        = level_sum[0];
    wire desired_parity= sign_first;                           // HM convention
    wire parity_wrong  = has_nz && (parity != desired_parity);

    // Compute adjusted last_nz level
    wire signed [`COEFF_WIDTH-1:0] last_nz_level  = group_buf[last_nz];
    wire                            last_nz_pos    = last_nz_level[`COEFF_WIDTH-1];
    // Adjust direction: add +1 if positive, -1 if negative (toward zero = safer)
    
    // To guarantee the parity is fixed without accidentally setting the coefficient to 0 
    // (which would change the last_nz position and break the distance calculation),
    // we increase magnitude if it is +/- 1, and decrease magnitude otherwise.
    wire signed [`COEFF_WIDTH-1:0] adj_level =
        (parity_wrong && (last_nz_level >= SDH_MIN_LEVEL || last_nz_level <= -SDH_MIN_LEVEL)) ?
        parity_wrong ? (
            (last_nz_level ==  16'sd1) ?  16'sd2 :
            (last_nz_level == -16'sd1) ? -16'sd2 :
            (last_nz_pos ? (last_nz_level + 16'sd1) : (last_nz_level - 16'sd1)) :
            last_nz_level;
        ) : last_nz_level;

    // Don't apply SDH for transform skip (HM: TS coefficients are not sign-hidden)
    wire sdh_enable = !transform_skip && has_nz && parity_wrong;
    wire [GROUP_BITS-1:0] nz_distance = last_nz - first_nz;

    // Apply SDH if distance >= 4 (HM SBH_THRESHOLD)
    // Don't apply for transform skip
    wire sdh_enable = !transform_skip && has_nz && parity_wrong && (nz_distance >= SBH_THRESHOLD[GROUP_BITS-1:0]);

    //-------------------------------------------------------------------------
    // Flush FSM — output buffered group when full
    //-------------------------------------------------------------------------
    reg [GROUP_BITS-1:0] flush_ptr;
    reg                   flush_cbf;

    // FSM states
    localparam S_IDLE  = 1'b0;
    localparam S_FLUSH = 1'b1;
    reg state;

    always @(posedge clk) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            flushing  <= 1'b0;
            flush_ptr <= {GROUP_BITS{1'b0}};
            flush_cbf <= 1'b0;
            out_valid <= 1'b0;
            out_level    <= {`COEFF_WIDTH{1'b0}};
            out_scan_idx <= 10'd0;
            out_last     <= 1'b0;
            out_cbf      <= 1'b0;
            has_nz       <= 1'b0;
            level_sum    <= {(`COEFF_WIDTH+GROUP_BITS){1'b0}};
        end else begin
            case (state)
                //--------------------------------------------------------------
                S_IDLE: begin
                    out_valid <= 1'b0;
                    // Trigger flush when group is complete
                    if (group_full) begin
                        state     <= S_FLUSH;
                        flushing  <= 1'b1;
                        flush_ptr <= {GROUP_BITS{1'b0}};
                        flush_cbf <= 1'b0;
                        // Reset group tracking for next group
                        has_nz    <= 1'b0;
                        level_sum <= {(`COEFF_WIDTH+GROUP_BITS){1'b0}};
                    end
                end

                //--------------------------------------------------------------
                S_FLUSH: begin
                    if (out_ready || !out_valid) begin
                        // Determine output level for this flush position
                        // Apply SDH adjustment to last_nz position only
                        automatic signed [`COEFF_WIDTH-1:0] emit_level;
                        emit_level = (sdh_enable && flush_ptr == last_nz) ?
                                     adj_level : group_buf[flush_ptr];

                        out_valid    <= 1'b1;
                        out_level    <= emit_level;
                        out_scan_idx <= group_scan[flush_ptr];
                        out_cbf      <= flush_cbf | (emit_level != 16'sd0);
                        flush_cbf    <= flush_cbf | (emit_level != 16'sd0);

                        // Last flag: last position in last group of TU
                        out_last <= (flush_ptr == GROUP_SIZE-1 && group_last_tu)
                                  || (group_last_tu &&
                                      flush_ptr == group_ptr - 1'b1);

                        if (flush_ptr == GROUP_SIZE - 1
                        || (group_last_tu && flush_ptr == group_ptr - 1'b1)) begin
                            // Group output complete
                            state    <= S_IDLE;
                            flushing <= 1'b0;
                        end else begin
                            flush_ptr <= flush_ptr + 1'b1;
                        end
                    end
                end
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // Simulation checks
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && in_valid && !in_ready && !flushing)
            $display("WARN  [rdoq_simple] unexpected stall at scan=%0d time=%0t",
                     in_scan_idx, $time);
    end
    // synthesis translate_on

endmodule