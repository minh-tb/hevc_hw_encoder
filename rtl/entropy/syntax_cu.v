//=============================================================================
// syntax_cu.v
// CU-Level CABAC Syntax Element Encoder
//
// Mapped from HM source:
//   TLibEncoder/TEncSbac.cpp ::
//     codeSplitFlag()    → split_cu_flag
//     codeSkipFlag()     → cu_skip_flag
//     codeMergeFlag()    → merge_flag
//     codeMergeIndex()   → merge_idx
//     codePredMode()     → pred_mode_flag
//     codePartSize()     → part_mode
//     codeRootCbf()      → rqt_root_cbf (no_residual_data_flag)
//   TLibCommon/TComDataCU.h :: CU fields, getCtxSkipFlag()
//
// HEVC CU syntax element encoding order (HM TEncSbac::codeBegin/CU):
//
//   split_cu_flag               (always — at each quad-tree depth)
//   if not split:
//     if inter slice:
//       cu_skip_flag            (ctx depends on left/above skip flags)
//       if skip:
//         merge_idx             (first bin ctx=8, rest bypass EP)
//       else:
//         merge_flag            (ctx=7)
//         if merge:
//           merge_idx           (as above)
//         else:
//           pred_mode_flag      (ctx=9; 0=inter, 1=intra)
//           if inter:
//             part_mode         (ctx 10-13, unary)
//           else (intra):
//             part_mode=2Nx2N   (single bin=1, ctx=10)
//             rqt_root_cbf      (always 1 for intra; encode=bypass 1)
//     else (I-slice):
//       pred_mode_flag=1        (forced intra — often not coded, signaled by slice)
//       part_mode=2Nx2N
//       rqt_root_cbf
//
// Context index assignments (matching ctx_model_store.v):
//   [0..2]  SPLIT_FLAG  (ctx = depth)
//   [4..6]  SKIP_FLAG   (ctx = 4 + skip_ctx, skip_ctx from neighbors)
//   [7]     MERGE_FLAG
//   [8]     MERGE_IDX   (first bin only; remainder bypass EP)
//   [9]     PRED_MODE_FLAG
//   [10..13] PART_SIZE  (unary code, ctx = 10+bit_idx)
//
// Part mode encoding (HM codePartSize, inter non-skip non-merge):
//   SIZE_2Nx2N : {1}           (1 bin)
//   SIZE_2NxN  : {0, 1}        (2 bins)
//   SIZE_Nx2N  : {0, 0, 1}     (3 bins)
//   SIZE_NxN   : {0, 0, 0}     (3 bins, only at min CU size)
//   Intra SIZE_2Nx2N: {1}      (1 bin, ctx=10)
//
// Interface:
//   cu_valid         : pulse — start encoding this CU's syntax
//   cu_done          : pulse — all bins for this CU have been sent
//   CU fields        : depth, is_intra_slice, skip, merge, pred_intra,
//                      part_mode, merge_idx, skip_ctx, cbf
//   Bin output       : {bin_valid, bin_value, ctx_id, is_ep} → bin_encoder
//   Backpressure     : bin_rdy from bin_encoder (stall if 0)
//
// Pipeline:
//   One bin per clock when bin_rdy=1.
//   FSM steps through bin sequence; cu_done asserts one cycle after last bin.
//=============================================================================

`include "parameter_pkg.vh"

module syntax_cu #(
    parameter CTX_ID_W = 8      // context index width
)(
    input  wire        clk,
    input  wire        rst_n,

    // ── CU encoding request ───────────────────────────────────────────────
    input  wire        cu_valid,       // start encoding this CU
    output reg         cu_done,        // all CU bins sent to bin_encoder

    // ── CU parameters (held stable while cu_valid→cu_done) ───────────────
    input  wire [1:0]  cu_depth,       // quad-tree depth 0..3
    input  wire        cu_is_split,    // 1 = split CU (only split_flag encoded)
    input  wire        slice_is_intra, // 1 = I-slice (skip/merge not encoded)
    input  wire        cu_skip,        // cu_skip_flag value
    input  wire        cu_merge,       // merge_flag value (valid when !skip)
    input  wire [2:0]  cu_merge_idx,   // merge index 0..4 (if skip or merge)
    input  wire        cu_pred_intra,  // pred_mode_flag (1=intra, 0=inter)
    input  wire [1:0]  cu_part_mode,   // 0=2Nx2N,1=2NxN,2=Nx2N,3=NxN
    input  wire        cu_cbf,         // rqt_root_cbf (1=has residual)
    // Neighbor context for skip_flag (HM TComDataCU::getCtxSkipFlag)
    input  wire [1:0]  cu_skip_ctx,    // 0-2: counts of skip-flagged neighbors

    // ── Bin output → bin_encoder ──────────────────────────────────────────
    output reg                  bin_valid,
    output reg                  bin_value,
    output reg [CTX_ID_W-1:0]   bin_ctx_id,
    output reg                  bin_is_ep,
    input  wire                 bin_rdy     // backpressure from bin_encoder
);

    // =========================================================================
    // FSM state encoding
    // Each state outputs exactly one bin (or skips transparently if not needed)
    // =========================================================================
    localparam [4:0]
        S_IDLE        = 5'd0,
        S_SPLIT       = 5'd1,   // split_cu_flag
        S_SKIP        = 5'd2,   // cu_skip_flag            (inter only)
        S_MERGE_FLAG  = 5'd3,   // merge_flag              (inter, !skip)
        S_MERGE_IDX0  = 5'd4,   // merge_idx first bin     (ctx=8)
        S_MERGE_IDX1  = 5'd5,   // merge_idx[1] bypass EP
        S_MERGE_IDX2  = 5'd6,   // merge_idx[2] bypass EP
        S_MERGE_IDX3  = 5'd7,   // merge_idx[3] bypass EP
        S_PRED_MODE   = 5'd8,   // pred_mode_flag          (!skip, !merge inter or I-slice)
        S_PART0       = 5'd9,   // part_mode bin 0         (ctx=10)
        S_PART1       = 5'd10,  // part_mode bin 1         (ctx=11, if needed)
        S_PART2       = 5'd11,  // part_mode bin 2         (ctx=12, if needed)
        S_CBF         = 5'd12,  // rqt_root_cbf            (EP bypass)
        S_DONE        = 5'd13;

    reg [4:0] state;

    // =========================================================================
    // Context ID constants (matching ctx_model_store.v block assignments)
    // =========================================================================
    localparam CTX_SPLIT_0  = 8'd0;    // SPLIT_FLAG depth 0
    localparam CTX_SPLIT_1  = 8'd1;    // SPLIT_FLAG depth 1
    localparam CTX_SPLIT_2  = 8'd2;    // SPLIT_FLAG depth 2
    localparam CTX_SKIP_0   = 8'd4;    // SKIP_FLAG (no skip neighbors)
    localparam CTX_SKIP_1   = 8'd5;    // SKIP_FLAG (1 skip neighbor)
    localparam CTX_SKIP_2   = 8'd6;    // SKIP_FLAG (2 skip neighbors)
    localparam CTX_MERGE    = 8'd7;    // MERGE_FLAG
    localparam CTX_MERGE_IDX= 8'd8;    // MERGE_IDX first bin
    localparam CTX_PRED     = 8'd9;    // PRED_MODE_FLAG
    localparam CTX_PART_0   = 8'd10;   // PART_SIZE bin 0
    localparam CTX_PART_1   = 8'd11;   // PART_SIZE bin 1
    localparam CTX_PART_2   = 8'd12;   // PART_SIZE bin 2
    localparam CTX_CBF      = 8'd14;   // RQT_ROOT_CBF (assigned 14)

    // =========================================================================
    // Derived context for skip_flag: ctx = 4 + min(skip_ctx, 2)
    // HM: TComDataCU::getCtxSkipFlag() counts inter-coded left/above CUs
    // =========================================================================
    wire [CTX_ID_W-1:0] skip_ctx_id = CTX_SKIP_0 + {6'd0, cu_skip_ctx};

    // =========================================================================
    // Part mode encoding (HM codePartSize, unary prefix code):
    //   2Nx2N : first bin = 1
    //   2NxN  : {0, 1}
    //   Nx2N  : {0, 0, 1}
    //   NxN   : {0, 0, 0}
    // =========================================================================
    // Number of part_mode bins needed
    wire [1:0] n_part_bins = (cu_part_mode == 2'd0) ? 2'd1 :  // 2Nx2N: 1 bin
                             (cu_part_mode == 2'd1) ? 2'd2 :  // 2NxN:  2 bins
                                                      2'd3;   // Nx2N/NxN: 3 bins

    // =========================================================================
    // Main FSM — emits one bin per clock when bin_rdy=1
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            bin_valid <= 1'b0;
            cu_done   <= 1'b0;
        end else begin
            bin_valid <= 1'b0;
            cu_done   <= 1'b0;

            case (state)

            // ── IDLE: wait for encoding request ───────────────────────────
            S_IDLE: begin
                if (cu_valid) state <= S_SPLIT;
            end

            // ── SPLIT: split_cu_flag ───────────────────────────────────────
            // HM codeSplitFlag(): ctx = depth (0..2, capped at 2 per HEVC spec)
            // Always the first bin of any CU at any depth
            S_SPLIT: begin
                if (bin_rdy) begin
                    bin_valid  <= 1'b1;
                    bin_value  <= cu_is_split;
                    bin_ctx_id <= CTX_SPLIT_0 + {6'd0, cu_depth[1:0]};
                    bin_is_ep  <= 1'b0;
                    if (cu_is_split) begin
                        // Split CU — no further syntax at this depth
                        state <= S_DONE;
                    end else if (slice_is_intra) begin
                    // I-slice: no skip/merge/pred_mode, intra part_mode only at max depth
                    state <= (cu_depth == 2'd3) ? S_PART0 : S_DONE;
                    end else begin
                        // Inter slice: encode skip_flag
                        state <= S_SKIP;
                    end
                end
            end

            // ── SKIP: cu_skip_flag ────────────────────────────────────────
            // HM codeSkipFlag(): ctx = 4 + getCtxSkipFlag() (0..2)
            S_SKIP: begin
                if (bin_rdy) begin
                    bin_valid  <= 1'b1;
                    bin_value  <= cu_skip;
                    bin_ctx_id <= skip_ctx_id;
                    bin_is_ep  <= 1'b0;
                    if (cu_skip) begin
                        // Skip: encode merge_idx (skip is always a merge)
                        state <= S_MERGE_IDX0;
                    end else begin
                        state <= S_MERGE_FLAG;
                    end
                end
            end

            // ── MERGE_FLAG: merge_flag ─────────────────────────────────────
            // HM codeMergeFlag(): fixed ctx=7
            S_MERGE_FLAG: begin
                if (bin_rdy) begin
                    bin_valid  <= 1'b1;
                    bin_value  <= cu_merge;
                    bin_ctx_id <= CTX_MERGE;
                    bin_is_ep  <= 1'b0;
                    state      <= cu_merge ? S_MERGE_IDX0 : S_PRED_MODE;
                end
            end

            // ── MERGE_IDX0: first bin of merge_idx (ctx=8) ────────────────
            // HM codeMergeIndex():
            //   encodeBin(merge_idx != 0, ctx=MERGE_IDX)
            //   then EP bins for merge_idx > 1..numMerge-2
            S_MERGE_IDX0: begin
                if (bin_rdy) begin
                    bin_valid  <= 1'b1;
                    bin_value  <= (cu_merge_idx != 3'd0) ? 1'b1 : 1'b0;
                    bin_ctx_id <= CTX_MERGE_IDX;
                    bin_is_ep  <= 1'b0;
                    // If merge_idx=0: done; else encode remaining with EP
                    state      <= (cu_merge_idx == 3'd0) ? S_DONE : S_MERGE_IDX1;
                end
            end

            // ── MERGE_IDX1..3: bypass EP bins for merge_idx ──────────────
            // HM: for ui = 1 .. numMerge-2: encodeBinEP(merge_idx > ui)
            S_MERGE_IDX1: begin
                if (bin_rdy) begin
                    bin_valid  <= 1'b1;
                    bin_value  <= (cu_merge_idx > 3'd1) ? 1'b1 : 1'b0;
                    bin_is_ep  <= 1'b1;
                    bin_ctx_id <= 8'd0;    // EP: ctx ignored
                    state      <= (cu_merge_idx <= 3'd1) ? S_DONE : S_MERGE_IDX2;
                end
            end

            S_MERGE_IDX2: begin
                if (bin_rdy) begin
                    bin_valid  <= 1'b1;
                    bin_value  <= (cu_merge_idx > 3'd2) ? 1'b1 : 1'b0;
                    bin_is_ep  <= 1'b1;
                    bin_ctx_id <= 8'd0;
                    state      <= (cu_merge_idx <= 3'd2) ? S_DONE : S_MERGE_IDX3;
                end
            end

            S_MERGE_IDX3: begin
                if (bin_rdy) begin
                    bin_valid  <= 1'b1;
                    bin_value  <= (cu_merge_idx > 3'd3) ? 1'b1 : 1'b0;
                    bin_is_ep  <= 1'b1;
                    bin_ctx_id <= 8'd0;
                    state      <= S_DONE;
                end
            end

            // ── PRED_MODE: pred_mode_flag ─────────────────────────────────
            // HM codePredMode(): 1=intra, 0=inter; ctx=9
            // For I-slice: pred_mode is always 1 (intra), still encoded
            S_PRED_MODE: begin
                if (bin_rdy) begin
                    bin_valid  <= 1'b1;
                    bin_value  <= cu_pred_intra;    // 1=intra, 0=inter
                    bin_ctx_id <= CTX_PRED;
                    bin_is_ep  <= 1'b0;
                if (cu_pred_intra)
                    state <= (cu_depth == 2'd3) ? S_PART0 : S_DONE;
                else
                    state <= S_PART0;
                end
            end

            // ── PART0: part_mode first bin ────────────────────────────────
            // HM codePartSize(): unary code, ctx = 10+bit_idx
            // Intra always SIZE_2Nx2N → single bin=1
            // Inter: bin0 = (part_mode==2Nx2N ? 1 : 0)
            S_PART0: begin
                if (bin_rdy) begin
                    bin_valid  <= 1'b1;
                    bin_value  <= (cu_part_mode == 2'd0) ? 1'b1 : 1'b0;
                    bin_ctx_id <= CTX_PART_0;
                    bin_is_ep  <= 1'b0;
                // 2Nx2N → single bin done; intra also done
                if (cu_pred_intra)
                    state <= S_DONE;
                else if (cu_part_mode == 2'd0)
                        state <= S_CBF;
                    else
                        state <= S_PART1;
                end
            end

            // ── PART1: part_mode second bin ───────────────────────────────
            // 2NxN  → {0,1} → bin1=1 then done
            // Nx2N  → {0,0,1}
            // NxN   → {0,0,0}
            S_PART1: begin
                if (bin_rdy) begin
                    bin_valid  <= 1'b1;
                    bin_value  <= (cu_part_mode == 2'd1) ? 1'b1 : 1'b0; // 2NxN=1
                    bin_ctx_id <= CTX_PART_1;
                    bin_is_ep  <= 1'b0;
                    if (cu_part_mode == 2'd1)
                        state <= S_CBF;    // 2NxN done
                    else
                        state <= S_PART2;  // Nx2N or NxN
                end
            end

            // ── PART2: part_mode third bin ────────────────────────────────
            // Nx2N  → {0,0,1}  bin2=1
            // NxN   → {0,0,0}  bin2=0
            S_PART2: begin
                if (bin_rdy) begin
                    bin_valid  <= 1'b1;
                    bin_value  <= (cu_part_mode == 2'd2) ? 1'b1 : 1'b0; // Nx2N=1
                    bin_ctx_id <= CTX_PART_2;
                    bin_is_ep  <= 1'b0;
                    state      <= S_CBF;
                end
            end

            // ── CBF: rqt_root_cbf (no_residual_data_flag) ────────────────
            // HM codeQtRootCbf(): bypass EP
            // For intra: always cbf=1 (never skip residual)
            // For inter non-skip: cbf signals whether there is residual
            S_CBF: begin
                if (bin_rdy) begin
                    bin_valid  <= 1'b1;
                    bin_value  <= cu_cbf;
                bin_ctx_id <= CTX_CBF; // CABAC context, not EP
                bin_is_ep  <= 1'b0;
                    state      <= S_DONE;
                end
            end

            // ── DONE ─────────────────────────────────────────────────────
            S_DONE: begin
                cu_done <= 1'b1;
                state   <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Simulation assertions
    // =========================================================================
    // synthesis translate_off
    always @(posedge clk) begin
        if (cu_valid && state != S_IDLE)
            $display("WARN  [syntax_cu] cu_valid while busy (state=%0d) at t=%0t",
                     state, $time);
        if (cu_done)
            $display("INFO  [syntax_cu] CU done: depth=%0d split=%0d skip=%0d merge=%0d pred_intra=%0d part=%0d",
                     cu_depth, cu_is_split, cu_skip, cu_merge,
                     cu_pred_intra, cu_part_mode);
        // Verify ctx_id in valid range when emitting regular bins
        if (bin_valid && !bin_is_ep && bin_ctx_id >= 8'd154)
            $display("ERROR [syntax_cu] ctx_id=%0d out of range at t=%0t",
                     bin_ctx_id, $time);
    end
    initial $display("INFO  [syntax_cu] CTX_ID_W=%0d", CTX_ID_W);
    // synthesis translate_on

endmodule