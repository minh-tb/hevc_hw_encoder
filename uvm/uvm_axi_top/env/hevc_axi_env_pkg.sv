`timescale 1ns / 1ps
//=============================================================================
// hevc_axi_env_pkg.sv
// Phase 3 Tier 2 UVM SoC Integration Package for hevc_encoder_axi_top:
//   - hevc_virtual_sequencer
//   - hevc_axi_coverage (functional covergroup cg_soc_axi)
//   - hevc_axi_scoreboard (CSR checks, Annex B capture -> uvm_axi_out.bin, DRAM check)
//   - hevc_axi_env (4 AMBA VIP agents + RAL block + predictor + v_sqr + sb + cov)
//=============================================================================

package hevc_axi_env_pkg;

    import uvm_pkg::*;
    import hevc_ral_pkg::*;
    import hevc_axi_vip_pkg::*;
    `include "uvm_macros.svh"

    `uvm_analysis_imp_decl(_axi_lite)
    `uvm_analysis_imp_decl(_video)
    `uvm_analysis_imp_decl(_bitstream)
    `uvm_analysis_imp_decl(_mem)

    //=========================================================================
    // Virtual Sequencer
    //=========================================================================
    class hevc_virtual_sequencer extends uvm_sequencer #(uvm_sequence_item);
        `uvm_component_utils(hevc_virtual_sequencer)

        hevc_reg_block       reg_model;
        axi_lite_sequencer   axi_lite_sqr;
        axis_video_sequencer axis_video_sqr;

        function new(string name = "hevc_virtual_sequencer", uvm_component parent = null);
            super.new(name, parent);
        endfunction
    endclass

    //=========================================================================
    // Functional Coverage Collector
    //=========================================================================
    typedef enum int {
        COV_EV_AXI_LITE     = 0,
        COV_EV_BS_TLAST     = 1,
        COV_EV_BS_HANDSHAKE = 2
    } cov_event_kind_e;

    class hevc_axi_coverage extends uvm_component;
        `uvm_component_utils(hevc_axi_coverage)

        uvm_analysis_imp_axi_lite  #(axi_lite_txn, hevc_axi_coverage)       axi_lite_imp;
        uvm_analysis_imp_bitstream #(axis_bitstream_pkt, hevc_axi_coverage) bitstream_imp;

        virtual hevc_axi_if vif;

        // Sampled fields for cg_soc_axi
        cov_event_kind_e cov_ev_kind;
        bit [11:0]       cov_csr_addr;
        bit              cov_is_write;
        bit [5:0]        cov_base_qp;
        bit [1:0]        cov_gop_structure;
        bit              cov_soft_rst;
        bit              cov_irq_w1c;
        bit              cov_bs_tlast;
        bit              cov_bs_tready;

        int unsigned     bs_stall_cycles;
        int unsigned     bs_ready_cycles;
        int unsigned     axi_lite_samples;
        int unsigned     bs_tlast_samples;

        covergroup cg_soc_axi;
            option.per_instance = 1;

            cp_csr_addr: coverpoint cov_csr_addr iff (cov_ev_kind == COV_EV_AXI_LITE) {
                bins ctrl           = {12'h000};
                bins status         = {12'h004};
                bins irq_status     = {12'h008};
                bins total_frames   = {12'h00C};
                bins base_qp        = {12'h010};
                bins gop_structure  = {12'h014};
                bins target_bitrate = {12'h018};
                bins magic_id       = {12'h01C};
                bins resolution     = {12'h020};
                bins vbv_fullness   = {12'h024};
            }

            cp_csr_rw: coverpoint cov_is_write iff (cov_ev_kind == COV_EV_AXI_LITE) {
                bins read_op  = {1'b0};
                bins write_op = {1'b1};
            }

            cx_csr_addr_rw: cross cp_csr_addr, cp_csr_rw {
                // Exclude writes to strictly Read-Only CSRs
                ignore_bins ro_writes = binsof(cp_csr_rw) intersect {1'b1} &&
                                        binsof(cp_csr_addr) intersect {12'h004, 12'h01C, 12'h020, 12'h024};
            }

            cp_base_qp: coverpoint cov_base_qp
                iff (cov_ev_kind == COV_EV_AXI_LITE && cov_is_write && cov_csr_addr == 12'h010) {
                bins qp_low  = {[0:21]};
                bins qp_mid  = {[22:37]};
                bins qp_high = {[38:51]};
            }

            cp_gop_structure: coverpoint cov_gop_structure
                iff (cov_ev_kind == COV_EV_AXI_LITE && cov_is_write && cov_csr_addr == 12'h014) {
                bins gop_ipp    = {2'd0};
                bins gop_ipbb   = {2'd1};
                bins gop_hier_b = {2'd2};
            }

            cp_soft_reset: coverpoint cov_soft_rst
                iff (cov_ev_kind == COV_EV_AXI_LITE && cov_is_write && cov_csr_addr == 12'h000) {
                bins deasserted = {1'b0};
                bins asserted   = {1'b1};
            }

            cp_irq_w1c: coverpoint cov_irq_w1c
                iff (cov_ev_kind == COV_EV_AXI_LITE && cov_is_write && cov_csr_addr == 12'h008) {
                bins w1c_clear = {1'b1};
            }

            cp_bs_tlast: coverpoint cov_bs_tlast iff (cov_ev_kind == COV_EV_BS_TLAST) {
                bins frame_complete = {1'b1};
            }

            cp_bs_backpressure: coverpoint cov_bs_tready iff (cov_ev_kind == COV_EV_BS_HANDSHAKE) {
                bins stalled = {1'b0};
                bins ready   = {1'b1};
            }
        endgroup

        function new(string name = "hevc_axi_coverage", uvm_component parent = null);
            super.new(name, parent);
            axi_lite_imp     = new("axi_lite_imp", this);
            bitstream_imp    = new("bitstream_imp", this);
            cg_soc_axi       = new();
            bs_stall_cycles  = 0;
            bs_ready_cycles  = 0;
            axi_lite_samples = 0;
            bs_tlast_samples = 0;
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual hevc_axi_if)::get(this, "", "vif", vif)) begin
                `uvm_warning("AXI_COV", "Virtual interface 'vif' not found; cycle-level backpressure sampling disabled")
            end
        endfunction

        virtual function void write_axi_lite(axi_lite_txn tr);
            cov_ev_kind       = COV_EV_AXI_LITE;
            cov_csr_addr      = tr.addr;
            cov_is_write      = tr.is_write;
            cov_base_qp       = tr.data[5:0];
            cov_gop_structure = tr.data[1:0];
            cov_soft_rst      = tr.data[1];
            cov_irq_w1c       = tr.data[0];
            cg_soc_axi.sample();
            axi_lite_samples++;
        endfunction

        virtual function void write_bitstream(axis_bitstream_pkt pkt);
            cov_ev_kind  = COV_EV_BS_TLAST;
            cov_bs_tlast = (pkt.tlast_cnt > 0) ? 1'b1 : 1'b0;
            cg_soc_axi.sample();
            bs_tlast_samples++;
        endfunction

        virtual task run_phase(uvm_phase phase);
            if (vif == null) return;
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n !== 1'b1) continue;
                if (vif.m_axis_bitstream_tvalid === 1'b1) begin
                    cov_ev_kind   = COV_EV_BS_HANDSHAKE;
                    cov_bs_tready = vif.m_axis_bitstream_tready;
                    cg_soc_axi.sample();
                    if (vif.m_axis_bitstream_tready === 1'b0)
                        bs_stall_cycles++;
                    else
                        bs_ready_cycles++;
                end
            end
        endtask

        virtual function real get_overall_coverage();
            return cg_soc_axi.get_inst_coverage();
        endfunction

        virtual function void report_phase(uvm_phase phase);
            super.report_phase(phase);
            `uvm_info("AXI_COV", $sformatf({
                "\n==========================================================\n",
                " SoC AXI FUNCTIONAL COVERAGE SUMMARY (cg_soc_axi)\n",
                "----------------------------------------------------------\n",
                "  Overall cg_soc_axi   : %0.2f%%\n",
                "  cp_csr_addr          : %0.2f%%\n",
                "  cp_csr_rw            : %0.2f%%\n",
                "  cx_csr_addr_rw       : %0.2f%%\n",
                "  cp_base_qp           : %0.2f%%\n",
                "  cp_gop_structure     : %0.2f%%\n",
                "  cp_soft_reset        : %0.2f%%\n",
                "  cp_irq_w1c           : %0.2f%%\n",
                "  cp_bs_tlast          : %0.2f%%\n",
                "  cp_bs_backpressure   : %0.2f%%\n",
                "  Samples (Lite/TLAST) : %0d / %0d\n",
                "  BS Handshake (St/Rd) : %0d / %0d cycles\n",
                "=========================================================="},
                cg_soc_axi.get_inst_coverage(),
                cg_soc_axi.cp_csr_addr.get_inst_coverage(),
                cg_soc_axi.cp_csr_rw.get_inst_coverage(),
                cg_soc_axi.cx_csr_addr_rw.get_inst_coverage(),
                cg_soc_axi.cp_base_qp.get_inst_coverage(),
                cg_soc_axi.cp_gop_structure.get_inst_coverage(),
                cg_soc_axi.cp_soft_reset.get_inst_coverage(),
                cg_soc_axi.cp_irq_w1c.get_inst_coverage(),
                cg_soc_axi.cp_bs_tlast.get_inst_coverage(),
                cg_soc_axi.cp_bs_backpressure.get_inst_coverage(),
                axi_lite_samples, bs_tlast_samples,
                bs_stall_cycles, bs_ready_cycles), UVM_LOW)
        endfunction
    endclass

    //=========================================================================
    // SoC Scoreboard
    //=========================================================================
    class hevc_axi_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(hevc_axi_scoreboard)

        uvm_analysis_imp_axi_lite  #(axi_lite_txn, hevc_axi_scoreboard)          axi_lite_imp;
        uvm_analysis_imp_video     #(axis_video_frame_item, hevc_axi_scoreboard) video_imp;
        uvm_analysis_imp_bitstream #(axis_bitstream_pkt, hevc_axi_scoreboard)    bitstream_imp;
        uvm_analysis_imp_mem       #(axi4_mem_txn, hevc_axi_scoreboard)          mem_imp;

        // Expected CSR identity & dimensions
        bit [31:0]   exp_magic_id   = 32'h48455643;
        bit [31:0]   exp_resolution = 32'h00400040;
        int unsigned exp_frame_px   = 4096;

        // Bitstream capture file
        string       bitstream_out_file = "uvm_axi_out.bin";
        protected int bs_fd = 0;
        protected bit bs_file_opened = 1'b0;

        // Counters
        int unsigned axi_lite_rd_cnt;
        int unsigned axi_lite_wr_cnt;
        int unsigned magic_id_checks;
        int unsigned resolution_checks;
        int unsigned video_frames_rcvd;
        int unsigned video_pixels_total;
        int unsigned bs_pkts_rcvd;
        int unsigned bs_bytes_total;
        int unsigned mem_wr_txns;
        int unsigned mem_wr_beats;
        int unsigned mem_rd_txns;
        int unsigned mem_rd_beats;
        int unsigned sb_errors;

        function new(string name = "hevc_axi_scoreboard", uvm_component parent = null);
            super.new(name, parent);
            axi_lite_imp  = new("axi_lite_imp", this);
            video_imp     = new("video_imp", this);
            bitstream_imp = new("bitstream_imp", this);
            mem_imp       = new("mem_imp", this);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            int plusarg_ok;
            super.build_phase(phase);
            plusarg_ok = $value$plusargs("BITSTREAM_OUT=%s", bitstream_out_file);
        endfunction

        virtual function void write_axi_lite(axi_lite_txn tr);
            if (tr.resp !== 2'b00) begin
                sb_errors++;
                `uvm_error("AXI_SB", $sformatf("AXI4-Lite non-OKAY resp (%0b) on %s", tr.resp, tr.convert2string()))
            end

            if (tr.is_write) begin
                axi_lite_wr_cnt++;
            end else begin
                axi_lite_rd_cnt++;
                if (tr.addr == 12'h01C) begin
                    magic_id_checks++;
                    if (tr.data !== exp_magic_id) begin
                        sb_errors++;
                        `uvm_error("AXI_SB", $sformatf(
                            "MAGIC_ID readback mismatch: got 0x%08h, expected 0x%08h",
                            tr.data, exp_magic_id))
                    end
                end else if (tr.addr == 12'h020) begin
                    resolution_checks++;
                    if (tr.data !== exp_resolution) begin
                        sb_errors++;
                        `uvm_error("AXI_SB", $sformatf(
                            "RESOLUTION readback mismatch: got 0x%08h, expected 0x%08h",
                            tr.data, exp_resolution))
                    end
                end
            end
        endfunction

        virtual function void write_video(axis_video_frame_item frame);
            video_frames_rcvd++;
            video_pixels_total += frame.tdata_q.size();
            if (frame.tdata_q.size() != exp_frame_px) begin
                sb_errors++;
                `uvm_error("AXI_SB", $sformatf(
                    "Video frame #%0d pixel count mismatch: got %0d, expected %0d",
                    video_frames_rcvd, frame.tdata_q.size(), exp_frame_px))
            end else begin
                `uvm_info("AXI_SB", $sformatf(
                    "Observed video frame #%0d (%0d pixels)",
                    video_frames_rcvd, frame.tdata_q.size()), UVM_MEDIUM)
            end
        endfunction

        virtual function void write_bitstream(axis_bitstream_pkt pkt);
            int unsigned pkt_bytes = pkt.data.size();
            bs_pkts_rcvd++;
            bs_bytes_total += pkt_bytes;

            if (pkt_bytes <= 50) begin
                sb_errors++;
                `uvm_error("AXI_SB", $sformatf(
                    "Bitstream packet #%0d too small: %0d bytes (expected > 50)",
                    pkt.pkt_id, pkt_bytes))
            end

            if (pkt_bytes < 4 ||
                pkt.data[0] !== 8'h00 ||
                pkt.data[1] !== 8'h00 ||
                pkt.data[2] !== 8'h00 ||
                pkt.data[3] !== 8'h01) begin
                sb_errors++;
                `uvm_error("AXI_SB", $sformatf(
                    "Bitstream packet #%0d missing Annex B 4-byte start code 00 00 00 01 (got %02x %02x %02x %02x)",
                    pkt.pkt_id,
                    (pkt_bytes > 0) ? pkt.data[0] : 8'h00,
                    (pkt_bytes > 1) ? pkt.data[1] : 8'h00,
                    (pkt_bytes > 2) ? pkt.data[2] : 8'h00,
                    (pkt_bytes > 3) ? pkt.data[3] : 8'h00))
            end

            if (!bs_file_opened) begin
                bs_fd = $fopen(bitstream_out_file, "wb");
                if (bs_fd == 0) begin
                    `uvm_fatal("AXI_SB", $sformatf("Cannot open bitstream output file '%s' for writing", bitstream_out_file))
                end
                bs_file_opened = 1'b1;
            end

            foreach (pkt.data[i]) begin
                $fwrite(bs_fd, "%c", pkt.data[i]);
            end
            $fflush(bs_fd);

            `uvm_info("AXI_SB", $sformatf(
                "Captured Annex B bitstream packet #%0d (%0d bytes, start=%02x %02x %02x %02x) -> '%s'",
                pkt.pkt_id, pkt_bytes,
                (pkt_bytes > 0) ? pkt.data[0] : 8'h00,
                (pkt_bytes > 1) ? pkt.data[1] : 8'h00,
                (pkt_bytes > 2) ? pkt.data[2] : 8'h00,
                (pkt_bytes > 3) ? pkt.data[3] : 8'h00,
                bitstream_out_file), UVM_LOW)
        endfunction

        virtual function void write_mem(axi4_mem_txn tr);
            if (tr.resp !== 2'b00) begin
                sb_errors++;
                `uvm_error("AXI_SB", $sformatf("AXI4 DRAM non-OKAY resp (%0b) on %s", tr.resp, tr.convert2string()))
            end
            if (tr.is_write) begin
                mem_wr_txns++;
                mem_wr_beats += tr.data.size();
            end else begin
                mem_rd_txns++;
                mem_rd_beats += tr.data.size();
            end
        endfunction

        virtual function void check_phase(uvm_phase phase);
            super.check_phase(phase);

            if (bs_file_opened) begin
                $fflush(bs_fd);
                $fclose(bs_fd);
                bs_file_opened = 1'b0;
            end

            if (magic_id_checks == 0) begin
                sb_errors++;
                `uvm_error("AXI_SB", "MAGIC_ID (0x1C) was never read/verified during test")
            end
            if (resolution_checks == 0) begin
                sb_errors++;
                `uvm_error("AXI_SB", "RESOLUTION (0x20) was never read/verified during test")
            end

            if (video_frames_rcvd > 0) begin
                if (bs_pkts_rcvd < video_frames_rcvd) begin
                    sb_errors++;
                    `uvm_error("AXI_SB", $sformatf(
                        "Bitstream TLAST packet count (%0d) < encoded video frames (%0d)",
                        bs_pkts_rcvd, video_frames_rcvd))
                end
                if (mem_wr_txns == 0) begin
                    sb_errors++;
                    `uvm_error("AXI_SB", "No AXI4 DRAM write transactions observed during frame encode!")
                end
                if ((video_frames_rcvd > 1) && (mem_rd_txns == 0)) begin
                    sb_errors++;
                    `uvm_error("AXI_SB", "Multi-frame encode produced zero AXI4 DRAM reference read transactions!")
                end
            end
        endfunction

        virtual function void report_phase(uvm_phase phase);
            super.report_phase(phase);
            `uvm_info("AXI_SB", $sformatf({
                "\n==========================================================\n",
                " HEVC SoC AXI SCOREBOARD SUMMARY\n",
                "----------------------------------------------------------\n",
                "  AXI4-Lite Reads/Writes : %0d / %0d\n",
                "  MAGIC_ID Checks        : %0d\n",
                "  RESOLUTION Checks      : %0d\n",
                "  Video Frames Streamed  : %0d (%0d pixels)\n",
                "  Bitstream Packets      : %0d (%0d bytes)\n",
                "  Bitstream Output File  : %s\n",
                "  DRAM Write Txns/Beats  : %0d / %0d\n",
                "  DRAM Read Txns/Beats   : %0d / %0d\n",
                "  Scoreboard Errors      : %0d\n",
                "=========================================================="},
                axi_lite_rd_cnt, axi_lite_wr_cnt,
                magic_id_checks, resolution_checks,
                video_frames_rcvd, video_pixels_total,
                bs_pkts_rcvd, bs_bytes_total,
                (bs_pkts_rcvd > 0) ? bitstream_out_file : "(none)",
                mem_wr_txns, mem_wr_beats,
                mem_rd_txns, mem_rd_beats,
                sb_errors), UVM_LOW)
        endfunction
    endclass

    //=========================================================================
    // Top-Level SoC Verification Environment
    //=========================================================================
    class hevc_axi_env extends uvm_env;
        `uvm_component_utils(hevc_axi_env)

        axi_lite_agent                 axi_lite_agt;
        axis_video_agent               axis_vid_agt;
        axis_bitstream_agent           axis_bs_agt;
        axi4_mem_agent                 axi_mem_agt;

        hevc_reg_block                 reg_model;
        reg2axi_lite_adapter           adapter;
        uvm_reg_predictor #(axi_lite_txn) predictor;

        hevc_virtual_sequencer         v_sqr;
        hevc_axi_scoreboard            sb;
        hevc_axi_coverage              cov;

        function new(string name = "hevc_axi_env", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);

            axi_lite_agt = axi_lite_agent::type_id::create("axi_lite_agt", this);
            axis_vid_agt = axis_video_agent::type_id::create("axis_vid_agt", this);
            axis_bs_agt  = axis_bitstream_agent::type_id::create("axis_bs_agt", this);
            axi_mem_agt  = axi4_mem_agent::type_id::create("axi_mem_agt", this);

            reg_model = hevc_reg_block::type_id::create("reg_model");
            reg_model.set_default_params(16'd64, 16'd64, 6'd28, 2'd0, 16'd5000);
            reg_model.build();

            adapter   = reg2axi_lite_adapter::type_id::create("adapter");
            predictor = uvm_reg_predictor #(axi_lite_txn)::type_id::create("predictor", this);

            v_sqr     = hevc_virtual_sequencer::type_id::create("v_sqr", this);
            sb        = hevc_axi_scoreboard::type_id::create("sb", this);
            cov       = hevc_axi_coverage::type_id::create("cov", this);
        endfunction

        virtual function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);

            // Explicit RAL prediction from axi_lite_monitor
            reg_model.default_map.set_sequencer(axi_lite_agt.sqr, adapter);
            reg_model.default_map.set_auto_predict(0);
            predictor.map     = reg_model.default_map;
            predictor.adapter = adapter;
            axi_lite_agt.ap.connect(predictor.bus_in);

            // Virtual sequencer wiring
            v_sqr.reg_model      = reg_model;
            v_sqr.axi_lite_sqr   = axi_lite_agt.sqr;
            v_sqr.axis_video_sqr = axis_vid_agt.sqr;

            // Scoreboard connections
            axi_lite_agt.ap.connect(sb.axi_lite_imp);
            axis_vid_agt.ap.connect(sb.video_imp);
            axis_bs_agt.ap.connect(sb.bitstream_imp);
            axi_mem_agt.ap.connect(sb.mem_imp);

            // Coverage connections
            axi_lite_agt.ap.connect(cov.axi_lite_imp);
            axis_bs_agt.ap.connect(cov.bitstream_imp);
        endfunction
    endclass

endpackage
