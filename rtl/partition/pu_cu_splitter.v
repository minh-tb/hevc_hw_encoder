//=============================================================================
// pu_cu_splitter.v
// PU/TU Split Within a Leaf CU
//
// Mapped from HM source:
//   TLibCommon/TComTU.cpp         — TComTU transform unit tree traversal
//   TLibEncoder/TEncCu.cpp        — xCheckRDCostInter/xCheckRDCostIntra
//   TLibEncoder/TEncSearch.cpp    — xIntraSearch, xMotionEstimation
//
// HEVC spec:
//   Section 7.3.8.6  coding_unit() — part_mode, pred_mode
//   Section 7.3.8.8  prediction_unit()
//   Section 7.3.8.9  pcm_sample() (skipped — PCM disabled)
//   Section 7.3.8.10 transform_tree()
//
// Function:
//   Given a leaf CU (from ctu_partitioner + mode_decision), generates:
//     1. PU stream — one or more prediction units based on part_mode
//     2. TU stream — transform units based on TU quadtree depth
//
// PU partition modes (config: AMP_ENABLE=1):
//   PART_2Nx2N (0): 1 PU  = full CU size          [always valid]
//   PART_2NxN  (1): 2 PUs = top/bottom halves      [inter only]
//   PART_Nx2N  (2): 2 PUs = left/right halves      [inter only]
//   PART_NxN   (3): 4 PUs = quarter CU             [intra: 8x8 only]
//   PART_2NxnU (4): 2 PUs asymmetric top-small     [AMP inter only]
//   PART_2NxnD (5): 2 PUs asymmetric bottom-small  [AMP inter only]
//   PART_nLx2N (6): 2 PUs asymmetric left-small    [AMP inter only]
//   PART_nRx2N (7): 2 PUs asymmetric right-small   [AMP inter only]
//
// TU quadtree:
//   Config: QuadtreeTUMaxDepthInter=3, QuadtreeTUMaxDepthIntra=3
//           QuadtreeTULog2MaxSize=5 (32x32), QuadtreeTULog2MinSize=2 (4x4)
//   TU split depth relative to PU size:
//     tu_split_flag comes back from residual coding (rdoq_simple feedback)
//     If not split: single TU = PU size (clamped to TU_SIZE_MAX=32)
//     If split: recurse until TU_SIZE_MIN=4 or max depth reached
//
// Output streams:
//   PU stream: pu_valid/pu_ready with PU geometry + list context
//   TU stream: tu_valid/tu_ready with TU geometry for dct_top
//   Both in Z-scan order within the CU
//=============================================================================

`include "parameter_pkg.vh"
`include "hevc_interfaces.vh"

module pu_cu_splitter (
    input  wire         clk,
    input  wire         rst_n,

    //-------------------------------------------------------------------------
    // CU input from mode_decision (leaf CU with decisions made)
    //-------------------------------------------------------------------------
    input  wire         cu_valid,
    output wire         cu_ready,

    input  wire [5:0]   cu_x,           // CU top-left in CTU (pixels)
    input  wire [5:0]   cu_y,
    input  wire [6:0]   cu_size,        // 8,16,32,64
    input  wire [1:0]   cu_depth,       // 0..3
    input  wire         pred_mode,      // PRED_INTRA=1, PRED_INTER=0
    input  wire [2:0]   part_mode,      // PART_2Nx2N..PART_nRx2N
    input  wire         skip_flag,      // merge skip (no residual)
    input  wire [5:0]   qp,
    // CTU context passthrough
    input  wire [15:0]  cu_ctu_addr,
    input  wire [9:0]   cu_poc,
    input  wire [1:0]   cu_slice_type,

    //-------------------------------------------------------------------------
    // PU output stream → intra_pred_top / me_top
    //-------------------------------------------------------------------------
    output reg          pu_valid,
    input  wire         pu_ready,

    output reg  [5:0]   pu_x,           // PU top-left in CTU
    output reg  [5:0]   pu_y,
    output reg  [6:0]   pu_w,           // PU width
    output reg  [6:0]   pu_h,           // PU height
    output reg  [1:0]   pu_idx,         // PU index within CU (0..3)
    output reg          pu_pred_mode,
    output reg  [2:0]   pu_part_mode,
    output reg          pu_is_last_in_cu, // last PU of this CU
    output reg  [5:0]   pu_qp,
    output reg  [15:0]  pu_ctu_addr,
    output reg  [9:0]   pu_poc,
    output reg  [1:0]   pu_slice_type,

    //-------------------------------------------------------------------------
    // TU split feedback (from residual coding — does TU need splitting?)
    //-------------------------------------------------------------------------
    input  wire         tu_split_fb_valid,
    input  wire         tu_split_fb_flag,   // 1=split this TU
    output wire         tu_split_fb_ready,

    //-------------------------------------------------------------------------
    // TU output stream → dct_top
    //-------------------------------------------------------------------------
    output reg          tu_valid,
    input  wire         tu_ready,

    // TU_INFO_BUS_SIGNALS
    output reg  [5:0]   tu_x,           // TU top-left in CTU
    output reg  [5:0]   tu_y,
    output reg  [2:0]   tu_size_log2,   // 2=4x4 .. 5=32x32
    output reg  [1:0]   tu_comp,        // 0=Y, 1=Cb, 2=Cr
    output reg          tu_transform_skip,
    output reg          tu_is_last_in_cu,
    output reg  [5:0]   tu_qp,
    output reg  [15:0]  tu_ctu_addr
);

    //-------------------------------------------------------------------------
    // PU geometry computation
    // Given cu_size and part_mode, compute each PU's x,y,w,h
    //
    // AMP sizes (HM TComRom.cpp g_puOffset):
    //   2NxnU: top PU h = N/2, bottom h = 3N/2
    //   2NxnD: top PU h = 3N/2, bottom h = N/2
    //   nLx2N: left PU w = N/2, right w = 3N/2
    //   nRx2N: left PU w = 3N/2, right w = N/2
    //   where N = cu_size/2
    //-------------------------------------------------------------------------
    wire [6:0] half  = {1'b0, cu_size[6:1]};     // cu_size/2
    wire [6:0] qrtr  = {2'b0, cu_size[6:2]};     // cu_size/4
    wire [6:0] three_qrtr = cu_size - qrtr;       // 3*cu_size/4

    //-------------------------------------------------------------------------
    // PU geometry LUT — indexed by (part_mode, pu_idx)
    // Returns {pu_x_off, pu_y_off, pu_w, pu_h} relative to CU top-left
    //
    // Packed as {x_off[5:0], y_off[5:0], w[6:0], h[6:0]} = 26 bits
    //-------------------------------------------------------------------------
    function automatic [25:0] pu_geom;
        input [2:0] pm;
        input [1:0] idx;
        input [6:0] N;      // cu_size
        input [6:0] H;      // half
        input [6:0] Q;      // quarter
        input [6:0] TQ;     // three_quarter
        reg [5:0] px, py;
        reg [6:0] pw, ph;
        begin
            px = 6'd0; py = 6'd0; pw = N; ph = N;  // defaults
            case (pm)
                3'd0: begin pw=N;  ph=N;  px=6'd0; py=6'd0; end
                3'd1: begin
                    pw=N; ph=H[5:0];
                    px=6'd0; py= (idx==2'd0) ? 6'd0 : H[5:0];
                end
                3'd2: begin
                    pw=H[5:0]; ph=N;
                    py=6'd0; px= (idx==2'd0) ? 6'd0 : H[5:0];
                end
                3'd3: begin
                    pw=H[5:0]; ph=H[5:0];
                    px= idx[0] ? H[5:0] : 6'd0;
                    py= idx[1] ? H[5:0] : 6'd0;
                end
                3'd4: begin
                    pw=N;
                    ph= (idx==2'd0) ? Q[5:0] : TQ[5:0];
                    px=6'd0;
                    py= (idx==2'd0) ? 6'd0   : Q[5:0];
                end
                3'd5: begin
                    pw=N;
                    ph= (idx==2'd0) ? TQ[5:0] : Q[5:0];
                    px=6'd0;
                    py= (idx==2'd0) ? 6'd0    : TQ[5:0];
                end
                3'd6: begin
                    ph=N;
                    pw= (idx==2'd0) ? Q[5:0] : TQ[5:0];
                    py=6'd0;
                    px= (idx==2'd0) ? 6'd0   : Q[5:0];
                end
                3'd7: begin
                    ph=N;
                    pw= (idx==2'd0) ? TQ[5:0] : Q[5:0];
                    py=6'd0;
                    px= (idx==2'd0) ? 6'd0    : TQ[5:0];
                end
                default: begin pw=N; ph=N; px=6'd0; py=6'd0; end
            endcase
            pu_geom = {px, py, pw, ph};
        end
    endfunction

    //-------------------------------------------------------------------------
    // TU quadtree stack
    // Each entry: {x[5:0], y[5:0], size_log2[2:0], comp[1:0]} = 17 bits
    // Max entries: depth 3 × 3 siblings × 3 components = 27 entries
    // Use 32-entry stack
    //-------------------------------------------------------------------------
    localparam TU_STACK_DEPTH = 32;
    localparam TU_STACK_W     = 6 + 6 + 3 + 2;   // 17 bits

    reg [TU_STACK_W-1:0] tu_stack [0:TU_STACK_DEPTH-1];
    reg [4:0]             tu_sp;

    wire [5:0] tu_top_x       = tu_stack[tu_sp-1][TU_STACK_W-1:TU_STACK_W-6];
    wire [5:0] tu_top_y       = tu_stack[tu_sp-1][TU_STACK_W-7:TU_STACK_W-12];
    wire [2:0] tu_top_log2    = tu_stack[tu_sp-1][TU_STACK_W-13:TU_STACK_W-15];
    wire [1:0] tu_top_comp    = tu_stack[tu_sp-1][1:0];

    //-------------------------------------------------------------------------
    // State machine
    //-------------------------------------------------------------------------
    localparam S_IDLE    = 3'd0;
    localparam S_PU_OUT  = 3'd1;   // outputting PU stream
    localparam S_TU_EVAL = 3'd2;   // presenting TU to split feedback
    localparam S_TU_WAIT = 3'd3;   // waiting for tu_split_fb
    localparam S_TU_OUT  = 3'd4;   // outputting leaf TU

    reg [2:0]  state;
    reg [2:0]  pu_idx_cnt;         // which PU we're currently outputting
    reg [2:0]  tu_depth_rel;       // TU depth relative to CU (0=CU size)

    // Latch current CU
    reg [5:0]  lcu_x, lcu_y;
    reg [6:0]  lcu_size;
    reg [1:0]  lcu_depth;
    reg        lcu_pred_mode;
    reg [2:0]  lcu_part_mode;
    reg        lcu_skip;
    reg [5:0]  lcu_qp;
    reg [15:0] lcu_ctu_addr;
    reg [9:0]  lcu_poc;
    reg [1:0]  lcu_slice_type;
    reg [2:0]  lcu_num_pus;

    assign cu_ready         = (state == S_IDLE);
    assign tu_split_fb_ready= (state == S_TU_WAIT);

    // Max TU depth allowed from config
    wire [2:0] max_tu_depth = lcu_pred_mode ? 3'd3 : 3'd3;

    // TU size log2 from stack
    wire [2:0] tu_cur_log2 = tu_top_log2;
    wire       tu_can_split = (tu_top_comp == 2'd0) && 
                              (tu_cur_log2 > 3'd2) &&
                              (tu_depth_rel < max_tu_depth);
    wire       tu_must_split= (tu_top_comp == 2'd0) &&
                              (tu_cur_log2 > 3'd5);

    integer ti;
    reg [2:0]  init_log2;
    reg [25:0] geom;
    reg [5:0]  cx, cy;
    reg [2:0]  child_log2;
    reg [5:0]  child_half;
    reg [2:0]  chr_log2;

    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            pu_valid    <= 1'b0;
            tu_valid    <= 1'b0;
            pu_idx_cnt  <= 2'd0;
            tu_sp       <= 5'd0;
            tu_depth_rel<= 3'd0;
            for (ti = 0; ti < TU_STACK_DEPTH; ti = ti + 1)
                tu_stack[ti] <= {TU_STACK_W{1'b0}};
        end else begin
            case (state)
                //--------------------------------------------------------------
                S_IDLE: begin
                    if (cu_valid) begin
                        // Latch CU
                        lcu_x          <= cu_x;
                        lcu_y          <= cu_y;
                        lcu_size       <= cu_size;
                        lcu_depth      <= cu_depth;
                        lcu_pred_mode  <= pred_mode;
                        lcu_part_mode  <= part_mode;
                        lcu_skip       <= skip_flag;
                        lcu_qp         <= qp;
                        lcu_ctu_addr   <= cu_ctu_addr;
                        lcu_poc        <= cu_poc;
                        lcu_slice_type <= cu_slice_type;
                        lcu_num_pus    <= (part_mode == 3'd0) ? 3'd1 :
                                          (part_mode == 3'd3) ? 3'd4 : 3'd2;
                        pu_idx_cnt     <= 2'd0;
                        state          <= S_PU_OUT;
                    end
                end

                //--------------------------------------------------------------
                // S_PU_OUT: stream PUs one at a time
                //--------------------------------------------------------------
                S_PU_OUT: begin
                    if (!pu_valid || pu_ready) begin
                        if (pu_idx_cnt == lcu_num_pus) begin
                            // Last PU — move to TU phase (unless skip)
                            pu_valid <= 1'b0;
                            if (lcu_skip) begin
                                state <= S_IDLE;  // skip: no residual TUs
                            end else begin
                                // Initialize TU stack with CU-level entry (luma first)
                                // TU size capped at TU_SIZE_MAX (32x32)
                                init_log2 = ($clog2(lcu_size) > 3'd5) ?
                                             3'd5 :
                                             $clog2(lcu_size[6:0]);
                                tu_stack[0]  <= {lcu_x, lcu_y, init_log2, 2'd0}; // comp=Y
                                tu_sp        <= 5'd1;
                                tu_depth_rel <= 3'd0;
                                state        <= S_TU_EVAL;
                            end
                        end else begin
                            geom  = pu_geom(lcu_part_mode, pu_idx_cnt[1:0], lcu_size, half, qrtr, three_qrtr);
                            pu_valid      <= 1'b1;
                            pu_x          <= lcu_x + geom[25:20];
                            pu_y          <= lcu_y + geom[19:14];
                            pu_w          <= geom[13:7];
                            pu_h          <= geom[6:0];
                            pu_idx        <= pu_idx_cnt[1:0];
                            pu_pred_mode  <= lcu_pred_mode;
                            pu_part_mode  <= lcu_part_mode;
                            pu_qp         <= lcu_qp;
                            pu_ctu_addr   <= lcu_ctu_addr;
                            pu_poc        <= lcu_poc;
                            pu_slice_type <= lcu_slice_type;
                            pu_is_last_in_cu <= (pu_idx_cnt == lcu_num_pus - 3'd1);
                            
                            pu_idx_cnt <= pu_idx_cnt + 2'd1;
                        end
                    end
                end

                //--------------------------------------------------------------
                // S_TU_EVAL: check if top TU needs splitting
                //--------------------------------------------------------------
                S_TU_EVAL: begin
                    if (tu_valid && !tu_ready) begin
                        // wait for downstream to accept previous TU
                    end else begin
                        tu_valid <= 1'b0;
                        if (tu_sp == 5'd0) begin
                        // All TUs for all components processed
                        state <= S_IDLE;
                    end else if (tu_must_split) begin
                        // Force split — TU too large
                        tu_sp        <= tu_sp - 5'd1;
                        tu_depth_rel <= tu_depth_rel + 3'd1;
                        // Push 4 children
                        begin
                            cx         = tu_top_x;
                            cy         = tu_top_y;
                            child_log2 = tu_top_log2 - 3'd1;
                            child_half = 6'd1 << child_log2;

                            tu_stack[tu_sp-1+3] <= {cx,            cy,            child_log2, tu_top_comp}; // TL placed at top (Child 0)
                            tu_stack[tu_sp-1+2] <= {cx+child_half, cy,            child_log2, tu_top_comp}; // TR (Child 1)
                            tu_stack[tu_sp-1+1] <= {cx,            cy+child_half, child_log2, tu_top_comp}; // BL (Child 2)
                            tu_stack[tu_sp-1]   <= {cx+child_half, cy+child_half, child_log2, tu_top_comp}; // BR (Child 3)
                            tu_sp <= tu_sp + 5'd3;
                        end
                    end else if (!tu_can_split) begin
                        // Leaf TU (can't split further) — output directly
                        state <= S_TU_OUT;
                    end else begin
                        // Ask residual coder if splitting needed
                        state <= S_TU_WAIT;
                    end
                    end
                end

                //--------------------------------------------------------------
                // S_TU_WAIT: waiting for split feedback
                //--------------------------------------------------------------
                S_TU_WAIT: begin
                    if (tu_split_fb_valid) begin
                        if (tu_split_fb_flag) begin
                            // Split this TU
                            tu_depth_rel <= tu_depth_rel + 3'd1;
                            begin
                                cx         = tu_top_x;
                                cy         = tu_top_y;
                                child_log2 = tu_top_log2 - 3'd1;
                                child_half = 6'd1 << child_log2;

                                tu_stack[tu_sp-1+3] <= {cx,            cy,            child_log2, tu_top_comp}; // TL placed at top (Child 0)
                                tu_stack[tu_sp-1+2] <= {cx+child_half, cy,            child_log2, tu_top_comp}; // TR (Child 1)
                                tu_stack[tu_sp-1+1] <= {cx,            cy+child_half, child_log2, tu_top_comp}; // BL (Child 2)
                                tu_stack[tu_sp-1]   <= {cx+child_half, cy+child_half, child_log2, tu_top_comp}; // BR (Child 3)
                                tu_sp <= tu_sp + 5'd3;
                            end
                            state <= S_TU_EVAL;
                        end else begin
                            // Leaf TU
                            state <= S_TU_OUT;
                        end
                    end
                end

                //--------------------------------------------------------------
                // S_TU_OUT: output leaf TU, then handle chroma / next TU
                //--------------------------------------------------------------
                S_TU_OUT: begin
                    if (!tu_valid || tu_ready) begin
                        // Output this TU
                        tu_valid          <= 1'b1;
                        tu_x              <= tu_top_x;
                        tu_y              <= tu_top_y;
                        tu_size_log2      <= tu_top_log2;
                        tu_comp           <= tu_top_comp;
                        tu_transform_skip <= 1'b0;  // mode_decision sets this
                        tu_qp             <= lcu_qp;
                        tu_ctu_addr       <= lcu_ctu_addr;

                        // Pop this TU
                        tu_sp <= tu_sp - 5'd1;

                        // After luma TU, push chroma TUs at same position
                        // HM: Y first, then Cb, then Cr per TU node
                        if (tu_top_comp == 2'd0) begin
                            // Push Cr then Cb (Cb processed first due to stack)
                            // Chroma TU is half luma size in each dimension (4:2:0)
                            // but same log2 if already at minimum
                            chr_log2 = (tu_top_log2 > 3'd2) ?
                                        (tu_top_log2 - 3'd1) : tu_top_log2;

                            tu_stack[tu_sp]     <= {tu_top_x, tu_top_y, chr_log2, 2'd1}; // Cb placed at top
                            tu_stack[tu_sp-1]   <= {tu_top_x, tu_top_y, chr_log2, 2'd2}; // Cr placed at bottom
                            tu_sp <= tu_sp + 5'd1;  // net: -1 + 2 = +1
                        end

                        // is_last: after pop and possible chroma push
                        tu_is_last_in_cu <= (tu_sp == 5'd1) &&
                                            (tu_top_comp == 2'd2);

                        state <= S_TU_EVAL;
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
        if (rst_n) begin
            if (tu_sp >= TU_STACK_DEPTH - 2)
                $display("ERROR [pu_cu_splitter] TU stack overflow sp=%0d time=%0t",
                         tu_sp, $time);
            if (cu_valid && cu_ready && !(1) &&
                (part_mode >= 3'd4))
                $display("WARN  [pu_cu_splitter] AMP mode %0d but AMP_ENABLE=0",
                         part_mode);
        end
    end
    // synthesis translate_on

endmodule