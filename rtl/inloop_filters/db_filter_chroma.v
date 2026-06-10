//=============================================================================
// db_filter_chroma.v
// Deblocking Filter — Chroma Edge Filter
//
// Mapped from HM source:
//   TLibCommon/TComLoopFilter.cpp
//   xEdgeFilterChroma()      — outer loop over 2-sample groups
//   xPelFilterChroma()       — per-sample chroma filter
//
// HEVC spec: Section 8.7.2.5 (filtering process for chroma samples)
//
// Key differences from luma filter:
//   1. Only ONE filter (no strong/weak decision for chroma)
//   2. Operates on 2 samples each side: p[0..1], q[0..1]
//   3. Only applied when BS=2 (intra boundary)
//      BS=1 does NOT filter chroma (per HEVC spec Table 8-10)
//   4. Chroma QP is derived from luma QP via chroma QP table
//      (QpC table from spec Table 8-15)
//   5. Uses Tc table only (no Beta table for chroma)
//
// Chroma QP mapping (HEVC spec Table 8-15):
//   QpC = QpCTable[max(0, QpY + pps_cb_qp_offset)]
//   Config: SliceCbQpOffsetIntraOrPeriodic=0, SliceCrQpOffsetIntraOrPeriodic=0
//   → QpC = QpCTable[QpY] (no offset)
//
// Filter formula (HM xPelFilterChroma):
//   delta = Clip3(-tc, tc, ((((q0-p0)<<2) + p1 - q1 + 4) >> 3))
//   p0' = Clip1(p0 + delta)
//   q0' = Clip1(q0 - delta)
//   (p1, q1 are NOT modified in chroma — only p0/q0)
//
// Tc table: same as luma (spec Table 8-11), indexed by QpC + 2*(BS-1)
//   For chroma BS=2: Tc index = QpC + 2
//
// Pipeline:
//   Input:  p0,p1,q0,q1 (4 samples, 10-bit), BS, edge_qp (luma QP)
//   Output: p0_f, q0_f (2 filtered samples — p1/q1 unchanged)
//   Latency: 2 cycles (QP remap + filter)
//=============================================================================

`include "parameter_pkg.vh"

module db_filter_chroma (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         in_valid,
    output wire         in_ready,

    input  wire [1:0]   bs,             // from boundary_strength
    input  wire [5:0]   edge_qp,        // luma QP from boundary_strength
    input  wire [1:0]   comp,           // 1=Cb, 2=Cr (for QP offset selection)

    // 4 chroma samples (10-bit)
    input  wire [`PIXEL_WIDTH-1:0] p0, p1,
    input  wire [`PIXEL_WIDTH-1:0] q0, q1,

    // Output — only p0/q0 modified
    output reg          out_valid,
    input  wire         out_ready,

    output reg  [`PIXEL_WIDTH-1:0] p0_f,
    output reg  [`PIXEL_WIDTH-1:0] q0_f,
    output reg  [`PIXEL_WIDTH-1:0] p1_pass,   // p1 passed through unchanged
    output reg  [`PIXEL_WIDTH-1:0] q1_pass,   // q1 passed through unchanged
    output reg          modified        // 1=samples were modified
);

    //-------------------------------------------------------------------------
    // Chroma QP mapping table (HEVC spec Table 8-15)
    // QpC = QpCTable[QpY], QpY range 0..51
    // Config: no Cb/Cr QP offsets (SliceCbQpOffset=0, SliceCrQpOffset=0)
    //-------------------------------------------------------------------------
    function automatic [5:0] chroma_qp_table;
        input [5:0] qpy;
        case (qpy)
            6'd0:  chroma_qp_table = 6'd0;  6'd1:  chroma_qp_table = 6'd1;
            6'd2:  chroma_qp_table = 6'd2;  6'd3:  chroma_qp_table = 6'd3;
            6'd4:  chroma_qp_table = 6'd4;  6'd5:  chroma_qp_table = 6'd5;
            6'd6:  chroma_qp_table = 6'd6;  6'd7:  chroma_qp_table = 6'd7;
            6'd8:  chroma_qp_table = 6'd8;  6'd9:  chroma_qp_table = 6'd9;
            6'd10: chroma_qp_table = 6'd10; 6'd11: chroma_qp_table = 6'd11;
            6'd12: chroma_qp_table = 6'd12; 6'd13: chroma_qp_table = 6'd13;
            6'd14: chroma_qp_table = 6'd14; 6'd15: chroma_qp_table = 6'd15;
            6'd16: chroma_qp_table = 6'd16; 6'd17: chroma_qp_table = 6'd17;
            6'd18: chroma_qp_table = 6'd18; 6'd19: chroma_qp_table = 6'd19;
            6'd20: chroma_qp_table = 6'd20; 6'd21: chroma_qp_table = 6'd21;
            6'd22: chroma_qp_table = 6'd22; 6'd23: chroma_qp_table = 6'd23;
            6'd24: chroma_qp_table = 6'd24; 6'd25: chroma_qp_table = 6'd25;
            6'd26: chroma_qp_table = 6'd26; 6'd27: chroma_qp_table = 6'd27;
            6'd28: chroma_qp_table = 6'd28; 6'd29: chroma_qp_table = 6'd29;
            6'd30: chroma_qp_table = 6'd29; 6'd31: chroma_qp_table = 6'd30;
            6'd32: chroma_qp_table = 6'd31; 6'd33: chroma_qp_table = 6'd32;
            6'd34: chroma_qp_table = 6'd33; 6'd35: chroma_qp_table = 6'd33;
            6'd36: chroma_qp_table = 6'd34; 6'd37: chroma_qp_table = 6'd34;
            6'd38: chroma_qp_table = 6'd35; 6'd39: chroma_qp_table = 6'd35;
            6'd40: chroma_qp_table = 6'd36; 6'd41: chroma_qp_table = 6'd36;
            6'd42: chroma_qp_table = 6'd37; 6'd43: chroma_qp_table = 6'd37;
            6'd44: chroma_qp_table = 6'd38; 6'd45: chroma_qp_table = 6'd39;
            6'd46: chroma_qp_table = 6'd40; 6'd47: chroma_qp_table = 6'd41;
            6'd48: chroma_qp_table = 6'd42; 6'd49: chroma_qp_table = 6'd43;
            6'd50: chroma_qp_table = 6'd44; 6'd51: chroma_qp_table = 6'd45;
            default: chroma_qp_table = 6'd0;
        endcase
    endfunction

    //-------------------------------------------------------------------------
    // Tc table (same as luma, spec Table 8-11)
    // Indexed by QpC + 2 (chroma always uses BS=2 path)
    //-------------------------------------------------------------------------
    function automatic [6:0] tc_table;
        input [6:0] idx;
        case (idx)
            7'd0,7'd1,7'd2,7'd3,7'd4,7'd5,7'd6,7'd7,
            7'd8,7'd9,7'd10,7'd11,7'd12,7'd13,7'd14,7'd15,
            7'd16,7'd17: tc_table = 7'd0;
            7'd18,7'd19,7'd20,7'd21,7'd22,7'd23: tc_table = 7'd1;
            7'd24,7'd25,7'd26,7'd27: tc_table = 7'd2;
            7'd28,7'd29,7'd30,7'd31: tc_table = 7'd3;
            7'd32,7'd33,7'd34: tc_table = 7'd4;
            7'd35,7'd36: tc_table = 7'd5;
            7'd37,7'd38: tc_table = 7'd6;
            7'd39: tc_table = 7'd7;
            7'd40: tc_table = 7'd8;
            7'd41: tc_table = 7'd9;
            7'd42: tc_table = 7'd10;
            7'd43: tc_table = 7'd11;
            7'd44: tc_table = 7'd13;
            7'd45: tc_table = 7'd14;
            7'd46: tc_table = 7'd16;
            7'd47: tc_table = 7'd18;
            7'd48: tc_table = 7'd20;
            7'd49: tc_table = 7'd22;
            7'd50: tc_table = 7'd24;
            7'd51: tc_table = 7'd26;
            7'd52: tc_table = 7'd28;
            7'd53: tc_table = 7'd30;
            default: tc_table = 7'd0;
        endcase
    endfunction

    //-------------------------------------------------------------------------
    // Clip helpers
    //-------------------------------------------------------------------------
    localparam signed [11:0] CLIP1_MAX = (1 << `BIT_DEPTH) - 1;

    function automatic [`PIXEL_WIDTH-1:0] clip1;
        input signed [11:0] val;
        begin
            if      (val > CLIP1_MAX) clip1 = CLIP1_MAX[`PIXEL_WIDTH-1:0];
            else if (val < 12'sd0)    clip1 = {`PIXEL_WIDTH{1'b0}};
            else                      clip1 = val[`PIXEL_WIDTH-1:0];
        end
    endfunction

    function automatic signed [11:0] clip3;
        input signed [11:0] lo, hi, val;
        begin
            if      (val < lo) clip3 = lo;
            else if (val > hi) clip3 = hi;
            else               clip3 = val;
        end
    endfunction

    //-------------------------------------------------------------------------
    // Stage 1 register — QP remap + threshold lookup
    //-------------------------------------------------------------------------
    reg [`PIXEL_WIDTH-1:0] s1_p0, s1_p1, s1_q0, s1_q1;
    reg [6:0]  s1_tc;
    reg [1:0]  s1_bs;
    reg        s1_valid;
    reg        s1_filter_enable;

    assign in_ready = !s1_valid || (out_ready | ~out_valid);

    // Chroma QP: apply chroma QP table to luma edge_qp
    wire [5:0] qpc    = chroma_qp_table(edge_qp);
    // Tc index: QpC + 2*(BS-1). Chroma only filters at BS=2 → +2
    wire [6:0] tc_idx = {1'b0, qpc} + 7'd2;

    always @(posedge clk) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            s1_filter_enable <= 1'b0;
        end else if (in_ready) begin
            s1_valid <= in_valid;
            s1_filter_enable <= (bs == 2'd2); // Chroma only filters at BS=2 per HEVC spec
            s1_p0 <= p0; s1_p1 <= p1;
            s1_q0 <= q0; s1_q1 <= q1;
            s1_bs <= bs;
            s1_tc <= tc_table(tc_idx);
        end
    end

    //-------------------------------------------------------------------------
    // Stage 2 — filter computation (combinational)
    //
    // HM xPelFilterChroma():
    //   delta = Clip3(-tc, tc, ((((q0-p0) << 2) + p1 - q1 + 4) >> 3))
    //   p0'   = Clip1(p0 + delta)
    //   q0'   = Clip1(q0 - delta)
    //
    // Bit widths:
    //   (q0-p0) max = 1023 → 11-bit signed
    //   (q0-p0)<<2  max = 4092 → 13-bit signed
    //   + p1 - q1 + 4: add ±1023 → 14-bit signed
    //   >>3: 11-bit signed result
    //   Clip3(-tc, tc): tc max = 11 → clip to ±11
    //-------------------------------------------------------------------------
    wire signed [13:0] q0_minus_p0  = $signed({4'b0, s1_q0})
                                    - $signed({4'b0, s1_p0});
    wire signed [13:0] p1_minus_q1  = $signed({4'b0, s1_p1})
                                    - $signed({4'b0, s1_q1});

    wire signed [13:0] raw_sum = ({q0_minus_p0[11:0], 2'b0}) // <<2
                                + p1_minus_q1
                                + 14'sd4;

    wire signed [10:0] raw_delta = raw_sum[13:3];   // >>3

    wire signed [11:0] tc_pos  =  $signed({5'b0, s1_tc});
    wire signed [11:0] tc_neg  = -$signed({5'b0, s1_tc});

    wire signed [11:0] delta   = clip3(tc_neg, tc_pos, {{1{raw_delta[10]}}, raw_delta});

    wire [`PIXEL_WIDTH-1:0] p0_filtered = clip1($signed({2'b0, s1_p0}) + delta);
    wire [`PIXEL_WIDTH-1:0] q0_filtered = clip1($signed({2'b0, s1_q0}) - delta);

    //-------------------------------------------------------------------------
    // Output register
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            modified  <= 1'b0;
        end else if (out_ready || !out_valid) begin
            out_valid <= s1_valid;

            if (s1_valid && s1_filter_enable) begin
                p0_f    <= p0_filtered;
                q0_f    <= q0_filtered;
                p1_pass <= s1_p1;
                q1_pass <= s1_q1;
                modified<= (s1_tc != 7'd0);  // no modification if Tc=0
            end else if (s1_valid) begin
                // Pass through unmodified (BS=0 or BS=1)
                p0_f    <= s1_p0;
                q0_f    <= s1_q0;
                p1_pass <= s1_p1;
                q1_pass <= s1_q1;
                modified<= 1'b0;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Simulation checks
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && in_valid && in_ready && bs == 2'd1)
            $display("INFO  [db_filter_chroma] BS=1 chroma edge skipped (spec correct) QP=%0d",
                     edge_qp);
    end
    // synthesis translate_on

endmodule