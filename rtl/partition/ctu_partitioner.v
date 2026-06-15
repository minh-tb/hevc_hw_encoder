//=============================================================================
// ctu_partitioner.v
// CTU Quadtree CU Split Decision
//
// Mapped from HM source:
//   TLibEncoder/TEncCu.cpp
//   Void TEncCu::xCompressCU()  — recursive CU split decision
//   Void TEncCu::xEncodeCU()    — CU encoding after split decision
//
// HEVC spec: Section 7.3.8.1 (coding_quadtree)
//
// Function:
//   For each CTU (64×64), decides the quadtree CU partition structure.
//   Traverses depths 0→3 (64→32→16→8px) and for each CU decides:
//     split_flag = 1: divide into 4 sub-CUs (go deeper)
//     split_flag = 0: this CU is a leaf — pass to mode_decision
//
// Config:
//   MaxCUWidth     = 64   (depth 0)
//   MaxPartitionDepth = 4 (depths 0,1,2,3 → sizes 64,32,16,8)
//   MinCUSize      = 8    (depth 3 → always leaf, split_flag forced 0)
//
// Split decision (simplified — no RD cost here, that's in mode_decision):
//   This module outputs the CTU quadtree structure as a stream of CU
//   descriptors in Z-scan order (HM raster-to-Z conversion).
//   Actual split decision is made by mode_decision feedback.
//
// Z-scan (Morton code) order:
//   HM uses Z-scan within a CTU for CU traversal.
//   Z-scan maps 2D position to 1D index using bit-interleaving.
//   For a 64×64 CTU split to depth D:
//     D=0: 1 CU  at (0,0)
//     D=1: 4 CUs at (0,0),(32,0),(0,32),(32,32)
//     D=2: 16 CUs
//     D=3: 64 CUs at 8×8 positions
//
// Interface:
//   Input:  CTU descriptor from ctu_raster_scan
//   Output: stream of CU descriptors to mode_decision
//           Each CU: (cu_x, cu_y, cu_size, cu_depth) within CTU
//   Split feedback: mode_decision tells us whether to split each CU
//
// Pipeline:
//   Iterative — process one CU per cycle (depth-first Z-scan traversal)
//   A 64×64 fully-split CTU produces 64 leaf CUs (depth 3)
//   Worst case: 64 cycles per CTU
//=============================================================================

`include "parameter_pkg.vh"
`include "hevc_interfaces.vh"

module ctu_partitioner (
    input  wire         clk,
    input  wire         rst_n,

    //-------------------------------------------------------------------------
    // CTU input from ctu_raster_scan
    //-------------------------------------------------------------------------
    input  wire         ctu_valid,
    output wire         ctu_ready,

    //-------------------------------------------------------------------------
    // CU output stream to mode_decision
    //-------------------------------------------------------------------------
    output reg          cu_valid,
    input  wire         cu_ready,
    // CU_INFO_BUS_SIGNALS (subset — pred_mode and partition filled by mode_decision)
    output reg  [5:0]   cu_x,          // CU top-left x within CTU (pixels)
    output reg  [5:0]   cu_y,          // CU top-left y within CTU
    output reg  [6:0]   cu_size,       // 8, 16, 32, 64
    output reg  [1:0]   cu_depth,      // 0=64, 1=32, 2=16, 3=8
    output reg          cu_is_last_in_ctu,  // last leaf CU of this CTU

    //-------------------------------------------------------------------------
    // Split feedback from mode_decision
    // mode_decision evaluates each CU and returns split_flag
    //-------------------------------------------------------------------------
    input  wire         split_valid,    // mode_decision has decided
    input  wire         split_flag,     // 1=split this CU, 0=leaf
    output wire         split_ready     // we are ready for split decision
);

    //-------------------------------------------------------------------------
    // Traversal stack
    // Depth-first Z-scan traversal uses a stack of pending CUs.
    // Max depth = 4, branching factor = 4
    // Worst case stack depth: 3 levels × 3 pending siblings = 9 entries
    // Use 16-entry stack for safety.
    //
    // Each stack entry: {x[5:0], y[5:0], size[6:0], depth[1:0]} = 21 bits
    //-------------------------------------------------------------------------
    localparam STACK_DEPTH = 16;
    localparam STACK_W     = 6 + 6 + 7 + 2;    // 21 bits

    reg [STACK_W-1:0] stack [0:STACK_DEPTH-1];
    reg [3:0]         sp;               // stack pointer (0=empty)

    // Unpack top of stack
    wire [5:0] top_x    = stack[sp-1][STACK_W-1:STACK_W-6];
    wire [5:0] top_y    = stack[sp-1][STACK_W-7:STACK_W-12];
    wire [6:0] top_size = stack[sp-1][STACK_W-13:STACK_W-19];
    wire [1:0] top_depth= stack[sp-1][1:0];

    //-------------------------------------------------------------------------
    // Z-scan child ordering (HM: g_auiRasterToZscan pattern)
    // For a parent CU at (px, py) of size S, children are at:
    //   Child 0: (px,       py      ) — top-left
    //   Child 1: (px+S/2,   py      ) — top-right
    //   Child 2: (px,       py+S/2  ) — bottom-left
    //   Child 3: (px+S/2,   py+S/2  ) — bottom-right
    // Push in reverse order (3,2,1,0) so 0 is processed first
    //-------------------------------------------------------------------------
    wire [5:0] half_size = {1'b0, top_size[6:1]};   // top_size / 2

    //-------------------------------------------------------------------------
    // State machine
    //-------------------------------------------------------------------------
    localparam S_IDLE     = 2'd0;   // waiting for CTU
    localparam S_PUSH_CTU = 2'd1;   // push root CU onto stack
    localparam S_EVAL     = 2'd2;   // present top CU to mode_decision
    localparam S_SPLIT    = 2'd3;   // received split decision, act on it

    reg [1:0] state;

    // Count leaf CUs output (to detect last in CTU)
    // Max leaves = 64 (all depth-3), fits in 7 bits
    reg [6:0]  leaf_count;
    reg [6:0]  expected_leaves; // set when CTU is fully determined (not used in simplified version)

    assign ctu_ready   = (state == S_IDLE);
    assign split_ready = (state == S_SPLIT);

    integer ki;

    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            sp          <= 4'd0;
            cu_valid    <= 1'b0;
            cu_is_last_in_ctu <= 1'b0;
            leaf_count  <= 7'd0;
            for (ki = 0; ki < STACK_DEPTH; ki = ki + 1)
                stack[ki] <= {STACK_W{1'b0}};
        end else begin
            case (state)
                //--------------------------------------------------------------
                // S_IDLE: wait for a CTU, then push the root CU
                //--------------------------------------------------------------
                S_IDLE: begin
                    cu_valid <= 1'b0;
                    cu_is_last_in_ctu <= 1'b0;
                    if (ctu_valid) begin
                        leaf_count    <= 7'd0;

                        // Push root CU: x=0, y=0, size=64, depth=0
                        stack[0] <= {6'd0, 6'd0, 7'd64, 2'd0};
                        sp       <= 4'd1;
                        state    <= S_EVAL;
                    end
                end

                //--------------------------------------------------------------
                // S_EVAL: present top-of-stack CU to mode_decision
                //--------------------------------------------------------------
                S_EVAL: begin
                    if (sp == 4'd0) begin
                        // Stack empty — CTU fully partitioned
                        state    <= S_IDLE;
                        cu_valid <= 1'b0;
                    end else begin
                        // Present current top CU
                        cu_valid       <= 1'b1;
                        cu_x           <= top_x;
                        cu_y           <= top_y;
                        cu_size        <= top_size;
                        cu_depth       <= top_depth;
                        cu_is_last_in_ctu <= 1'b0;  // updated on split decision

                        if (cu_valid && split_valid) begin
                            state <= S_SPLIT;
                            cu_valid <= 1'b0;
                        end
                    end
                end

                //--------------------------------------------------------------
                // S_SPLIT: received split_flag from mode_decision
                //--------------------------------------------------------------
                S_SPLIT: begin
                    if (cu_ready) begin
                        if (!split_flag || top_depth == 2'd3) begin
                            // Leaf CU — wait for datapath to accept it
                            sp <= sp - 4'd1;
                            leaf_count <= leaf_count + 7'd1;
                            state <= S_EVAL;
                        end else begin
                            // Split — push 4 children (Child 0 placed at new top of stack)
                            sp <= sp - 4'd1;
                            stack[sp-1+3] <= {top_x, top_y, {1'b0, half_size}, top_depth + 2'd1};
                            stack[sp-1+2] <= {top_x + half_size, top_y, {1'b0, half_size}, top_depth + 2'd1};
                            stack[sp-1+1] <= {top_x, top_y + half_size, {1'b0, half_size}, top_depth + 2'd1};
                            stack[sp-1]   <= {top_x + half_size, top_y + half_size, {1'b0, half_size}, top_depth + 2'd1};
                            sp <= sp + 4'd3;
                            state <= S_EVAL;
                        end
                    end
                end
            endcase

            // Assert is_last_in_ctu on the final leaf
            // Detected when stack goes to 0 after a leaf pop
            if (state == S_SPLIT && split_valid &&
                (!split_flag || top_depth == 2'd3) &&
                sp == 4'd1) begin
                // This is the last leaf — mark it
                cu_is_last_in_ctu <= 1'b1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Simulation checks
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n) begin
            if (state == S_SPLIT && split_valid && split_flag && top_depth == 2'd3)
                $display("WARN  [ctu_partitioner] split requested at max depth 3 - forced leaf at (%0d,%0d)",
                         top_x, top_y);
            if (sp >= STACK_DEPTH - 1)
                $display("ERROR [ctu_partitioner] stack near overflow sp=%0d at time=%0t",
                         sp, $time);
        end
    end
    // synthesis translate_on

endmodule