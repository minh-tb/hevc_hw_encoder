//=============================================================================
// bin_encoder.v
// HEVC CABAC Bin Encoder — context lookup, state update, range-coder dispatch
//
// Mapped from HM source:
//   TLibEncoder/TEncBinCABAC.cpp :: encodeBin(), encodeBinEP(), encodeBinsEP()
//   TLibEncoder/TEncSbac.cpp     :: syntax element encoders (call encodeBin/EP)
//
// HM encodeBin() call chain:
//   TEncSbac::xWriteCode/Flag → TEncBinCABAC::encodeBin(binValue, rcCtxModel)
//     1. look up pLPS from state + range
//     2. update arithmetic range/low  (→ range_coder.v)
//     3. rcCtxModel.update(binValue)  (→ ctx_model_store.v write-back)
//
// HM encodeBinEP() — bypass (equi-probable):
//   low <<= 1;  if (bin) low += range;   // no ctx, no range update
//   Implemented here by signalling range_coder with ep_valid/ep_value.
//
// Pipeline (2 stages):
//
//   Cycle T (ACCEPT):
//     - Receive {bin_valid, bin_value, ctx_id, is_ep} from syntax_*
//     - Read rd_state from ctx_model_store (COMBINATIONAL — zero latency)
//     - Extract pStateIdx = rd_state[6:1], valMPS = rd_state[0]
//     - Forward {bin_value, pStateIdx, valMPS} to range_coder (regular)
//       or {bin_value} to range_coder (bypass EP path)
//     - Latch {ctx_id, bin_value} for write-back next cycle
//
//   Cycle T+1 (UPDATE):
//     - Drive upd_valid → ctx_model_store (registered write, completes at T+1)
//     - ctx_model_store applies transition: transIdx[MPS|LPS][pStateIdx]
//     - Ready for next bin (if range_coder accepted T's bin)
//
// RAW Hazard — same context on consecutive bins:
//   If bin_n uses ctx=K and bin_{n+1} also uses ctx=K:
//   - At cycle T+1, the ctx_model_store WRITE for bin_n completes
//   - The ctx_model_store READ for bin_{n+1} at T+1 sees the UPDATED state ✓
//   - Because ctx_model_store read is combinational AFTER the registered write
//   - This holds for back-to-back bins to the same ctx with NO stall required
//
// Bypass encoding (EP):
//   Sent to range_coder via rc_ep_valid/rc_ep_value.
//   No ctx_model_store interaction.
//   range_coder handles: low = (low<<1) + (ep_bin ? range : 0)
//
// Stall conditions:
//   bin_rdy_out = rc_bin_ready && !init_busy
//   (Stalls while range_coder is renormalizing or ctx store is initializing)
//
// Interface note:
//   range_coder.v uses a shared bin_value and bin_ready port for both
//   regular and EP bypass bins, with ep_valid distinguishing them.
//=============================================================================

`include "parameter_pkg.vh"

module bin_encoder #(
    parameter CTX_ID_W = 8     // context index width (covers 0..153)
)(
    input  wire                clk,
    input  wire                rst_n,

    // ── Slice init ───────────────────────────────────────────────────────────
    // Gates output while ctx_model_store is initializing (init_busy)
    input  wire                init_busy,

    // ── Bin input from syntax_cu / syntax_pred / syntax_coeff ───────────────
    input  wire                bin_valid,    // new bin available
    input  wire                bin_value,    // 0 or 1
    input  wire [CTX_ID_W-1:0] ctx_id,       // context index (0..153, ignored if is_ep)
    input  wire                is_ep,        // 1 = bypass (equiprobable), 0 = context-coded
    output wire                bin_rdy_out,  // 1 = can accept a new bin this cycle

    // ── ctx_model_store read port ────────────────────────────────────────────
    output wire [CTX_ID_W-1:0] rd_ctx_id,    // context to look up (combinational)
    input  wire [6:0]          rd_state,     // {pStateIdx[5:0], valMPS}

    // ── ctx_model_store write-back port ──────────────────────────────────────
    // Driven on the cycle AFTER the bin was sent to range_coder
    output reg                 upd_valid,
    output reg  [CTX_ID_W-1:0] upd_ctx_id,
    output reg                 upd_bin,

    // ── range_coder regular port ─────────────────────────────────────────────
    // HM: pLPS / range update path (context-coded bins)
    output reg                 rc_bin_valid,
    output reg                 rc_bin_value,
    output reg  [5:0]          rc_pstate,    // pStateIdx to range_coder
    output reg                 rc_valmps,    // valMPS    to range_coder
    input  wire                rc_bin_ready, // range_coder can accept (backpressure)

    // ── range_coder bypass (EP) port ─────────────────────────────────────────
    // HM: encodeBinEP() → low = (low<<1) + (bin ? range : 0)
    output reg                 rc_ep_valid
);

    // =========================================================================
    // Internal registers
    // =========================================================================

    // =========================================================================
    // Context state extraction (combinational from rd_state)
    // rd_state = {pStateIdx[5:0], valMPS}  (7-bit, from ctx_model_store)
    // =========================================================================
    wire [5:0] cur_pstate = rd_state[6:1];  // HM: m_ucState >> 1
    wire        cur_valmps = rd_state[0];    // HM: m_ucState & 1

    // =========================================================================
    // Readiness: can accept a new bin when:
    //   - range_coder is ready (rc_bin_ready)
    //   - ctx store is not initializing
    //   - no pending write-back stall (write-back is non-blocking; no stall needed
    //     unless there is a RAW hazard)
    // =========================================================================
    wire raw_hazard   = !is_ep && upd_valid && (ctx_id == upd_ctx_id);
    wire can_dispatch = !init_busy && !raw_hazard;

    assign rd_ctx_id  = ctx_id;   // always present ctx_id for combinational read
    assign bin_rdy_out = can_dispatch && rc_bin_ready;

    // =========================================================================
    // Main pipeline: ACCEPT stage
    // Runs combinationally each clock; registered output goes to range_coder
    // =========================================================================
    always @* begin
        rc_bin_valid = 1'b0;
        rc_ep_valid  = 1'b0;
        rc_bin_value = bin_value;
        rc_pstate    = cur_pstate;
        rc_valmps    = cur_valmps;

        if (bin_valid && can_dispatch) begin
            if (is_ep) begin
                rc_ep_valid  = 1'b1;
            end else begin
                rc_bin_valid = 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            upd_valid     <= 1'b0;
            upd_ctx_id    <= {CTX_ID_W{1'b0}};
            upd_bin       <= 1'b0;
        end else begin
            // ── Default: deassert single-cycle pulses ──────────────────────
            upd_valid    <= 1'b0;

            // ── Stage T: Accept and dispatch new bin ───────────────────────
            if (bin_valid && bin_rdy_out) begin
                if (!is_ep) begin
                    // Schedule write-back for T+1
                    upd_valid    <= 1'b1;
                    upd_ctx_id   <= ctx_id;
                    upd_bin      <= bin_value;
                end
            end
        end
    end

    // =========================================================================
    // Simulation assertions
    // =========================================================================
    // synthesis translate_off

    // RAW hazard monitor: warn if consecutive bins hit same non-EP ctx
    reg [CTX_ID_W-1:0] prev_ctx_id = 0;
    reg                 prev_valid_nonep = 0;

    always @(posedge clk) begin
        if (bin_valid && bin_rdy_out) begin
            if (!is_ep && prev_valid_nonep && (ctx_id == prev_ctx_id)) begin
                // Same ctx back-to-back: verify write-back resolves before next read
                // (Should be fine by RTL analysis, but flag for debug)
                $display("INFO  [bin_encoder] consecutive same-ctx bins: ctx=%0d at t=%0t",
                         ctx_id, $time);
            end
            prev_ctx_id       <= ctx_id;
            prev_valid_nonep  <= !is_ep;
        end else begin
            prev_valid_nonep  <= 1'b0;
        end

        // Removed spammy warning

        if (rc_bin_valid && rc_bin_ready)
            $display("TRACE [bin_encoder] bin=%0d ctx=%0d ps=%0d vmps=%0d at t=%0t",
                     rc_bin_value, upd_ctx_id, rc_pstate, rc_valmps, $time);
    end

    initial begin
        $display("INFO  [bin_encoder] CTX_ID_W=%0d", CTX_ID_W);
    end
    // synthesis translate_on

endmodule