//=============================================================================
// tb_b_frame_encoder.v
// Bi-Directional B-Frame & Merge/Skip Validation Testbench
// Resolution: 128x128 (2x2 = 4 CTUs per frame, 3 Frames: I - P - B)
// Tests:
//   - Multi-CTU raster traversal
//   - Frame 0 (POC 0): IDR I-Slice
//   - Frame 1 (POC 1): P-Slice (Uni-prediction from Frame 0)
//   - Frame 2 (POC 2): B-Slice (Bi-prediction from Frame 1 and Frame 0 + Merge/Skip)
//=============================================================================

`timescale 1ns / 1ps

`include "parameter_pkg.vh"

module tb_b_frame_encoder;

    reg clk;
    reg rst_n;

    // Clock generation (100 MHz)
    always #5 clk = ~clk;

    // Reset generation
    initial begin
        clk = 0;
        rst_n = 0;
        #50;
        rst_n = 1;
    end

    // Interface signals
    reg         encode_start;
    reg  [15:0] total_frames;
    wire        encode_done;

    reg         in_valid;
    wire        in_ready;
    reg  [`PIXEL_WIDTH-1:0] in_pixel_y;
    reg  [`PIXEL_WIDTH-1:0] in_pixel_u;
    reg  [`PIXEL_WIDTH-1:0] in_pixel_v;

    wire        out_valid;
    reg         out_ready;
    wire [7:0]  out_byte;

    wire        axi_awvalid;
    reg         axi_awready;
    wire [32:0] axi_awaddr;
    wire [7:0]  axi_awlen;
    wire [2:0]  axi_awsize;
    wire [1:0]  axi_awburst;
    wire        axi_wvalid;
    reg         axi_wready;
    wire [255:0] axi_wdata;
    wire [31:0] axi_wstrb;
    wire        axi_wlast;
    reg         axi_bvalid;
    wire        axi_bready;

    wire        axi_arvalid;
    reg         axi_arready;
    wire [32:0] axi_araddr;
    wire [7:0]  axi_arlen;
    wire [2:0]  axi_arsize;
    wire [1:0]  axi_arburst;
    reg         axi_rvalid;
    wire        axi_rready;
    reg  [255:0] axi_rdata;
    reg         axi_rlast;

`ifdef SWEEP_QP_22
    localparam CFG_QP = 6'd22;
    localparam BITSTREAM_OUT = "str_b_frame_qp22.bin";
    localparam RECON_OUT = "hw_recon_qp22.yuv";
`elsif SWEEP_QP_27
    localparam CFG_QP = 6'd27;
    localparam BITSTREAM_OUT = "str_b_frame_qp27.bin";
    localparam RECON_OUT = "hw_recon_qp27.yuv";
`elsif SWEEP_QP_32
    localparam CFG_QP = 6'd32;
    localparam BITSTREAM_OUT = "str_b_frame_qp32.bin";
    localparam RECON_OUT = "hw_recon_qp32.yuv";
`elsif SWEEP_QP_37
    localparam CFG_QP = 6'd37;
    localparam BITSTREAM_OUT = "str_b_frame_qp37.bin";
    localparam RECON_OUT = "hw_recon_qp37.yuv";
`elsif PATTERN_FLAT
    localparam CFG_QP = 6'd29;
    localparam BITSTREAM_OUT = "str_b_frame_flat.bin";
    localparam RECON_OUT = "hw_recon_flat.yuv";
`elsif PATTERN_CHECKER
    localparam CFG_QP = 6'd29;
    localparam BITSTREAM_OUT = "str_b_frame_checker.bin";
    localparam RECON_OUT = "hw_recon_checker.yuv";
`elsif PATTERN_HIGH_MOTION
    localparam CFG_QP = 6'd29;
    localparam BITSTREAM_OUT = "str_b_frame_high_motion.bin";
    localparam RECON_OUT = "hw_recon_high_motion.yuv";
`elsif ENABLE_RC
    localparam CFG_QP = 6'd29;
    localparam BITSTREAM_OUT = "str_b_frame_rc.bin";
    localparam RECON_OUT = "hw_recon_rc.yuv";
`else
    localparam CFG_QP = 6'd29;
    localparam BITSTREAM_OUT = "str_b_frame.bin";
    localparam RECON_OUT = "hw_recon.yuv";
`endif

`ifdef ENABLE_RC
    localparam CFG_RC = 1'b1;
    localparam CFG_BITRATE = 16'd250; // 250 kbps @ 30 fps (scaled for 128x128 sequence)
`else
    localparam CFG_RC = 1'b0;
    localparam CFG_BITRATE = 16'd5000;
`endif

`ifdef PATTERN_FLAT
    localparam HEX_FILE_Y = "flat_y.hex";
    localparam HEX_FILE_U = "flat_u.hex";
    localparam HEX_FILE_V = "flat_v.hex";
`elsif PATTERN_CHECKER
    localparam HEX_FILE_Y = "checker_y.hex";
    localparam HEX_FILE_U = "checker_u.hex";
    localparam HEX_FILE_V = "checker_v.hex";
`elsif PATTERN_HIGH_MOTION
    localparam HEX_FILE_Y = "high_motion_y.hex";
    localparam HEX_FILE_U = "high_motion_u.hex";
    localparam HEX_FILE_V = "high_motion_v.hex";
`else
    localparam HEX_FILE_Y = "foreman_y.hex";
    localparam HEX_FILE_U = "foreman_u.hex";
    localparam HEX_FILE_V = "foreman_v.hex";
`endif

    localparam TB_WIDTH        = `DEFAULT_FRAME_WIDTH;
    localparam TB_HEIGHT       = `DEFAULT_FRAME_HEIGHT;
    localparam CTUS_X          = (TB_WIDTH + `CTU_SIZE - 1) / `CTU_SIZE;
    localparam CTUS_Y          = (TB_HEIGHT + `CTU_SIZE - 1) / `CTU_SIZE;
    localparam TOTAL_CTUS      = CTUS_X * CTUS_Y;
    localparam FRAME_PIXELS_Y  = TB_WIDTH * TB_HEIGHT;
    localparam FRAME_PIXELS_C  = (TB_WIDTH / 2) * (TB_HEIGHT / 2);
    localparam CHROMA_WIDTH    = TB_WIDTH / 2;

    // Instantiate Top-Level with Parameterized Resolution and GOP_STRUCTURE = 1 (IPBB)
    hevc_encoder_top #(
        .FRAME_WIDTH         (TB_WIDTH),
        .FRAME_HEIGHT        (TB_HEIGHT),
        .GOP_STRUCTURE       (`DEFAULT_GOP_STRUCTURE),
        .BASE_QP             (CFG_QP),
        .RC_ENABLE           (CFG_RC),
        .TARGET_BITRATE_KBPS (CFG_BITRATE)
    ) uut (
        .clk(clk),
        .rst_n(rst_n),
        .encode_start(encode_start),
        .total_frames(total_frames),
        .encode_done(encode_done),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_pixel_y(in_pixel_y),
        .in_pixel_u(in_pixel_u),
        .in_pixel_v(in_pixel_v),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_byte(out_byte),
        .axi_awvalid(axi_awvalid),
        .axi_awready(axi_awready),
        .axi_awaddr(axi_awaddr),
        .axi_awlen(axi_awlen),
        .axi_awsize(axi_awsize),
        .axi_awburst(axi_awburst),
        .axi_wvalid(axi_wvalid),
        .axi_wready(axi_wready),
        .axi_wdata(axi_wdata),
        .axi_wstrb(axi_wstrb),
        .axi_wlast(axi_wlast),
        .axi_bvalid(axi_bvalid),
        .axi_bready(axi_bready),
        .axi_arvalid(axi_arvalid),
        .axi_arready(axi_arready),
        .axi_araddr(axi_araddr),
        .axi_arlen(axi_arlen),
        .axi_arsize(axi_arsize),
        .axi_arburst(axi_arburst),
        .axi_rvalid(axi_rvalid),
        .axi_rready(axi_rready),
        .axi_rdata(axi_rdata),
        .axi_rlast(axi_rlast)
    );

    // Mock DRAM Memory (4MB)
    reg [255:0] dram_mem [0:131071];
    integer i_mem;
    initial begin
        for (i_mem = 0; i_mem < 131072; i_mem = i_mem + 1) dram_mem[i_mem] = 256'd0;
    end

    // AXI Write Channel
    reg [31:0] waddr_reg;
    reg        w_active;
    always @(posedge clk) begin
        if (!rst_n) begin
            axi_awready <= 1'b1;
            axi_wready  <= 1'b0;
            axi_bvalid  <= 1'b0;
            w_active    <= 1'b0;
        end else begin
            if (axi_awvalid && axi_awready) begin
                axi_awready <= 1'b0;
                axi_wready  <= 1'b1;
                waddr_reg   <= axi_awaddr;
                w_active    <= 1'b1;
                // $display("Time=%0t: [TB_AXI_AW] addr=0x%0h", $time, axi_awaddr);
            end
            if (w_active && axi_wvalid && axi_wready) begin : mem_write_with_strb
                reg [255:0] cur_mem_word;
                integer b_idx;
                cur_mem_word = dram_mem[waddr_reg[19:5]];
                for (b_idx = 0; b_idx < 32; b_idx = b_idx + 1) begin
                    if (axi_wstrb[b_idx]) begin
                        cur_mem_word[b_idx*8 +: 8] = axi_wdata[b_idx*8 +: 8];
                    end
                end
                dram_mem[waddr_reg[19:5]] <= cur_mem_word;
                // $display("Time=%0t: [TB_AXI_W] beat_idx=%0d addr=0x%0h strb=0x%0h data=0x%0h result=0x%0h", 
                //          $time, waddr_reg[19:5], waddr_reg, axi_wstrb, axi_wdata, cur_mem_word);
                waddr_reg <= waddr_reg + 32;
                if (axi_wlast) begin
                    w_active    <= 1'b0;
                    axi_wready  <= 1'b0;
                    axi_awready <= 1'b1;
                    axi_bvalid  <= 1'b1;
                end
            end
            if (axi_bvalid && axi_bready) axi_bvalid <= 1'b0;
        end
    end

    // AXI Read Channel
    reg [7:0] rlen_cnt;
    reg       r_active;
    reg [31:0] raddr_reg;
    always @(posedge clk) begin
        if (!rst_n) begin
            axi_arready <= 1'b1;
            axi_rvalid  <= 1'b0;
            axi_rlast   <= 1'b0;
            axi_rdata   <= 256'd0;
            r_active    <= 1'b0;
        end else begin
            if (axi_arvalid && axi_arready) begin
                axi_arready <= 1'b0;
                r_active    <= 1'b1;
                rlen_cnt    <= axi_arlen;
                raddr_reg   <= axi_araddr;
                axi_rvalid  <= 1'b1;
                axi_rlast   <= (axi_arlen == 0);
                axi_rdata   <= dram_mem[axi_araddr[19:5]];
                // $display("Time=%0t: [TB_AXI_AR] beat_idx=%0d addr=0x%0h rdata=0x%0h", 
                //          $time, axi_araddr[19:5], axi_araddr, dram_mem[axi_araddr[19:5]]);
            end else if (r_active && axi_rvalid && axi_rready) begin
                if (rlen_cnt == 0) begin
                    r_active    <= 1'b0;
                    axi_rvalid  <= 1'b0;
                    axi_arready <= 1'b1;
                end else begin
                    rlen_cnt    <= rlen_cnt - 1;
                    raddr_reg   <= raddr_reg + 32;
                    axi_rdata   <= dram_mem[(raddr_reg + 32) >> 5];
                    axi_rlast   <= (rlen_cnt == 1);
                    // $display("Time=%0t: [TB_AXI_R] beat_idx=%0d addr=0x%0h rdata=0x%0h", 
                    //          $time, (raddr_reg + 32) >> 5, raddr_reg + 32, dram_mem[(raddr_reg + 32) >> 5]);
                end
            end
        end
    end

`ifdef CFG_TOTAL_FRAMES
    localparam TOTAL_FRAMES = `CFG_TOTAL_FRAMES;
`else
    localparam TOTAL_FRAMES = 5;
`endif

    // Video Memory
    reg [`PIXEL_WIDTH-1:0] foreman_mem_y [0:TOTAL_FRAMES*FRAME_PIXELS_Y-1];
    reg [`PIXEL_WIDTH-1:0] foreman_mem_u [0:TOTAL_FRAMES*FRAME_PIXELS_C-1];
    reg [`PIXEL_WIDTH-1:0] foreman_mem_v [0:TOTAL_FRAMES*FRAME_PIXELS_C-1];

    initial begin
        $readmemh(HEX_FILE_Y, foreman_mem_y);
        $readmemh(HEX_FILE_U, foreman_mem_u);
        $readmemh(HEX_FILE_V, foreman_mem_v);
    end

    // File Output Stream
    integer fd_out;
    integer f_idx, ctu_idx, pix_idx;
    integer lx, ly, fx, fy, cx, cy, fcx, fcy;
    initial begin
        fd_out = $fopen(BITSTREAM_OUT, "wb");
        encode_start = 0;
        total_frames = TOTAL_FRAMES;
        in_valid   = 0;
        in_pixel_y = 0;
        in_pixel_u = `MID_GRAY_SAMPLE;
        in_pixel_v = `MID_GRAY_SAMPLE;
        out_ready  = 1;

        @(posedge rst_n);
        #20;

        $display("[%0t] Starting B-Frame & Multi-CTU Encoder with Real Video (%0dx%0d %0db, %0d Frames, %0d CTUs/frame)...",
                 $time, TB_WIDTH, TB_HEIGHT, `PIXEL_WIDTH, TOTAL_FRAMES, TOTAL_CTUS);
        @(posedge clk);
        encode_start = 1;
        total_frames = TOTAL_FRAMES;
        @(posedge clk);
        encode_start = 0;

        // ---------------------------------------------------------------------
        // Multi-Frame Streaming Loop (Foreman Frames 0 to TOTAL_FRAMES-1)
        // ---------------------------------------------------------------------
        for (f_idx = 0; f_idx < TOTAL_FRAMES; f_idx = f_idx + 1) begin
            $display("[%0t] Streaming Frame %0d/%0d (%0d CTUs)...", $time, f_idx, TOTAL_FRAMES, TOTAL_CTUS);
            for (ctu_idx = 0; ctu_idx < TOTAL_CTUS; ctu_idx = ctu_idx + 1) begin
                $display("[%0t] Streaming Frame %0d CTU %0d/%0d...", $time, f_idx, ctu_idx, TOTAL_CTUS);
                for (pix_idx = 0; pix_idx < `CTU_LUMA_SAMPLES; pix_idx = pix_idx + 1) begin
                    lx = pix_idx % `CTU_SIZE;
                    ly = pix_idx / `CTU_SIZE;
                    fx = (ctu_idx % CTUS_X) * `CTU_SIZE + lx;
                    fy = (ctu_idx / CTUS_X) * `CTU_SIZE + ly;
                    cx = lx / 2;
                    cy = ly / 2;
                    fcx = (ctu_idx % CTUS_X) * (`CTU_SIZE / 2) + cx;
                    fcy = (ctu_idx / CTUS_X) * (`CTU_SIZE / 2) + cy;

                    in_valid = 1'b1;
                    in_pixel_y = foreman_mem_y[f_idx*FRAME_PIXELS_Y + fy * TB_WIDTH + fx];
                    in_pixel_u = foreman_mem_u[f_idx*FRAME_PIXELS_C + fcy * CHROMA_WIDTH + fcx];
                    in_pixel_v = foreman_mem_v[f_idx*FRAME_PIXELS_C + fcy * CHROMA_WIDTH + fcx];
                    wait(in_ready);
                    @(posedge clk);
                end
                in_valid = 0;
                repeat(100) @(posedge clk);
            end

            // Wait for Frame completion before starting next frame, except for the last frame
            if (f_idx < TOTAL_FRAMES - 1) begin
                while (!uut.sync_frame_done_pulse) @(posedge clk);
                @(posedge clk);
            end
        end

        $display("[%0t] Input Streaming Complete (%0d Frames). Waiting for encode_done...", $time, TOTAL_FRAMES);
    end

    // Heartbeat monitor (every 10ms sim time)
    always #(10000000) begin
        $display("[%0t] Simulation Heartbeat: Frame POC=%0d, slice_type=%0d, ctu_addr=%0d, cabac_state=%0d", 
                 $time, uut.gop_frame_poc, uut.gop_frame_slice_type, uut.ctu_addr, uut.cabac_state);
    end

    // Hardware Reconstructed Frame Capture
    reg [`PIXEL_WIDTH-1:0] hw_recon_y  [0:TOTAL_FRAMES-1][0:FRAME_PIXELS_Y-1];
    reg [`PIXEL_WIDTH-1:0] hw_recon_cb [0:TOTAL_FRAMES-1][0:FRAME_PIXELS_C-1];
    reg [`PIXEL_WIDTH-1:0] hw_recon_cr [0:TOTAL_FRAMES-1][0:FRAME_PIXELS_C-1];

    integer hi_init, hf_init;
    initial begin
        for (hf_init = 0; hf_init < TOTAL_FRAMES; hf_init = hf_init + 1) begin
            for (hi_init = 0; hi_init < FRAME_PIXELS_Y; hi_init = hi_init + 1) begin
                hw_recon_y[hf_init][hi_init] = `MID_GRAY_SAMPLE;
            end
            for (hi_init = 0; hi_init < FRAME_PIXELS_C; hi_init = hi_init + 1) begin
                hw_recon_cb[hf_init][hi_init] = `MID_GRAY_SAMPLE;
                hw_recon_cr[hf_init][hi_init] = `MID_GRAY_SAMPLE;
            end
        end
    end

    always @(posedge clk) begin
        if (uut.filter_out_valid && uut.filter_out_ready) begin
            if (uut.filter_out_comp == 2'd0)
                hw_recon_y[uut.gop_frame_poc][uut.filter_out_y * TB_WIDTH + uut.filter_out_x] <= uut.filter_out_pixel;
            else if (uut.filter_out_comp == 2'd1)
                hw_recon_cb[uut.gop_frame_poc][uut.filter_out_y * CHROMA_WIDTH + uut.filter_out_x] <= uut.filter_out_pixel;
            else if (uut.filter_out_comp == 2'd2)
                hw_recon_cr[uut.gop_frame_poc][uut.filter_out_y * CHROMA_WIDTH + uut.filter_out_x] <= uut.filter_out_pixel;
        end
    end

    // File Output Monitor
    always @(posedge clk) begin
        if (out_valid && out_ready) begin
            $fwrite(fd_out, "%c", out_byte);
            // $fflush(fd_out);
            // $display("Time=%0t: [TB_OUT] byte=0x%02x (%0d)", $time, out_byte, out_byte);
        end
    end

    // =========================================================================
    // Pipeline Profiling & Cycle-Accurate Throughput Instrumentation
    // =========================================================================
    integer ctu_start_cycle [0:TOTAL_FRAMES-1][0:TOTAL_CTUS-1];
    integer ctu_total_cycles [0:TOTAL_FRAMES-1][0:TOTAL_CTUS-1];
    integer ctu_md_cycles [0:TOTAL_FRAMES-1][0:TOTAL_CTUS-1];
    integer ctu_tq_cycles [0:TOTAL_FRAMES-1][0:TOTAL_CTUS-1];
    integer ctu_db_cycles [0:TOTAL_FRAMES-1][0:TOTAL_CTUS-1];
    integer ctu_cabac_cycles [0:TOTAL_FRAMES-1][0:TOTAL_CTUS-1];
    integer ctu_stall_cabac [0:TOTAL_FRAMES-1][0:TOTAL_CTUS-1];
    integer ctu_stall_inloop [0:TOTAL_FRAMES-1][0:TOTAL_CTUS-1];

    reg [31:0] global_cycle_count;
    reg [9:0]  cur_mon_poc;
    reg [`CTU_ADDR_WIDTH-1:0] cur_mon_ctu;
    reg        mon_ctu_active;

    wire md_stage_active    = (uut.u_mode_decision.state != 3'd0) || uut.eval_inter_start;
    wire tq_stage_active    = uut.p2s_active || uut.idct_active || uut.idct_p2s_active || uut.recon_out_valid || uut.intra_ref_active;
    wire db_stage_active    = (uut.u_inloop_filters.filter_state == 2'd1); // S_DB
    wire cabac_stage_active = (uut.cabac_state != 3'd0);
    wire stall_cabac_active = uut.cu_valid && !uut.cabac_cu_ready;
    wire stall_inloop_active= (uut.u_inloop_filters.filter_state == 2'd0) && !uut.inloop_ready;

    integer cur_f, cur_c;
    initial begin
        global_cycle_count = 32'd0;
        for (cur_f = 0; cur_f < TOTAL_FRAMES; cur_f = cur_f + 1) begin
            for (cur_c = 0; cur_c < TOTAL_CTUS; cur_c = cur_c + 1) begin
                ctu_start_cycle[cur_f][cur_c] = 0;
                ctu_total_cycles[cur_f][cur_c] = 0;
                ctu_md_cycles[cur_f][cur_c] = 0;
                ctu_tq_cycles[cur_f][cur_c] = 0;
                ctu_db_cycles[cur_f][cur_c] = 0;
                ctu_cabac_cycles[cur_f][cur_c] = 0;
                ctu_stall_cabac[cur_f][cur_c] = 0;
                ctu_stall_inloop[cur_f][cur_c] = 0;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            global_cycle_count <= 32'd0;
            cur_mon_poc        <= 10'd0;
            cur_mon_ctu        <= {`CTU_ADDR_WIDTH{1'b0}};
            mon_ctu_active     <= 1'b0;
        end else begin
            global_cycle_count <= global_cycle_count + 32'd1;

            if (uut.ctu_partitioner_accepted) begin
                cur_mon_poc <= uut.gop_frame_poc;
                cur_mon_ctu <= uut.ctu_addr;
                mon_ctu_active <= 1'b1;
                ctu_start_cycle[uut.gop_frame_poc][uut.ctu_addr] <= global_cycle_count;
            end

            if (mon_ctu_active) begin
                ctu_total_cycles[cur_mon_poc][cur_mon_ctu] <= ctu_total_cycles[cur_mon_poc][cur_mon_ctu] + 1;
                if (md_stage_active)
                    ctu_md_cycles[cur_mon_poc][cur_mon_ctu] <= ctu_md_cycles[cur_mon_poc][cur_mon_ctu] + 1;
                if (tq_stage_active)
                    ctu_tq_cycles[cur_mon_poc][cur_mon_ctu] <= ctu_tq_cycles[cur_mon_poc][cur_mon_ctu] + 1;
                if (db_stage_active)
                    ctu_db_cycles[cur_mon_poc][cur_mon_ctu] <= ctu_db_cycles[cur_mon_poc][cur_mon_ctu] + 1;
                if (cabac_stage_active)
                    ctu_cabac_cycles[cur_mon_poc][cur_mon_ctu] <= ctu_cabac_cycles[cur_mon_poc][cur_mon_ctu] + 1;
                if (stall_cabac_active)
                    ctu_stall_cabac[cur_mon_poc][cur_mon_ctu] <= ctu_stall_cabac[cur_mon_poc][cur_mon_ctu] + 1;
                if (stall_inloop_active)
                    ctu_stall_inloop[cur_mon_poc][cur_mon_ctu] <= ctu_stall_inloop[cur_mon_poc][cur_mon_ctu] + 1;
            end

            if (uut.inloop_ctu_done) begin
                mon_ctu_active <= 1'b0;
                $display("[PROFILER] Frame %0d CTU %0d: Total=%0d cycles | T_MD=%0d | T_TQ=%0d | T_DB=%0d | T_CABAC=%0d | Stall_CABAC=%0d | Stall_Inloop=%0d",
                    cur_mon_poc, cur_mon_ctu,
                    ctu_total_cycles[cur_mon_poc][cur_mon_ctu],
                    ctu_md_cycles[cur_mon_poc][cur_mon_ctu],
                    ctu_tq_cycles[cur_mon_poc][cur_mon_ctu],
                    ctu_db_cycles[cur_mon_poc][cur_mon_ctu],
                    ctu_cabac_cycles[cur_mon_poc][cur_mon_ctu],
                    ctu_stall_cabac[cur_mon_poc][cur_mon_ctu],
                    ctu_stall_inloop[cur_mon_poc][cur_mon_ctu]);
            end
        end
    end

    // =========================================================================
    // Stall Watchdog & Heartbeat Timers
    // =========================================================================
    reg [31:0] stall_cabac_timer;
    reg [31:0] stall_inloop_timer;
    reg [31:0] ctu_progress_timer;

    localparam MAX_CONSECUTIVE_STALL = `STALL_WATCHDOG_LIMIT;
    localparam MAX_CTU_PROGRESS      = `CTU_WATCHDOG_LIMIT;
    localparam HEARTBEAT_INTERVAL    = `HEARTBEAT_INTERVAL;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stall_cabac_timer  <= 32'd0;
            stall_inloop_timer <= 32'd0;
            ctu_progress_timer <= 32'd0;
        end else begin
            // 1. Periodic Heartbeat Monitor
            if (global_cycle_count > 0 && (global_cycle_count % HEARTBEAT_INTERVAL == 0)) begin
                $display("[HEARTBEAT] Time=%0t | Cycles=%0d | POC=%0d CTU=%0d | CTU_Cycles=%0d | CABAC_Stall=%0d Inloop_Stall=%0d",
                    $time, global_cycle_count, cur_mon_poc, cur_mon_ctu, ctu_progress_timer, stall_cabac_timer, stall_inloop_timer);
            end

            // 2. CABAC Backpressure Stall Watchdog
            if (stall_cabac_active) begin
                stall_cabac_timer <= stall_cabac_timer + 32'd1;
                if (stall_cabac_timer >= MAX_CONSECUTIVE_STALL) begin
                    $display("\n[ERROR] [STALL_WATCHDOG] CABAC backpressure stall exceeded %0d consecutive cycles at time %0t!",
                             MAX_CONSECUTIVE_STALL, $time);
                    $display("        Current CTU: (%0d, %0d), POC: %0d", cur_mon_poc, cur_mon_ctu, uut.gop_frame_poc);
                    $display("        CABAC state: %0d, RangeCoder range: %0d", uut.cabac_state, uut.u_cabac_enc_top.u_rc.range_r);
                    $finish;
                end
            end else begin
                stall_cabac_timer <= 32'd0;
            end

            // 3. Inloop Filter Stall Watchdog
            if (stall_inloop_active) begin
                stall_inloop_timer <= stall_inloop_timer + 32'd1;
                if (stall_inloop_timer >= MAX_CONSECUTIVE_STALL) begin
                    $display("\n[ERROR] [STALL_WATCHDOG] Inloop filter stall exceeded %0d consecutive cycles at time %0t!",
                             MAX_CONSECUTIVE_STALL, $time);
                    $display("        Current CTU: (%0d, %0d), POC: %0d", cur_mon_poc, cur_mon_ctu, uut.gop_frame_poc);
                    $display("        Filter state: %0d, dump_count: %0d", uut.u_inloop_filters.filter_state, uut.u_inloop_filters.dump_count);
                    $finish;
                end
            end else begin
                stall_inloop_timer <= 32'd0;
            end

            // 4. CTU Execution Duration Watchdog
            if (mon_ctu_active) begin
                ctu_progress_timer <= ctu_progress_timer + 32'd1;
                if (ctu_progress_timer >= MAX_CTU_PROGRESS) begin
                    $display("\n[ERROR] [STALL_WATCHDOG] CTU progress watchdog tripped! CTU %0d has run for %0d cycles (> %0d limit) at time %0t!",
                             cur_mon_ctu, ctu_progress_timer, MAX_CTU_PROGRESS, $time);
                    $display("        Pipeline States: MD state=%0d, TQ active=%b, DB state=%0d, CABAC state=%0d",
                             uut.u_mode_decision.state, tq_stage_active, uut.u_inloop_filters.filter_state, uut.cabac_state);
                    $finish;
                end
            end else begin
                ctu_progress_timer <= 32'd0;
            end
        end
    end

    // Rate Control Monitor
    always @(posedge clk) begin
        if (uut.sync_frame_done_pulse) begin
            $display("[RATE_CONTROL] Frame %0d Finished: SliceType=%0d, FrameBits=%0d, NextQP=%0d, SliceDeltaQP=%0d, VBV_Fullness=%0d%%", 
                     uut.gop_frame_poc, uut.gop_frame_slice_type, uut.frame_bit_counter, uut.rc_frame_qp, uut.rc_slice_qp_delta, uut.rc_vbv_fullness);
        end
    end

    // Completion Monitor
    integer fd_hw, h_f, h_i;
    always @(posedge clk) begin
        if (encode_done) begin
            $display("[%0t] %0dx%0d %0d-Frame Encoding Finished Successfully!", $time, TB_WIDTH, TB_HEIGHT, TOTAL_FRAMES);
            // Write standard Annex B End of Sequence (EOS) NAL unit: 00 00 00 01 48 01
            $fwrite(fd_out, "%c%c%c%c%c%c", 8'h00, 8'h00, 8'h00, 8'h01, 8'h48, 8'h01);
            $fflush(fd_out);
            $fclose(fd_out);

            // Dump Hardware Reconstructed Frame to RECON_OUT (10-bit Little Endian)
            fd_hw = $fopen(RECON_OUT, "wb");
            for (h_f = 0; h_f < TOTAL_FRAMES; h_f = h_f + 1) begin
                for (h_i = 0; h_i < FRAME_PIXELS_Y; h_i = h_i + 1) begin
                    $fwrite(fd_hw, "%c%c", hw_recon_y[h_f][h_i][7:0], {6'd0, hw_recon_y[h_f][h_i][9:8]});
                end
                for (h_i = 0; h_i < FRAME_PIXELS_C; h_i = h_i + 1) begin
                    $fwrite(fd_hw, "%c%c", hw_recon_cb[h_f][h_i][7:0], {6'd0, hw_recon_cb[h_f][h_i][9:8]});
                end
                for (h_i = 0; h_i < FRAME_PIXELS_C; h_i = h_i + 1) begin
                    $fwrite(fd_hw, "%c%c", hw_recon_cr[h_f][h_i][7:0], {6'd0, hw_recon_cr[h_f][h_i][9:8]});
                end
            end
            $fclose(fd_hw);
            $display("Dumping Hardware Reconstructed frame: hw_recon.yuv complete.");

            // Print Pipeline Profiling Scorecard
            $display("\n====================================================================================================");
            $display("                            PIPELINE PROFILING & THROUGHPUT SCORECARD                               ");
            $display("====================================================================================================");
            $display(" Frame | CTU | Total Cyc | T_MD (cyc) | T_TQ (cyc) | T_DB (cyc) | T_CABAC (cyc) | Stall_CABAC | Stall_Inloop");
            $display("-------+-----+-----------+------------+------------+------------+---------------+-------------+-------------");
            for (h_f = 0; h_f < TOTAL_FRAMES; h_f = h_f + 1) begin
                for (h_i = 0; h_i < TOTAL_CTUS; h_i = h_i + 1) begin
                    $display("   %0d   |  %0d  |   %7d |    %7d |    %7d |    %7d |       %7d |     %7d |     %7d",
                        h_f, h_i,
                        ctu_total_cycles[h_f][h_i],
                        ctu_md_cycles[h_f][h_i],
                        ctu_tq_cycles[h_f][h_i],
                        ctu_db_cycles[h_f][h_i],
                        ctu_cabac_cycles[h_f][h_i],
                        ctu_stall_cabac[h_f][h_i],
                        ctu_stall_inloop[h_f][h_i]
                    );
                end
            end
            $display("====================================================================================================\n");

            $finish;
        end
    end

    // Watchdog (100 x 100ms = 10s sim time)
    initial begin
        repeat(100) #100000000;
        $display("ERROR: Simulation timeout reached!");
        $finish;
    end

endmodule
