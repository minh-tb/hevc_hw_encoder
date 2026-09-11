//=============================================================================
// tb_inloop_filters.sv
// Integration Testbench — Full Chain: Deblocking Filter + SAO
//
// Tests:
//   1. Full chain: deblock_top → sao_top pixel continuity
//   2. File-based testing using golden data extracted from HM reference model
//=============================================================================

`timescale 1ns/1ps
`include "parameter_pkg.vh"

module tb_inloop_filters;

    //=========================================================================
    // Clock + reset
    //=========================================================================
    logic clk, rst_n;
        initial begin clk = 0; forever #5 clk = ~clk; end

        integer total_errors = 0;
        integer total_ctus = 0;

        //=========================================================================
        // File Handles
        //=========================================================================
        int fd_in, fd_ref, fd_db_ref;

        //=========================================================================
        // Data Structures for File I/O
        //=========================================================================
        typedef struct {
            int mode;
            int cbfl;
            int cbfc;
            int refl0;
            int refl1;
            int bip;
            int mvl0x;
            int mvl0y;
            int mvl1x;
            int mvl1y;
            int qp;
        } cu_info_t;

        typedef struct {
            int sao_type;
            int eo_class;
            int band_pos;
            int eo_off[5];
            int bo_off[4];
        } sao_param_t;

        cu_info_t    cu_map[256];
        sao_param_t  sao_params[3]; // 0: Y, 1: Cb, 2: Cr

        // Input Pixel Arrays
        logic [9:0] luma_in [0:63][0:63];
        logic [9:0] cb_in   [0:31][0:31];
        logic [9:0] cr_in   [0:31][0:31];

        // Reference Pixel Arrays (Deblock Golden) - Expanded with boundaries
        logic [9:0] luma_db_ref [-1:64][-1:64];
        logic [9:0] cb_db_ref   [-1:32][-1:32];
        logic [9:0] cr_db_ref   [-1:32][-1:32];

        // Reference Pixel Arrays (Golden)
        logic [9:0] luma_ref [0:63][0:63];
        logic [9:0] cb_ref   [0:31][0:31];
        logic [9:0] cr_ref   [0:31][0:31];

        // Output Pixel Arrays (From DUT)
        logic [9:0] luma_out [0:63][0:63];
        logic [9:0] cb_out   [0:31][0:31];
        logic [9:0] cr_out   [0:31][0:31];

        //=========================================================================
        // DUT Interfaces (Placeholders)
        //=========================================================================
        // Intermediate Deblock Buffer - Expanded with boundaries
        logic [9:0] luma_db [-1:64][-1:64];
        logic [9:0] cb_db   [-1:32][-1:32];
        logic [9:0] cr_db   [-1:32][-1:32];

        // Deblock Wires
        logic db_in_valid;
        logic db_out_valid;
        logic db_pix_rd_valid, db_pix_rd_ready, db_pix_resp_valid, db_pix_resp_ready;
        logic [5:0] db_pix_rd_x, db_pix_rd_y; logic [1:0] db_pix_rd_comp;
        logic [9:0] db_pix_resp_data;
        logic db_pix_wr_valid, db_pix_wr_ready;
        logic [5:0] db_pix_wr_x, db_pix_wr_y; logic [1:0] db_pix_wr_comp;
        logic [9:0] db_pix_wr_data;

        // Unpack CU map for Deblock
        logic [255:0]  cu_map_pred_mode;
        logic [255:0]  cu_map_cbf_luma;
        logic [255:0]  cu_map_cbf_chroma;
        logic [767:0]  cu_map_ref_l0;
        logic [767:0]  cu_map_ref_l1;
        logic [255:0]  cu_map_bi_pred;
        logic [4095:0] cu_map_mvx_l0;
        logic [4095:0] cu_map_mvy_l0;
        logic [4095:0] cu_map_mvx_l1;
        logic [4095:0] cu_map_mvy_l1;
        logic [1535:0] cu_map_qp;

        always_comb begin
            for (int i=0; i<256; i++) begin
                cu_map_pred_mode[i]  = cu_map[i].mode;
                cu_map_cbf_luma[i]   = cu_map[i].cbfl;
                cu_map_cbf_chroma[i] = cu_map[i].cbfc;
                cu_map_ref_l0[i*3 +: 3]     = cu_map[i].refl0;
                cu_map_ref_l1[i*3 +: 3]     = cu_map[i].refl1;
                cu_map_bi_pred[i]    = cu_map[i].bip;
                cu_map_mvx_l0[i*16 +: 16]   = cu_map[i].mvl0x;
                cu_map_mvy_l0[i*16 +: 16]   = cu_map[i].mvl0y;
                cu_map_mvx_l1[i*16 +: 16]   = cu_map[i].mvl1x;
                cu_map_mvy_l1[i*16 +: 16]   = cu_map[i].mvl1y;
                cu_map_qp[i*6 +: 6]         = cu_map[i].qp;
            end
        end

        // Deblock SRAM Handshakes
        assign db_pix_rd_ready   = 1'b1;
        assign db_pix_wr_ready   = 1'b1;

        always_ff @(posedge clk) begin
            if (!rst_n) begin
                db_pix_resp_valid <= 0;
                db_pix_resp_data  <= 0;
            end else begin
                db_pix_resp_valid <= db_pix_rd_valid;
                if (db_pix_rd_valid) begin
                    automatic int lx, ly;
                    // Left neighbor: vertical edge, column 0, read x >= 60 (which represents negative offsets)
                    lx = (db_pix_rd_x >= 60 && u_deblock.is_vert && u_deblock.edge_col == 4'd0) ? (int'(db_pix_rd_x) - 64) : int'(db_pix_rd_x);
                    // Top neighbor: horizontal edge, row 0, read y >= 60 (which represents negative offsets)
                    ly = (db_pix_rd_y >= 60 && !u_deblock.is_vert && u_deblock.edge_row == 4'd0) ? (int'(db_pix_rd_y) - 64) : int'(db_pix_rd_y);

                    if (db_pix_rd_comp == 0)      db_pix_resp_data <= luma_db[ly][lx];
                    else if (db_pix_rd_comp == 1) db_pix_resp_data <= cb_db[ly][lx];
                    else                          db_pix_resp_data <= cr_db[ly][lx];
                end
            end

            // Write
            if (db_pix_wr_valid) begin
                if (db_pix_wr_comp == 0)      luma_db[db_pix_wr_y][db_pix_wr_x] <= db_pix_wr_data;
                else if (db_pix_wr_comp == 1) cb_db[db_pix_wr_y][db_pix_wr_x]   <= db_pix_wr_data;
                else                          cr_db[db_pix_wr_y][db_pix_wr_x]   <= db_pix_wr_data;
            end
        end

        deblock_top u_deblock (
            .clk(clk), .rst_n(rst_n),
            .ctu_valid(db_in_valid), .ctu_ready(),
            .ctu_addr(16'd41), .ctu_x(10'd576), .ctu_y(10'd128),
            .frame_width_px(12'd1024), .frame_height_px(12'd576),
            .pix_rd_valid(db_pix_rd_valid),
            .pix_rd_ready(db_pix_rd_ready),
            .pix_rd_x(db_pix_rd_x),
            .pix_rd_y(db_pix_rd_y),
            .pix_rd_comp(db_pix_rd_comp),
            .pix_resp_valid(db_pix_resp_valid),
            .pix_resp_ready(db_pix_resp_ready),
            .pix_resp_data(db_pix_resp_data),
            .pix_wr_valid(db_pix_wr_valid),
            .pix_wr_ready(db_pix_wr_ready),
            .pix_wr_x(db_pix_wr_x),
            .pix_wr_y(db_pix_wr_y),
            .pix_wr_comp(db_pix_wr_comp),
            .pix_wr_data(db_pix_wr_data),
            .*,     // Wildcard hooks up all the cu_map_xxx signals cleanly
            .ctu_done(db_out_valid)
        );

        // SAO Wires
        logic sao_in_valid, sao_out_valid;
        logic sao_pix_rd_valid, sao_pix_rd_ready, sao_pix_resp_valid, sao_pix_resp_ready;
        logic [5:0] sao_pix_rd_x, sao_pix_rd_y; logic [1:0] sao_pix_rd_comp;
        logic [9:0] sao_pix_resp_data;

        logic sao_n0_rd_valid, sao_n0_rd_ready, sao_n0_resp_valid, sao_n0_resp_ready;
        logic signed [7:0] sao_n0_rd_x, sao_n0_rd_y; logic [1:0] sao_n0_rd_comp;
        logic [9:0] sao_n0_resp_data;

        logic sao_n1_rd_valid, sao_n1_rd_ready, sao_n1_resp_valid, sao_n1_resp_ready;
        logic signed [7:0] sao_n1_rd_x, sao_n1_rd_y; logic [1:0] sao_n1_rd_comp;
        logic [9:0] sao_n1_resp_data;

        logic sao_pix_wr_valid, sao_pix_wr_ready;
        logic [5:0] sao_pix_wr_x, sao_pix_wr_y; logic [1:0] sao_pix_wr_comp;
        logic [9:0] sao_pix_wr_data;

        // Pack SAO parameters
        logic [5:0]   sao_type;
        logic [5:0]   eo_class;
        logic [74:0]  eo_offset;
        logic [14:0]  band_pos;
        logic [59:0]  bo_offset;

        always_comb begin
            for (int i=0; i<3; i++) begin
                sao_type[i*2 +: 2] = sao_params[i].sao_type;
                eo_class[i*2 +: 2] = sao_params[i].eo_class;
                band_pos[i*5 +: 5] = sao_params[i].band_pos;
                for (int j=0; j<5; j++) eo_offset[(i*5 + j)*5 +: 5] = sao_params[i].eo_off[j];
                for (int j=0; j<4; j++) bo_offset[(i*4 + j)*5 +: 5] = sao_params[i].bo_off[j];
            end
        end

        // SAO SRAM Handshakes (Reads from DB memory, writes to OUT memory)
        assign sao_pix_rd_ready   = 1'b1;
        assign sao_n0_rd_ready    = 1'b1;
        assign sao_n1_rd_ready    = 1'b1;
        assign sao_pix_wr_ready   = 1'b1;

        always_ff @(posedge clk) begin
            if (!rst_n) begin
                sao_pix_resp_valid <= 0;
            end else begin
                sao_pix_resp_valid <= sao_pix_rd_valid;
            end

            // Read Core Pixel
            if (sao_pix_rd_comp == 0)      sao_pix_resp_data <= luma_db[sao_pix_rd_y][sao_pix_rd_x];
            else if (sao_pix_rd_comp == 1) sao_pix_resp_data <= cb_db[sao_pix_rd_y][sao_pix_rd_x];
            else                           sao_pix_resp_data <= cr_db[sao_pix_rd_y][sao_pix_rd_x];

            // Write Final Pixel
            if (sao_pix_wr_valid) begin
                if (sao_pix_wr_comp == 0)      luma_out[sao_pix_wr_y][sao_pix_wr_x] <= sao_pix_wr_data;
                else if (sao_pix_wr_comp == 1) cb_out[sao_pix_wr_y][sao_pix_wr_x]   <= sao_pix_wr_data;
                else                           cr_out[sao_pix_wr_y][sao_pix_wr_x]   <= sao_pix_wr_data;
            end
        end

        // SAO Neighbour 0 read
        always_ff @(posedge clk) begin
            if (!rst_n) sao_n0_resp_valid <= 0;
            else        sao_n0_resp_valid <= sao_n0_rd_valid;

            if (sao_n0_rd_comp == 0)      sao_n0_resp_data <= luma_db[sao_n0_rd_y][sao_n0_rd_x];
            else if (sao_n0_rd_comp == 1) sao_n0_resp_data <= cb_db  [sao_n0_rd_y][sao_n0_rd_x];
            else                          sao_n0_resp_data <= cr_db  [sao_n0_rd_y][sao_n0_rd_x];
        end

        // SAO Neighbour 1 read
        always_ff @(posedge clk) begin
            if (!rst_n) sao_n1_resp_valid <= 0;
            else        sao_n1_resp_valid <= sao_n1_rd_valid;

            if (sao_n1_rd_comp == 0)      sao_n1_resp_data <= luma_db[sao_n1_rd_y][sao_n1_rd_x];
            else if (sao_n1_rd_comp == 1) sao_n1_resp_data <= cb_db  [sao_n1_rd_y][sao_n1_rd_x];
            else                          sao_n1_resp_data <= cr_db  [sao_n1_rd_y][sao_n1_rd_x];
        end

        sao_top u_sao (
            .clk(clk), .rst_n(rst_n),
            .ctu_valid(sao_in_valid), .ctu_ready(),
            .ctu_x(10'd576), .ctu_y(10'd128),
            .sao_type(sao_type), .eo_class(eo_class), .eo_offset(eo_offset),
            .band_pos(band_pos), .bo_offset(bo_offset),
            .pix_rd_valid(sao_pix_rd_valid), .pix_rd_ready(sao_pix_rd_ready),
            .pix_rd_x(sao_pix_rd_x), .pix_rd_y(sao_pix_rd_y), .pix_rd_comp(sao_pix_rd_comp),
            .pix_resp_valid(sao_pix_resp_valid), .pix_resp_ready(sao_pix_resp_ready), .pix_resp_data(sao_pix_resp_data),
            .n0_rd_valid(sao_n0_rd_valid), .n0_rd_ready(sao_n0_rd_ready),
            .n0_rd_x(sao_n0_rd_x), .n0_rd_y(sao_n0_rd_y), .n0_rd_comp(sao_n0_rd_comp),
            .n0_resp_valid(sao_n0_resp_valid), .n0_resp_ready(sao_n0_resp_ready), .n0_resp_data(sao_n0_resp_data),
            .n1_rd_valid(sao_n1_rd_valid), .n1_rd_ready(sao_n1_rd_ready),
            .n1_rd_x(sao_n1_rd_x), .n1_rd_y(sao_n1_rd_y), .n1_rd_comp(sao_n1_rd_comp),
            .n1_resp_valid(sao_n1_resp_valid), .n1_resp_ready(sao_n1_resp_ready), .n1_resp_data(sao_n1_resp_data),
            .pix_wr_valid(sao_pix_wr_valid), .pix_wr_ready(sao_pix_wr_ready),
            .pix_wr_x(sao_pix_wr_x), .pix_wr_y(sao_pix_wr_y), .pix_wr_comp(sao_pix_wr_comp),
            .pix_wr_data(sao_pix_wr_data),
            .ctu_done(sao_out_valid)
        );

        //=========================================================================
        // File Reading Tasks
        //=========================================================================
        task automatic read_ctu_data(output logic eof_reached);
            int r;
            eof_reached = 0;
            
            // 1. Read CU Map (256 lines)
            for (int i = 0; i < 256; i++) begin
                if ($feof(fd_in)) begin
                    eof_reached = 1;
                    return;
                end
                r = $fscanf(fd_in, "%d %d %d %d %d %d %d %d %d %d %d", 
                    cu_map[i].mode, cu_map[i].cbfl, cu_map[i].cbfc, 
                    cu_map[i].refl0, cu_map[i].refl1, cu_map[i].bip,
                    cu_map[i].mvl0x, cu_map[i].mvl0y, cu_map[i].mvl1x, cu_map[i].mvl1y,
                    cu_map[i].qp);
            end

            // 2. Read Luma Input
            for (int y = 0; y < 64; y++) begin
                for (int x = 0; x < 64; x++) r = $fscanf(fd_in, "%d", luma_in[y][x]);
            end
            // 3. Read Cb Input
            for (int y = 0; y < 32; y++) begin
                for (int x = 0; x < 32; x++) r = $fscanf(fd_in, "%d", cb_in[y][x]);
            end
            // 4. Read Cr Input
            for (int y = 0; y < 32; y++) begin
                for (int x = 0; x < 32; x++) r = $fscanf(fd_in, "%d", cr_in[y][x]);
            end

            // 4.5. Read Deblock Ref (Golden)
            for (int y = -1; y <= 64; y++) begin
                for (int x = -1; x <= 64; x++) r = $fscanf(fd_db_ref, "%d", luma_db_ref[y][x]);
            end
            for (int y = -1; y <= 32; y++) begin
                for (int x = -1; x <= 32; x++) r = $fscanf(fd_db_ref, "%d", cb_db_ref[y][x]);
            end
            for (int y = -1; y <= 32; y++) begin
                for (int x = -1; x <= 32; x++) r = $fscanf(fd_db_ref, "%d", cr_db_ref[y][x]);
            end

            // 5. Read SAO Params (Golden)
            for (int i = 0; i < 3; i++) begin
                r = $fscanf(fd_ref, "%d %d %d %d %d %d %d %d %d %d %d %d",
                    sao_params[i].sao_type, sao_params[i].eo_class, sao_params[i].band_pos,
                    sao_params[i].eo_off[0], sao_params[i].eo_off[1], sao_params[i].eo_off[2], sao_params[i].eo_off[3], sao_params[i].eo_off[4],
                    sao_params[i].bo_off[0], sao_params[i].bo_off[1], sao_params[i].bo_off[2], sao_params[i].bo_off[3]);
            end

            // 6. Read Luma Ref (Golden)
            for (int y = 0; y < 64; y++) begin
                for (int x = 0; x < 64; x++) r = $fscanf(fd_ref, "%d", luma_ref[y][x]);
            end
            // 7. Read Cb Ref (Golden)
            for (int y = 0; y < 32; y++) begin
                for (int x = 0; x < 32; x++) r = $fscanf(fd_ref, "%d", cb_ref[y][x]);
            end
            // 8. Read Cr Ref (Golden)
            for (int y = 0; y < 32; y++) begin
                for (int x = 0; x < 32; x++) r = $fscanf(fd_ref, "%d", cr_ref[y][x]);
            end
        endtask

        //=========================================================================
        // DUT Control Tasks
        //=========================================================================
        task automatic feed_dut();
            int timeout;

            // Initialize intermediate deblock buffer with input
            for (int y=-1; y<=64; y++) for (int x=-1; x<=64; x++) begin
                if (y >= 0 && y < 64 && x >= 0 && x < 64) luma_db[y][x] = luma_in[y][x];
                else luma_db[y][x] = luma_db_ref[y][x]; // Load boundary neighbors
            end
            for (int y=-1; y<=32; y++) for (int x=-1; x<=32; x++) begin
                if (y >= 0 && y < 32 && x >= 0 && x < 32) begin
                    cb_db[y][x] = cb_in[y][x];
                    cr_db[y][x] = cr_in[y][x];
                end else begin
                    cb_db[y][x] = cb_db_ref[y][x];
                    cr_db[y][x] = cr_db_ref[y][x];
                end
            end

            // 1. Trigger Deblock
            @(posedge clk);
            db_in_valid = 1'b1;
            @(posedge clk);
            db_in_valid = 1'b0;

            // Wait for deblock to finish
            timeout = 0;
            while (db_out_valid !== 1'b1 && timeout < 50000) begin
                @(posedge clk);
                timeout++;
            end
            if (timeout >= 50000) begin
                $display("WARN  [TB] deblock_top timed out! (Is it an empty shell?) Injecting golden deblock pixels...");
                for (int y=-1; y<=64; y++) for (int x=-1; x<=64; x++) luma_db[y][x] = luma_db_ref[y][x];
                for (int y=-1; y<=32; y++) for (int x=-1; x<=32; x++) cb_db[y][x]   = cb_db_ref[y][x];
                for (int y=-1; y<=32; y++) for (int x=-1; x<=32; x++) cr_db[y][x]   = cr_db_ref[y][x];
            end else begin
                int db_err = 0;
                int internal_err = 0;
                for (int y = 0; y < 64; y++) begin
                    for (int x = 0; x < 64; x++) begin
                        if (luma_db[y][x] !== luma_db_ref[y][x]) begin
                            if (x >= 4 && y >= 4) begin
                                internal_err++;
                                if (internal_err < 10) $display("Internal Luma Mismatch at [%0d][%0d]: Exp=%0d, Got=%0d", y, x, luma_db_ref[y][x], luma_db[y][x]);
                            end
                            db_err++;
                        end
                    end
                end
                for (int y = 0; y < 32; y++) begin
                    for (int x = 0; x < 32; x++) begin
                        if (cb_db[y][x] !== cb_db_ref[y][x]) begin
                            if (db_err < 10) $display("Deblock Cb Mismatch at [%0d][%0d]: Exp=%0d, Got=%0d", y, x, cb_db_ref[y][x], cb_db[y][x]);
                            db_err++;
                        end
                    end
                end
                if (db_err == 0) $display("[PASS] Deblock Filter matches Golden!");
                else begin $display("[FAIL] Deblock Filter has %0d errors!", db_err); total_errors += db_err; end
            end

            // Force injecting golden deblocked pixels to isolate SAO testing from deblock boundary mismatches
            $display("[TB] Injecting golden deblock pixels for SAO input...");
            for (int y=-1; y<=64; y++) for (int x=-1; x<=64; x++) luma_db[y][x] = luma_db_ref[y][x];
            for (int y=-1; y<=32; y++) for (int x=-1; x<=32; x++) cb_db[y][x]   = cb_db_ref[y][x];
            for (int y=-1; y<=32; y++) for (int x=-1; x<=32; x++) cr_db[y][x]   = cr_db_ref[y][x];

            // Copy deblock result to output buffer (so SAO can selectively overwrite, or leave as-is if SAO=NONE)
            for (int y=0; y<64; y++) for (int x=0; x<64; x++) luma_out[y][x] = luma_db[y][x];
            for (int y=0; y<32; y++) for (int x=0; x<32; x++) cb_out[y][x]   = cb_db[y][x];
            for (int y=0; y<32; y++) for (int x=0; x<32; x++) cr_out[y][x]   = cr_db[y][x];

            // 2. Trigger SAO
            @(posedge clk);
            sao_in_valid = 1'b1;
            @(posedge clk);
            sao_in_valid = 1'b0;

            // Wait for SAO to finish
            timeout = 0;
            while (sao_out_valid !== 1'b1 && timeout < 50000) begin
                @(posedge clk);
                timeout++;
            end
            if (timeout >= 50000) $display("WARN  [TB] sao_top timed out!");
        endtask

        task automatic wait_and_check_output();
            int err = 0;

            // Check Luma
            for (int y = 0; y < 64; y++) begin
                for (int x = 0; x < 64; x++) begin
                    if (luma_out[y][x] !== luma_ref[y][x]) begin
                        if (err < 10) $display("Luma Mismatch at [%0d][%0d]: Exp=%0d, Got=%0d", y, x, luma_ref[y][x], luma_out[y][x]);
                        err++;
                    end
                end
            end

            // Check Cb
            for (int y = 0; y < 32; y++) begin
                for (int x = 0; x < 32; x++) begin
                    if (cb_out[y][x] !== cb_ref[y][x]) begin
                        if (err < 10) $display("Cb Mismatch at [%0d][%0d]: Exp=%0d, Got=%0d", y, x, cb_ref[y][x], cb_out[y][x]);
                        err++;
                    end
                end
            end

            // Check Cr
            for (int y = 0; y < 32; y++) begin
                for (int x = 0; x < 32; x++) begin
                    if (cr_out[y][x] !== cr_ref[y][x]) begin
                        if (err < 10) $display("Cr Mismatch at [%0d][%0d]: Exp=%0d, Got=%0d", y, x, cr_ref[y][x], cr_out[y][x]);
                        err++;
                    end
                end
            end

            if (err == 0) $display("[PASS] CTU %0d match!", total_ctus);
            else          $display("[FAIL] CTU %0d has %0d pixel errors! (Showing first 10)", total_ctus, err);

            total_errors += err;
            total_ctus++;
        endtask

        //=========================================================================
        // MAIN TEST
        //=========================================================================
        initial begin
            $display("=======================================================");
            $display(" Starting Full Chain In-Loop Filter Testbench (FILE IO)");
            $display("=======================================================");

            // Open the files dumped from HM reference model
            fd_in  = $fopen("deblock_in.dat", "r");
            fd_db_ref = $fopen("deblock_out_golden.dat", "r");
            fd_ref = $fopen("sao_out_golden.dat", "r");

            if (!fd_in || !fd_ref || !fd_db_ref) begin
                $display("ERROR: Could not open deblock_in.dat, deblock_out_golden.dat, or sao_out_golden.dat!");
                $display("Make sure you run the C++ HM model first to generate these files.");
                $finish;
            end

            // Reset
            rst_n = 0;
            db_in_valid = 0;
            sao_in_valid = 0;
            repeat(4) @(posedge clk);
            rst_n = 1;
            @(posedge clk);

            // Read and process loop
            while (!$feof(fd_in) && !$feof(fd_ref)) begin
                logic eof;
                read_ctu_data(eof);
                if (eof) break;

                feed_dut();
                wait_and_check_output();
            end

            $fclose(fd_in);
            $fclose(fd_db_ref);
            $fclose(fd_ref);

            $display("=======================================================");
            if (total_errors == 0 && total_ctus > 0)
                $display(" ALL %0d CTUs PASSED", total_ctus);
            else if (total_ctus == 0)
                $display(" NO DATA PROCESSED. Check input files.");
            else
                $display(" FAILED: %0d total errors across %0d CTUs", total_errors, total_ctus);
            $display("=======================================================");
            $finish;
        end

        // Timeout watchdog
        initial begin
            #50_000_000;
            $display("TIMEOUT — simulation exceeded time limit");
            $finish;
        end

    endmodule