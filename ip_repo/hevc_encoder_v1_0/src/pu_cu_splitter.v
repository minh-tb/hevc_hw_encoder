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
//     tu_split_flag comes back from residual coding feedback
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
    input  wire [2:0]   part_mode,      // PART_2Nx2N..PART_nRx2N
    input  wire         skip_flag,      // merge skip (no residual)

    //-------------------------------------------------------------------------
    // PU output stream → intra_pred_top / me_top
    //-------------------------------------------------------------------------
    output reg          pu_valid,
    input  wire         pu_ready,

    output reg  [5:0]   pu_x,           // PU top-left in CTU
    output reg  [5:0]   pu_y,

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
    output reg          tu_is_last_in_cu
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
    localparam TU_STACK_W     = 6 + 6 + 3 + 3 + 2;   // 20 bits

    reg [TU_STACK_W-1:0] tu_stack [0:TU_STACK_DEPTH-1];
    reg [4:0]             tu_sp;

    wire [5:0] tu_top_x       = tu_stack[tu_sp-1][19:14];
    wire [5:0] tu_top_y       = tu_stack[tu_sp-1][13:8];
    wire [2:0] tu_top_log2    = tu_stack[tu_sp-1][7:5];
    wire [2:0] tu_top_depth   = tu_stack[tu_sp-1][4:2];
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

    // Latch current CU
    reg [5:0]  lcu_x, lcu_y;
    reg [6:0]  lcu_size;
    reg [1:0]  lcu_depth;
    reg [2:0]  lcu_part_mode;
    reg        lcu_skip;
    reg [2:0]  lcu_num_pus;

    assign cu_ready         = (state == S_IDLE);
    assign tu_split_fb_ready= (state == S_TU_WAIT);

    // Max TU depth allowed from config
    wire [2:0] max_tu_depth = 3'd3;

    // TU size log2 from stack
    wire [2:0] tu_cur_log2 = tu_top_log2;
    wire       tu_can_split = (tu_top_comp == 2'd0) && 
                              (tu_cur_log2 > 3'd2) &&
                              (tu_top_depth < max_tu_depth);
    wire       tu_must_split= (tu_top_comp == 2'd0) &&
                              (tu_cur_log2 > 3'd5);

    integer ti;
    reg [2:0]  init_log2;
    reg [25:0] geom;
    reg [5:0]  cx, cy;
    reg [2:0]  child_log2;
    reg [5:0]  child_half;
    reg [2:0]  child_depth;
    reg [2:0]  chr_log2;
    reg [5:0]  chr_x, chr_y;

    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            pu_valid    <= 1'b0;
            tu_valid    <= 1'b0;
            pu_idx_cnt  <= 2'd0;
            tu_sp       <= 5'd0;
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
                        lcu_part_mode  <= part_mode;
                        lcu_skip       <= skip_flag;
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
                                // $clog2 on variable not supported in Quartus II 13;
                                // use casez lookup (lcu_size is always power-of-2, cap at 5)
                                casez (lcu_size)
                                    7'b1??????: init_log2 = 3'd5; // 64 → log2=6, capped to 5
                                    7'b01?????: init_log2 = 3'd5; // 32 → 5
                                    7'b001????: init_log2 = 3'd4; // 16 → 4
                                    7'b0001???: init_log2 = 3'd3; // 8  → 3
                                    default:    init_log2 = 3'd3;
                                endcase
                                $display("Time=%0t: [pu_cu_splitter] S_PU_OUT lcu_size=%0d init_log2=%0d", $time, lcu_size, init_log2);
                                if (lcu_size == 7'd64) begin
                                    tu_stack[3] <= {lcu_x,                 lcu_y,                 3'd5, 3'd1, 2'd0}; // TL
                                    tu_stack[2] <= {lcu_x + 6'd32, lcu_y,                 3'd5, 3'd1, 2'd0}; // TR
                                    tu_stack[1] <= {lcu_x,                 lcu_y + 6'd32, 3'd5, 3'd1, 2'd0}; // BL
                                    tu_stack[0] <= {lcu_x + 6'd32, lcu_y + 6'd32, 3'd5, 3'd1, 2'd0}; // BR
                                    tu_sp       <= 5'd4;
                                end else begin
                                    tu_stack[0]  <= {lcu_x, lcu_y, init_log2, 3'd0, 2'd0}; // comp=Y
                                    tu_sp        <= 5'd1;
                                end
                                state        <= S_TU_EVAL;
                            end
                        end else begin
                            geom  = pu_geom(lcu_part_mode, pu_idx_cnt[1:0], lcu_size, half, qrtr, three_qrtr);
                            pu_valid      <= 1'b1;
                            pu_x          <= lcu_x + geom[25:20];
                            pu_y          <= lcu_y + geom[19:14];
                            
                            pu_idx_cnt <= pu_idx_cnt + 2'd1;
                        end
                    end
                end

                //--------------------------------------------------------------
                // S_TU_EVAL: check if top TU needs splitting
                //--------------------------------------------------------------
                S_TU_EVAL: begin
                    tu_valid <= 1'b0;
                    if (tu_sp == 5'd0) begin
                        // All TUs for all components processed
                        state <= S_IDLE;
                    end else if (tu_must_split) begin
                        // Force split — TU too large
                        tu_sp        <= tu_sp - 5'd1;
                        // Push 4 children
                        begin
                            cx         = tu_top_x;
                            cy         = tu_top_y;
                            child_log2 = tu_top_log2 - 3'd1;
                            child_half = 6'd1 << child_log2;
                            child_depth = tu_top_depth + 3'd1;

                            tu_stack[tu_sp-1+3] <= {cx,            cy,            child_log2, child_depth, tu_top_comp}; // TL placed at top (Child 0)
                            tu_stack[tu_sp-1+2] <= {cx+child_half, cy,            child_log2, child_depth, tu_top_comp}; // TR (Child 1)
                            tu_stack[tu_sp-1+1] <= {cx,            cy+child_half, child_log2, child_depth, tu_top_comp}; // BL (Child 2)
                            tu_stack[tu_sp-1]   <= {cx+child_half, cy+child_half, child_log2, child_depth, tu_top_comp}; // BR (Child 3)
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

                //--------------------------------------------------------------
                // S_TU_WAIT: waiting for split feedback
                //--------------------------------------------------------------
                S_TU_WAIT: begin
                    $display("Time=%0t: [pu_cu_splitter] S_TU_WAIT valid=%0b flag=%0b", $time, tu_split_fb_valid, tu_split_fb_flag);
                    if (tu_split_fb_valid) begin
                        if (tu_split_fb_flag) begin
                            // Split this TU
                            begin
                                cx         = tu_top_x;
                                cy         = tu_top_y;
                                child_log2 = tu_top_log2 - 3'd1;
                                child_half = 6'd1 << child_log2;
                                child_depth = tu_top_depth + 3'd1;

                                tu_stack[tu_sp-1+3] <= {cx,            cy,            child_log2, child_depth, tu_top_comp}; // TL placed at top (Child 0)
                                tu_stack[tu_sp-1+2] <= {cx+child_half, cy,            child_log2, child_depth, tu_top_comp}; // TR (Child 1)
                                tu_stack[tu_sp-1+1] <= {cx,            cy+child_half, child_log2, child_depth, tu_top_comp}; // BL (Child 2)
                                tu_stack[tu_sp-1]   <= {cx+child_half, cy+child_half, child_log2, child_depth, tu_top_comp}; // BR (Child 3)
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
                    if (tu_ready) begin
$display("Time=%0t: [pu_cu_splitter] S_TU_OUT outputting tu_size_log2=%0d tu_comp=%0d", $time, tu_top_log2, tu_top_comp);
                        // Output this TU
                        tu_valid          <= 1'b1;
                        tu_x              <= tu_top_x;
                        tu_y              <= tu_top_y;
                        tu_size_log2      <= tu_top_log2;
                        tu_comp           <= tu_top_comp;

                        // Pop this TU
                        tu_sp <= tu_sp - 5'd1;

                        // After luma TU, push chroma TUs at same position
                        // HM: Y first, then Cb, then Cr per TU node
                        if (tu_top_comp == 2'd0) begin
                            // Only push Chroma if:
                            // 1) Size is > 4x4 (log2 > 2)
                            // 2) Size is 4x4 AND it is the last 4x4 in the 8x8 parent (x[2]==1 && y[2]==1)
                            if (tu_top_log2 > 3'd2 || (tu_top_x[2] == 1'b1 && tu_top_y[2] == 1'b1)) begin
                                
                                // Chroma size is half luma, minimum 4x4
                                chr_log2 = (tu_top_log2 > 3'd2) ? (tu_top_log2 - 3'd1) : 3'd2;
                                
                                // If we are at the 4th 4x4 block, Chroma coordinates must point to the 8x8 base
                                // For 4:2:0, chroma coords are half of luma coords
                                chr_x = (tu_top_log2 == 3'd2) ? ((tu_top_x & ~6'd4) >> 1) : (tu_top_x >> 1);
                                chr_y = (tu_top_log2 == 3'd2) ? ((tu_top_y & ~6'd4) >> 1) : (tu_top_y >> 1);

                                tu_stack[tu_sp]     <= {chr_x, chr_y, chr_log2, tu_top_depth, 2'd1}; // Cb
                                tu_stack[tu_sp-1]   <= {chr_x, chr_y, chr_log2, tu_top_depth, 2'd2}; // Cr
                                tu_sp <= tu_sp + 5'd1;  // net: -1 + 2 = +1
                            end
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
        end
    end
    // synthesis translate_on

endmodule