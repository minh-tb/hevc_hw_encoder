//=============================================================================
// rate_estimator.v
// Fast Fractional Bit-Cost Estimator for HEVC Mode Decision (Q8.8 Fixed-Point)
//
// Outputs estimated syntax bits for:
//   - Intra Modes (MPM vs Non-MPM, Chroma mode)
//   - Inter Merge / Skip (Truncated unary merge index)
//   - Inter AMVP (MVD Exp-Golomb bit length, ref_idx, mvp_flag)
//
// 1 Bit = 8'd256 (in Q8.8 format)
//=============================================================================

`timescale 1ns / 1ps

module rate_estimator (
    // Mode indicators
    input  wire                     is_intra,
    input  wire                     is_merge,
    input  wire                     is_skip,
    
    // Intra parameters
    input  wire [5:0]               intra_mode,
    input  wire [5:0]               mpm_cand0,
    input  wire [5:0]               mpm_cand1,
    input  wire [5:0]               mpm_cand2,
    
    // Merge parameters
    input  wire [2:0]               merge_idx,
    
    // Inter MVD parameters (in quarter-pel units)
    input  wire signed [11:0]       mvd_x,
    input  wire signed [11:0]       mvd_y,
    
    // Output estimated rate in Q8.8 bits
    output reg  [15:0]              est_rate_bits
);

    // =========================================================================
    // MVD Exp-Golomb Length Calculator Function
    // =========================================================================
    function automatic [7:0] calc_mvd_bits;
        input signed [11:0] val;
        reg [11:0] abs_val;
        reg [11:0] suffix;
        begin
            abs_val = (val < 0) ? -val : val;
            if (abs_val == 12'd0) begin
                calc_mvd_bits = 8'd1; // abs_mvd_greater0 = 0
            end else if (abs_val == 12'd1) begin
                calc_mvd_bits = 8'd3; // gt0(1) + gt1(0) + sign(1)
            end else begin
                // gt0(1) + gt1(1) + EG-1 suffix + sign(1)
                // suffix = abs_val - 2
                // EG-1 length = 2 * floor(log2(suffix + 1)) + 1
                suffix = abs_val - 12'd2;
                if (suffix < 12'd2)       calc_mvd_bits = 8'd3 + 8'd3; // 1 bin pfx + 1 bit sfx + 1 sign + 3
                else if (suffix < 12'd6)  calc_mvd_bits = 8'd3 + 8'd5;
                else if (suffix < 12'd14) calc_mvd_bits = 8'd3 + 8'd7;
                else if (suffix < 12'd30) calc_mvd_bits = 8'd3 + 8'd9;
                else if (suffix < 12'd62) calc_mvd_bits = 8'd3 + 8'd11;
                else                      calc_mvd_bits = 8'd3 + 8'd15;
            end
        end
    endfunction

    // Evaluator
    reg [7:0] total_bits;
    wire is_mpm = (intra_mode == mpm_cand0) || 
                  (intra_mode == mpm_cand1) || 
                  (intra_mode == mpm_cand2);

    always @(*) begin
        if (is_intra) begin
            // Intra Header: split_cu(1) + pred_mode(1) + cbf_flags(2)
            // Luma Mode: MPM flag(1) + MPM index(1..2) OR Non-MPM(5)
            // Chroma Mode: 1 bit (DM)
            if (is_mpm) begin
                if (intra_mode == mpm_cand0)
                    total_bits = 8'd5;  // 4 header + 1 mpm_flag + 0 mpm_idx
                else
                    total_bits = 8'd6;  // 4 header + 1 mpm_flag + 1 mpm_idx
            end else begin
                total_bits = 8'd10; // 4 header + 1 mpm_flag + 5 rem_mode
            end
        end else if (is_skip) begin
            // Skip: split_cu(1) + skip_flag(1) + merge_idx(1..4)
            case (merge_idx)
                3'd0: total_bits = 8'd3;
                3'd1: total_bits = 8'd4;
                3'd2: total_bits = 8'd5;
                default: total_bits = 8'd6;
            endcase
        end else if (is_merge) begin
            // Merge: split_cu(1) + skip_flag(0) + merge_flag(1) + merge_idx(1..4) + cbf(1)
            case (merge_idx)
                3'd0: total_bits = 8'd5;
                3'd1: total_bits = 8'd6;
                3'd2: total_bits = 8'd7;
                default: total_bits = 8'd8;
            endcase
        end else begin
            // AMVP: split_cu(1) + skip(0) + merge(0) + inter_idc(1) + ref_idx(1) + mvp_flag(1) + MVD
            total_bits = 8'd5 + calc_mvd_bits(mvd_x) + calc_mvd_bits(mvd_y);
        end

        // Convert to Q8.8 fixed-point (total_bits * 256)
        est_rate_bits = {total_bits, 8'd0};
    end

endmodule
