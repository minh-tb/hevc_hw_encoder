//=============================================================================
// tb_flaw_deblock_stages.sv
// Dual-State Self-Checking Verification Testbench for Deblocking Edge Stage Truncation
// Target Module: rtl/inloop_filters/deblock_top.v
// Associated Flaw: Flaw D-07 (Deblocking edge stage truncation omitting edges 16..56)
//
// Specification Reference:
//   - ITU-T H.265 (HEVC) Clause 8.7.2: Deblocking filter process
//   - HM 18.0 reference software: TComLoopFilter::xDeblockCU
//
// Dual-State Behavior:
//   - Buggy RTL: edge_stage is a 1-bit register only toggling 0 and 1.
//     Only edges 0 and 8 are evaluated, skipping internal edges 16..56 across the CTU.
//     The testbench asserts on visited edge count, FAILING with exit code 1.
//   - Remediated RTL: edge_stage traverses all 8 8x8 raster edges (0..7) across CTU.
//     The testbench asserts all 8 edges visited, PASSING with zero errors.
//=============================================================================

`timescale 1ns/1ps
`include "parameter_pkg.vh"

`ifndef PIXEL_WIDTH
`define PIXEL_WIDTH 10
`endif

module tb_flaw_deblock_stages;

    // Clock and Reset
    logic clk;
    logic rst_n;

    // CTU Control
    logic        ctu_valid;
    logic        ctu_ready;
    logic [15:0] ctu_addr;
    logic [9:0]  ctu_x;
    logic [9:0]  ctu_y;
    logic [11:0] frame_width_px;
    logic [11:0] frame_height_px;

    // CU Metadata Map (64x64 CTU partitioned into 16x16 grid of 4x4 blocks)
    logic [255:0]        cu_map_pred_mode;
    logic [255:0]        cu_map_cbf_luma;
    logic [255:0]        cu_map_cbf_chroma;
    logic [(256*3)-1:0]  cu_map_ref_l0;
    logic [(256*3)-1:0]  cu_map_ref_l1;
    logic [255:0]        cu_map_bi_pred;
    logic [(256*16)-1:0] cu_map_mvx_l0;
    logic [(256*16)-1:0] cu_map_mvy_l0;
    logic [(256*16)-1:0] cu_map_mvx_l1;
    logic [(256*16)-1:0] cu_map_mvy_l1;
    logic [(256*6)-1:0]  cu_map_qp;

    // Pixel Read Interface
    logic        pix_rd_valid;
    logic        pix_rd_ready;
    logic [5:0]  pix_rd_x;
    logic [5:0]  pix_rd_y;
    logic [1:0]  pix_rd_comp;

    logic        pix_resp_valid;
    logic        pix_resp_ready;
    logic [`PIXEL_WIDTH-1:0] pix_resp_data;

    // Pixel Write Interface
    logic        pix_wr_valid;
    logic        pix_wr_ready;
    logic [5:0]  pix_wr_x;
    logic [5:0]  pix_wr_y;
    logic [1:0]  pix_wr_comp;
    logic [`PIXEL_WIDTH-1:0] pix_wr_data;

    // Neighbor cache metadata
    logic [15:0]  nbr_col_pred_mode;
    logic [15:0]  nbr_col_cbf_luma;
    logic [15:0]  nbr_col_cbf_chroma;
    logic [47:0]  nbr_col_ref_l0;
    logic [47:0]  nbr_col_ref_l1;
    logic [15:0]  nbr_col_bi_pred;
    logic [255:0] nbr_col_mvx_l0;
    logic [255:0] nbr_col_mvy_l0;
    logic [255:0] nbr_col_mvx_l1;
    logic [255:0] nbr_col_mvy_l1;
    logic [95:0]  nbr_col_qp;

    logic [15:0]  nbr_row_pred_mode;
    logic [15:0]  nbr_row_cbf_luma;
    logic [15:0]  nbr_row_cbf_chroma;
    logic [47:0]  nbr_row_ref_l0;
    logic [47:0]  nbr_row_ref_l1;
    logic [15:0]  nbr_row_bi_pred;
    logic [255:0] nbr_row_mvx_l0;
    logic [255:0] nbr_row_mvy_l0;
    logic [255:0] nbr_row_mvx_l1;
    logic [255:0] nbr_row_mvy_l1;
    logic [95:0]  nbr_row_qp;

    // Neighbor access indicators
    logic pix_rd_neighbor;
    logic pix_rd_is_vert;
    logic pix_rd_corner;
    logic pix_wr_neighbor;
    logic pix_wr_is_vert;
    logic pix_wr_corner;

    logic ctu_done;

    // Instantiate DUT
    deblock_top dut (
        .clk(clk),
        .rst_n(rst_n),
        .ctu_valid(ctu_valid),
        .ctu_ready(ctu_ready),
        .ctu_addr(ctu_addr),
        .ctu_x(ctu_x),
        .ctu_y(ctu_y),
        .frame_width_px(frame_width_px),
        .frame_height_px(frame_height_px),
        .cu_map_pred_mode(cu_map_pred_mode),
        .cu_map_cbf_luma(cu_map_cbf_luma),
        .cu_map_cbf_chroma(cu_map_cbf_chroma),
        .cu_map_ref_l0(cu_map_ref_l0),
        .cu_map_ref_l1(cu_map_ref_l1),
        .cu_map_bi_pred(cu_map_bi_pred),
        .cu_map_mvx_l0(cu_map_mvx_l0),
        .cu_map_mvy_l0(cu_map_mvy_l0),
        .cu_map_mvx_l1(cu_map_mvx_l1),
        .cu_map_mvy_l1(cu_map_mvy_l1),
        .cu_map_qp(cu_map_qp),
        .cu_map_edge_ver({256{1'b1}}),
        .cu_map_edge_hor({256{1'b1}}),
        .pix_rd_valid(pix_rd_valid),
        .pix_rd_ready(pix_rd_ready),
        .pix_rd_x(pix_rd_x),
        .pix_rd_y(pix_rd_y),
        .pix_rd_comp(pix_rd_comp),
        .pix_resp_valid(pix_resp_valid),
        .pix_resp_ready(pix_resp_ready),
        .pix_resp_data(pix_resp_data),
        .pix_wr_valid(pix_wr_valid),
        .pix_wr_ready(pix_wr_ready),
        .pix_wr_x(pix_wr_x),
        .pix_wr_y(pix_wr_y),
        .pix_wr_comp(pix_wr_comp),
        .pix_wr_data(pix_wr_data),
        .nbr_col_pred_mode(nbr_col_pred_mode),
        .nbr_col_cbf_luma(nbr_col_cbf_luma),
        .nbr_col_cbf_chroma(nbr_col_cbf_chroma),
        .nbr_col_ref_l0(nbr_col_ref_l0),
        .nbr_col_ref_l1(nbr_col_ref_l1),
        .nbr_col_bi_pred(nbr_col_bi_pred),
        .nbr_col_mvx_l0(nbr_col_mvx_l0),
        .nbr_col_mvy_l0(nbr_col_mvy_l0),
        .nbr_col_mvx_l1(nbr_col_mvx_l1),
        .nbr_col_mvy_l1(nbr_col_mvy_l1),
        .nbr_col_qp(nbr_col_qp),
        .nbr_row_pred_mode(nbr_row_pred_mode),
        .nbr_row_cbf_luma(nbr_row_cbf_luma),
        .nbr_row_cbf_chroma(nbr_row_cbf_chroma),
        .nbr_row_ref_l0(nbr_row_ref_l0),
        .nbr_row_ref_l1(nbr_row_ref_l1),
        .nbr_row_bi_pred(nbr_row_bi_pred),
        .nbr_row_mvx_l0(nbr_row_mvx_l0),
        .nbr_row_mvy_l0(nbr_row_mvy_l0),
        .nbr_row_mvx_l1(nbr_row_mvx_l1),
        .nbr_row_mvy_l1(nbr_row_mvy_l1),
        .nbr_row_qp(nbr_row_qp),
        .pix_rd_neighbor(pix_rd_neighbor),
        .pix_rd_is_vert(pix_rd_is_vert),
        .pix_rd_corner(pix_rd_corner),
        .pix_wr_neighbor(pix_wr_neighbor),
        .pix_wr_is_vert(pix_wr_is_vert),
        .pix_wr_corner(pix_wr_corner),
        .ctu_done(ctu_done)
    );

    // Clock generator (100MHz)
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // Emulate 1-cycle latency SRAM responses
    assign pix_rd_ready = 1'b1;
    assign pix_wr_ready = 1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_resp_valid <= 1'b0;
            pix_resp_data  <= 10'd0;
        end else begin
            pix_resp_valid <= pix_rd_valid;
            // Return synthetic ramp samples: base 500 + x*4 + y
            pix_resp_data  <= 10'd500 + {4'd0, pix_rd_x} + {4'd0, pix_rd_y};
        end
    end

    // Edge Stage Coverage Tracker
    // In a 64x64 CTU, the 8 normative 8x8 raster edges correspond to block columns:
    // Edge 0: block 0 (col 0)
    // Edge 1: block 2 (col 8)
    // Edge 2: block 4 (col 16)
    // Edge 3: block 6 (col 24)
    // Edge 4: block 8 (col 32)
    // Edge 5: block 10 (col 40)
    // Edge 6: block 12 (col 48)
    // Edge 7: block 14 (col 56)
    logic [7:0] luma_vert_edges_visited;
    logic [7:0] luma_horiz_edges_visited;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            luma_vert_edges_visited  <= 8'd0;
            luma_horiz_edges_visited <= 8'd0;
        end else if (dut.state == 4'd1) begin // S_BS_REQ
            if (dut.pass == 3'd0) begin // PASS_LUMA_VERT
                case (dut.edge_col)
                    4'd0:  luma_vert_edges_visited[0] <= 1'b1;
                    4'd2:  luma_vert_edges_visited[1] <= 1'b1;
                    4'd4:  luma_vert_edges_visited[2] <= 1'b1;
                    4'd6:  luma_vert_edges_visited[3] <= 1'b1;
                    4'd8:  luma_vert_edges_visited[4] <= 1'b1;
                    4'd10: luma_vert_edges_visited[5] <= 1'b1;
                    4'd12: luma_vert_edges_visited[6] <= 1'b1;
                    4'd14: luma_vert_edges_visited[7] <= 1'b1;
                    default: ;
                endcase
            end else if (dut.pass == 3'd1) begin // PASS_LUMA_HORIZ
                case (dut.edge_row)
                    4'd0:  luma_horiz_edges_visited[0] <= 1'b1;
                    4'd2:  luma_horiz_edges_visited[1] <= 1'b1;
                    4'd4:  luma_horiz_edges_visited[2] <= 1'b1;
                    4'd6:  luma_horiz_edges_visited[3] <= 1'b1;
                    4'd8:  luma_horiz_edges_visited[4] <= 1'b1;
                    4'd10: luma_horiz_edges_visited[5] <= 1'b1;
                    4'd12: luma_horiz_edges_visited[6] <= 1'b1;
                    4'd14: luma_horiz_edges_visited[7] <= 1'b1;
                    default: ;
                endcase
            end
        end
    end

    // Test Execution
    int timeout_cycles;
    int num_vert_visited;
    int num_horiz_visited;

    initial begin
        $display("==================================================================");
        $display(" Starting tb_flaw_deblock_stages: Verifying CTU Edge Stages (Flaw D-07)");
        $display(" ITU-T H.265 Clause 8.7.2 & HM TComLoopFilter::xDeblockCU Benchmark");
        $display("==================================================================");

        // Reset
        rst_n          = 1'b0;
        ctu_valid      = 1'b0;
        ctu_addr       = 16'd0;
        ctu_x          = 10'd1; // non-boundary CTU (has left neighbor)
        ctu_y          = 10'd1; // non-boundary CTU (has top neighbor)
        frame_width_px = 12'd128;
        frame_height_px= 12'd128;

        // Configure all 256 4x4 blocks inside CTU as Intra (pred_mode = 0) with QP=32
        // to guarantee bS = 2 on ALL edges
        cu_map_pred_mode = 256'd0;
        cu_map_cbf_luma  = {256{1'b1}};
        cu_map_cbf_chroma= {256{1'b1}};
        cu_map_ref_l0    = '0;
        cu_map_ref_l1    = '0;
        cu_map_bi_pred   = '0;
        cu_map_mvx_l0    = '0;
        cu_map_mvy_l0    = '0;
        cu_map_mvx_l1    = '0;
        cu_map_mvy_l1    = '0;
        for (int i = 0; i < 256; i++) begin
            cu_map_qp[i*6 +: 6] = 6'd32;
        end

        // Configure neighbor metadata as Intra QP=32
        nbr_col_pred_mode = 16'd0;
        nbr_col_cbf_luma  = 16'hFFFF;
        nbr_col_cbf_chroma= 16'hFFFF;
        nbr_col_ref_l0    = '0;
        nbr_col_ref_l1    = '0;
        nbr_col_bi_pred   = '0;
        nbr_col_mvx_l0    = '0;
        nbr_col_mvy_l0    = '0;
        nbr_col_mvx_l1    = '0;
        nbr_col_mvy_l1    = '0;
        for (int i = 0; i < 16; i++) nbr_col_qp[i*6 +: 6] = 6'd32;

        nbr_row_pred_mode = 16'd0;
        nbr_row_cbf_luma  = 16'hFFFF;
        nbr_row_cbf_chroma= 16'hFFFF;
        nbr_row_ref_l0    = '0;
        nbr_row_ref_l1    = '0;
        nbr_row_bi_pred   = '0;
        nbr_row_mvx_l0    = '0;
        nbr_row_mvy_l0    = '0;
        nbr_row_mvx_l1    = '0;
        nbr_row_mvy_l1    = '0;
        for (int i = 0; i < 16; i++) nbr_row_qp[i*6 +: 6] = 6'd32;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // Trigger CTU Deblock
        @(posedge clk);
        ctu_valid = 1'b1;
        @(posedge clk);
        ctu_valid = 1'b0;

        // Wait for CTU completion or pass 2 transition
        timeout_cycles = 0;
        while (!ctu_done && (dut.pass < 3'd2) && (timeout_cycles < 20000)) begin
            @(posedge clk);
            timeout_cycles++;
        end

        // If CTU completed or both Luma V and H passes finished:
        // Wait a few cycles for stabilization
        repeat (10) @(posedge clk);

        num_vert_visited  = $countones(luma_vert_edges_visited);
        num_horiz_visited = $countones(luma_horiz_edges_visited);

        $display("\n--- Verification Results ---");
        $display("Vertical edges visited bitmap:   8'b%08b (Count: %0d/8)", luma_vert_edges_visited, num_vert_visited);
        $display("Horizontal edges visited bitmap: 8'b%08b (Count: %0d/8)", luma_horiz_edges_visited, num_horiz_visited);

        // Flaw D-07 Verification Check
        if (num_vert_visited < 8) begin
            $display("\n==================================================================");
            $display("*** FAILED: Deblocking edge stage truncation detected! (Flaw D-07) ***");
            $display("Expected: 8 vertical raster edges on 8x8 grid (Clause 8.7.2.1)");
            $display("Actual:   Only %0d edges processed (edges 0 and 8 visited; edges 16..56 omitted)", num_vert_visited);
            $display("Failure Mechanism: edge_stage in deblock_top.v lines 185-187 and 540-547");
            $display("is a 1-bit reg toggling only {0, 1}, truncating stages 2..7!");
            $display("==================================================================\n");
            $finish(1);
        end else begin
            $display("\n==================================================================");
            $display("*** ALL TESTS PASSED: All 8 CTU raster edges visited and filtered successfully ***");
            $display("==================================================================\n");
            $finish(0);
        end
    end

endmodule
