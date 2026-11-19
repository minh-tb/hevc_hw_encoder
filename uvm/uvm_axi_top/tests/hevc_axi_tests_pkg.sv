`timescale 1ns / 1ps
//=============================================================================
// hevc_axi_tests_pkg.sv
// Phase 3 Tier 2 UVM Sequences & Tests for hevc_encoder_axi_top:
//   - axis_video_single_frame_seq (streams 1 frame via axis_video_sequencer)
//   - hevc_csr_rand_cfg (constrained-random CSR sweep item)
//   - hevc_axi_base_test (shared env + RAL helpers)
//   - hevc_ral_audit_test (hw_reset_seq, bit_bash_seq, CSR sweeps, soft reset)
//   - hevc_full_uvm_test (backpressure + DRAM latency + encode + IRQ W1C + HM)
//=============================================================================

package hevc_axi_tests_pkg;

    import uvm_pkg::*;
    import hevc_ral_pkg::*;
    import hevc_axi_vip_pkg::*;
    import hevc_axi_env_pkg::*;
    `include "uvm_macros.svh"

    //=========================================================================
    // Video Frame Sequence
    //=========================================================================
    class axis_video_single_frame_seq extends uvm_sequence #(axis_video_frame_item);
        `uvm_object_utils(axis_video_single_frame_seq)

        video_pattern_e pattern     = VIDEO_PAT_GRADIENT;
        int unsigned    width       = 64;
        int unsigned    height      = 64;
        int unsigned    bubble_prob = 15;

        function new(string name = "axis_video_single_frame_seq");
            super.new(name);
        endfunction

        virtual task body();
            axis_video_frame_item item = axis_video_frame_item::type_id::create("item");
            start_item(item);
            if (!item.randomize() with {
                pattern     == local::pattern;
                width       == local::width;
                height      == local::height;
                bubble_prob == local::bubble_prob;
            }) begin
                `uvm_fatal("VID_SEQ", "Failed to randomize axis_video_frame_item")
            end
            finish_item(item);
        endtask
    endclass

    //=========================================================================
    // Constrained-Random CSR Configuration Stimulus
    //=========================================================================
    class hevc_csr_rand_cfg extends uvm_object;
        `uvm_object_utils(hevc_csr_rand_cfg)

        rand bit [5:0]  base_qp;
        rand bit [1:0]  gop_structure;
        rand bit [15:0] target_bitrate;
        rand bit [15:0] total_frames;

        constraint c_legal {
            base_qp        inside {[0:51]};
            gop_structure  inside {[0:2]};
            target_bitrate inside {[500:25000]};
            total_frames   inside {[1:30]};
        }

        function new(string name = "hevc_csr_rand_cfg");
            super.new(name);
        endfunction
    endclass

    //=========================================================================
    // Base Test
    //=========================================================================
    class hevc_axi_base_test extends uvm_test;
        `uvm_component_utils(hevc_axi_base_test)

        hevc_axi_env        env;
        virtual hevc_axi_if vif;

        function new(string name = "hevc_axi_base_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = hevc_axi_env::type_id::create("env", this);
            if (!uvm_config_db #(virtual hevc_axi_if)::get(this, "", "vif", vif)) begin
                `uvm_fatal("NOVIF", "hevc_axi_base_test could not retrieve virtual interface 'vif'")
            end
        endfunction

        virtual task wait_reset_done();
            wait (vif.rst_n === 1'b1);
            repeat (3) @(posedge vif.clk);
        endtask

        virtual task ral_write(uvm_reg rg, uvm_reg_data_t val);
            uvm_status_e status;
            rg.write(status, val, UVM_FRONTDOOR);
            if (status != UVM_IS_OK) begin
                `uvm_error("RAL_WR", $sformatf("Write failed on %s (status=%s)", rg.get_name(), status.name()))
            end
        endtask

        virtual task ral_read(uvm_reg rg, output uvm_reg_data_t val);
            uvm_status_e status;
            rg.read(status, val, UVM_FRONTDOOR);
            if (status != UVM_IS_OK) begin
                `uvm_error("RAL_RD", $sformatf("Read failed on %s (status=%s)", rg.get_name(), status.name()))
            end
        endtask

        virtual task ral_mirror_check(uvm_reg rg);
            uvm_status_e status;
            rg.mirror(status, UVM_CHECK, UVM_FRONTDOOR);
            if (status != UVM_IS_OK) begin
                `uvm_error("RAL_CHK", $sformatf("Mirror check failed on %s (status=%s)", rg.get_name(), status.name()))
            end
        endtask

        virtual task verify_soft_reset();
            uvm_reg_data_t val;

            // Assert SOFT_RESET (CTRL.soft_rst = 1)
            ral_write(env.reg_model.CTRL, 32'h0000_0002);
            repeat (3) @(posedge vif.clk);
            ral_read(env.reg_model.CTRL, val);
            if (val[1] !== 1'b1) begin
                `uvm_error("SOFT_RST", $sformatf("Expected CTRL.soft_rst==1, got 0x%08h", val))
            end
            ral_read(env.reg_model.STATUS, val);
            if (val[2:0] !== 3'b100) begin
                `uvm_error("SOFT_RST", $sformatf("Expected STATUS==0x4 during soft reset, got 0x%08h", val))
            end

            // Deassert SOFT_RESET (CTRL.soft_rst = 0)
            ral_write(env.reg_model.CTRL, 32'h0000_0000);
            repeat (3) @(posedge vif.clk);
            ral_read(env.reg_model.CTRL, val);
            if (val[1] !== 1'b0) begin
                `uvm_error("SOFT_RST", $sformatf("Expected CTRL.soft_rst==0 after release, got 0x%08h", val))
            end
            ral_read(env.reg_model.STATUS, val);
            if (val[2:0] !== 3'b100) begin
                `uvm_error("SOFT_RST", $sformatf("Expected STATUS==0x4 after soft reset release, got 0x%08h", val))
            end
        endtask

        virtual task sweep_qp_and_gop_csrs();
            hevc_csr_rand_cfg cfg = hevc_csr_rand_cfg::type_id::create("cfg");

            // Sweep BASE_QP across low [0:21], mid [22:37], high [38:51]
            for (int bkt = 0; bkt < 3; bkt++) begin
                for (int iter = 0; iter < 3; iter++) begin
                    if (!cfg.randomize() with {
                        (bkt == 0) -> (base_qp inside {[0:21]});
                        (bkt == 1) -> (base_qp inside {[22:37]});
                        (bkt == 2) -> (base_qp inside {[38:51]});
                    }) begin
                        `uvm_fatal("CSR_SWEEP", "Randomization failed in QP sweep")
                    end
                    ral_write(env.reg_model.BASE_QP,        {26'd0, cfg.base_qp});
                    ral_write(env.reg_model.GOP_STRUCTURE,  {30'd0, cfg.gop_structure});
                    ral_write(env.reg_model.TARGET_BITRATE, {16'd0, cfg.target_bitrate});
                    ral_write(env.reg_model.TOTAL_FRAMES,   {16'd0, cfg.total_frames});

                    ral_mirror_check(env.reg_model.BASE_QP);
                    ral_mirror_check(env.reg_model.GOP_STRUCTURE);
                    ral_mirror_check(env.reg_model.TARGET_BITRATE);
                    ral_mirror_check(env.reg_model.TOTAL_FRAMES);
                end
            end

            // Explicitly cover all 3 legal GOP structures (0, 1, 2)
            for (int g = 0; g < 3; g++) begin
                if (!cfg.randomize() with { gop_structure == g; }) begin
                    `uvm_fatal("CSR_SWEEP", "Randomization failed in GOP sweep")
                end
                ral_write(env.reg_model.GOP_STRUCTURE,  {30'd0, cfg.gop_structure});
                ral_write(env.reg_model.BASE_QP,        {26'd0, cfg.base_qp});
                ral_write(env.reg_model.TARGET_BITRATE, {16'd0, cfg.target_bitrate});
                ral_write(env.reg_model.TOTAL_FRAMES,   {16'd0, cfg.total_frames});

                ral_mirror_check(env.reg_model.GOP_STRUCTURE);
                ral_mirror_check(env.reg_model.BASE_QP);
                ral_mirror_check(env.reg_model.TARGET_BITRATE);
                ral_mirror_check(env.reg_model.TOTAL_FRAMES);
            end
        endtask

        virtual function void report_phase(uvm_phase phase);
            uvm_report_server svr = uvm_report_server::get_server();
            super.report_phase(phase);
            if (svr.get_severity_count(UVM_FATAL) == 0 &&
                svr.get_severity_count(UVM_ERROR) == 0) begin
                `uvm_info("TEST_RESULT", $sformatf("*** TEST PASSED: %s ***", get_type_name()), UVM_NONE)
            end else begin
                `uvm_error("TEST_RESULT", $sformatf(
                    "*** TEST FAILED: %s (errors=%0d, fatals=%0d) ***",
                    get_type_name(),
                    svr.get_severity_count(UVM_ERROR),
                    svr.get_severity_count(UVM_FATAL)))
            end
        endfunction
    endclass

    //=========================================================================
    // Test 1: RAL Audit & CSR Sweep Test
    //=========================================================================
    class hevc_ral_audit_test extends hevc_axi_base_test;
        `uvm_component_utils(hevc_ral_audit_test)

        function new(string name = "hevc_ral_audit_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        virtual task run_phase(uvm_phase phase);
            uvm_reg_data_t       rd_val;
            uvm_reg_hw_reset_seq hw_rst_seq;
            uvm_reg_bit_bash_seq bit_bash_seq;

            phase.raise_objection(this);
            wait_reset_done();

            `uvm_info("RAL_AUDIT", "=== Step 1: Verify Initial Identity & Idle Status ===", UVM_LOW)
            ral_read(env.reg_model.MAGIC_ID, rd_val);
            if (rd_val !== 32'h48455643) begin
                `uvm_error("RAL_AUDIT", $sformatf("MAGIC_ID mismatch: 0x%08h", rd_val))
            end

            ral_read(env.reg_model.RESOLUTION, rd_val);
            if (rd_val !== 32'h00400040) begin
                `uvm_error("RAL_AUDIT", $sformatf("RESOLUTION mismatch: 0x%08h", rd_val))
            end

            ral_read(env.reg_model.STATUS, rd_val);
            if (rd_val[2:0] !== 3'b100) begin
                `uvm_error("RAL_AUDIT", $sformatf("Initial STATUS expected READY=1 BUSY=0 DONE=0 (0x4), got 0x%08h", rd_val))
            end

            ral_read(env.reg_model.VBV_FULLNESS, rd_val);

            `uvm_info("RAL_AUDIT", "=== Step 2: Run UVM Built-in uvm_reg_hw_reset_seq ===", UVM_LOW)
            hw_rst_seq = uvm_reg_hw_reset_seq::type_id::create("hw_rst_seq");
            hw_rst_seq.model = env.reg_model;
            hw_rst_seq.start(null);

            `uvm_info("RAL_AUDIT", "=== Step 3: Run UVM Built-in uvm_reg_bit_bash_seq ===", UVM_LOW)
            bit_bash_seq = uvm_reg_bit_bash_seq::type_id::create("bit_bash_seq");
            bit_bash_seq.model = env.reg_model;
            bit_bash_seq.start(null);

            `uvm_info("RAL_AUDIT", "=== Step 4: Verify Soft Reset Assertion & Deassertion ===", UVM_LOW)
            verify_soft_reset();

            `uvm_info("RAL_AUDIT", "=== Step 5: Constrained-Random QP/GOP/Bitrate/Frames Sweep ===", UVM_LOW)
            sweep_qp_and_gop_csrs();

            // Restore defaults cleanly
            ral_write(env.reg_model.TOTAL_FRAMES,   32'd1);
            ral_write(env.reg_model.BASE_QP,        32'd28);
            ral_write(env.reg_model.GOP_STRUCTURE,  32'd0);
            ral_write(env.reg_model.TARGET_BITRATE, 32'd5000);
            ral_write(env.reg_model.CTRL,           32'd0);

            repeat (10) @(posedge vif.clk);
            phase.drop_objection(this);
        endtask
    endclass

    //=========================================================================
    // Test 2: Full SoC UVM End-to-End Integration Test
    //=========================================================================
    class hevc_full_uvm_test extends hevc_axi_base_test;
        `uvm_component_utils(hevc_full_uvm_test)

        int unsigned bs_stall_prob   = 25;
        int unsigned force_hdr_stall = 0;

        function new(string name = "hevc_full_uvm_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            int plusarg_ok;
            plusarg_ok = $value$plusargs("BS_STALL_PROB=%d", bs_stall_prob);
            plusarg_ok = $value$plusargs("BS_FORCE_HDR_STALL=%d", force_hdr_stall);
            // Gate initial header stall to 0 unless +BS_FORCE_HDR_STALL=1 is given
            // (RTL nal_writer/slice_controller drops parameter-set nal_end under stall).
            uvm_config_db #(int unsigned)::set(this, "env.axis_bs_agt*", "stall_prob",
                                               (force_hdr_stall != 0) ? bs_stall_prob : 0);
            uvm_config_db #(int unsigned)::set(this, "env.axi_mem_agt*", "min_ready_delay", 0);
            uvm_config_db #(int unsigned)::set(this, "env.axi_mem_agt*", "max_ready_delay", 2);
            uvm_config_db #(int unsigned)::set(this, "env.axi_mem_agt*", "min_resp_delay",  0);
            uvm_config_db #(int unsigned)::set(this, "env.axi_mem_agt*", "max_resp_delay",  2);
            super.build_phase(phase);
        endfunction

        virtual task run_phase(uvm_phase phase);
            uvm_reg_data_t              rd_val;
            axis_video_single_frame_seq vid_seq;
            int unsigned                irq_wait_cycles;
            int unsigned                drain_wait_cycles;

            phase.raise_objection(this);

            // Configure DRAM latency & initial bitstream stall (0 for headers unless forced)
            env.axis_bs_agt.set_stall_prob((force_hdr_stall != 0) ? bs_stall_prob : 0);
            env.axi_mem_agt.set_latency(0, 2, 0, 2);

            wait_reset_done();

            `uvm_info("FULL_UVM", "=== Step 1: CSR Identity, Sweep & Soft Reset Audit ===", UVM_LOW)
            ral_read(env.reg_model.MAGIC_ID, rd_val);
            if (rd_val !== 32'h48455643) begin
                `uvm_error("FULL_UVM", $sformatf("MAGIC_ID mismatch: 0x%08h", rd_val))
            end

            ral_read(env.reg_model.RESOLUTION, rd_val);
            if (rd_val !== 32'h00400040) begin
                `uvm_error("FULL_UVM", $sformatf("RESOLUTION mismatch: 0x%08h", rd_val))
            end

            ral_read(env.reg_model.STATUS, rd_val);
            if (rd_val[2:0] !== 3'b100) begin
                `uvm_error("FULL_UVM", $sformatf("Initial STATUS expected 0x4, got 0x%08h", rd_val))
            end

            // Cover QP buckets & GOP modes prior to starting encode
            sweep_qp_and_gop_csrs();
            verify_soft_reset();

            `uvm_info("FULL_UVM", "=== Step 2: Configure Encode Parameters via RAL ===", UVM_LOW)
            ral_write(env.reg_model.TOTAL_FRAMES,   32'd1);
            ral_write(env.reg_model.BASE_QP,        32'd28);
            ral_write(env.reg_model.GOP_STRUCTURE,  32'd0);
            ral_write(env.reg_model.TARGET_BITRATE, 32'd6000);

            ral_mirror_check(env.reg_model.TOTAL_FRAMES);
            ral_mirror_check(env.reg_model.BASE_QP);
            ral_mirror_check(env.reg_model.GOP_STRUCTURE);
            ral_mirror_check(env.reg_model.TARGET_BITRATE);

            // Dynamic bitstream backpressure gate: wait until 80 bytes (VPS/SPS/PPS + slice hdr)
            // have handshaked cleanly, then enable payload backpressure (default 25%).
            if (force_hdr_stall == 0 && bs_stall_prob > 0) begin
                fork
                    begin
                        int unsigned bs_bytes_accepted = 0;
                        while (bs_bytes_accepted < 80) begin
                            @(posedge vif.clk);
                            if (vif.rst_n === 1'b1 &&
                                vif.m_axis_bitstream_tvalid === 1'b1 &&
                                vif.m_axis_bitstream_tready === 1'b1) begin
                                bs_bytes_accepted++;
                            end
                        end
                        env.axis_bs_agt.set_stall_prob(bs_stall_prob);
                        `uvm_info("FULL_UVM", $sformatf(
                            "Dynamic BS backpressure enabled: stall_prob=%0d%% after %0d header bytes",
                            bs_stall_prob, bs_bytes_accepted), UVM_LOW)
                    end
                join_none
            end

            `uvm_info("FULL_UVM", "=== Step 3: Start Encoder (CTRL: START=1, IRQ_EN=1 -> 0x5) ===", UVM_LOW)
            ral_write(env.reg_model.CTRL, 32'h0000_0005);
            repeat (2) @(posedge vif.clk);

            ral_read(env.reg_model.STATUS, rd_val);
            if (rd_val[1] !== 1'b1) begin
                `uvm_error("FULL_UVM", $sformatf("Expected STATUS.BUSY==1 after START, got 0x%08h", rd_val))
            end else begin
                `uvm_info("FULL_UVM", $sformatf("Encoder BUSY verified (STATUS=0x%08h)", rd_val), UVM_LOW)
            end

            `uvm_info("FULL_UVM", "=== Step 4: Stream 1x 64x64 Frame (4096 pixels, bubble_prob=15) ===", UVM_LOW)
            vid_seq = axis_video_single_frame_seq::type_id::create("vid_seq");
            vid_seq.pattern     = VIDEO_PAT_GRADIENT;
            vid_seq.width       = 64;
            vid_seq.height      = 64;
            vid_seq.bubble_prob = 15;
            vid_seq.start(env.v_sqr.axis_video_sqr);

            `uvm_info("FULL_UVM", "=== Step 5: Wait for Completion IRQ & Verify DONE Status ===", UVM_LOW)
            irq_wait_cycles = 0;
            while (vif.irq !== 1'b1) begin
                @(posedge vif.clk);
                irq_wait_cycles++;
                if (irq_wait_cycles > 2000000) begin
                    `uvm_fatal("FULL_UVM", "Timed out waiting for vif.irq assertion")
                end
            end
            `uvm_info("FULL_UVM", $sformatf("Interrupt vif.irq==1 observed after %0d wait cycles", irq_wait_cycles), UVM_LOW)

            // Note: irq_status asserts on core_frame_done, ~4 cycles before gop_controller
            // drives core_encode_done -> reg_done=1 / reg_busy=0. Allow STATUS to settle.
            for (int st_poll = 0; st_poll < 16; st_poll++) begin
                ral_read(env.reg_model.STATUS, rd_val);
                if (rd_val[0] === 1'b1 && rd_val[1] === 1'b0) break;
                repeat (2) @(posedge vif.clk);
            end
            if (rd_val[0] !== 1'b1 || rd_val[1] !== 1'b0) begin
                `uvm_error("FULL_UVM", $sformatf("Expected STATUS DONE=1 BUSY=0, got 0x%08h", rd_val))
            end else begin
                `uvm_info("FULL_UVM", $sformatf("Completion STATUS verified (0x%08h: DONE=1, BUSY=0)", rd_val), UVM_LOW)
            end

            ral_read(env.reg_model.VBV_FULLNESS, rd_val);

            ral_read(env.reg_model.IRQ_STATUS, rd_val);
            if (rd_val[0] !== 1'b1) begin
                `uvm_error("FULL_UVM", $sformatf("Expected IRQ_STATUS==1, got 0x%08h", rd_val))
            end

            `uvm_info("FULL_UVM", "=== Step 6: Clear IRQ via W1C & Wait for TLAST/File Flush ===", UVM_LOW)
            ral_write(env.reg_model.IRQ_STATUS, 32'h0000_0001);
            repeat (2) @(posedge vif.clk);

            if (vif.irq !== 1'b0) begin
                `uvm_error("FULL_UVM", "vif.irq did not deassert after IRQ_STATUS W1C write")
            end
            ral_read(env.reg_model.IRQ_STATUS, rd_val);
            if (rd_val[0] !== 1'b0) begin
                `uvm_error("FULL_UVM", $sformatf("Expected IRQ_STATUS==0 after W1C, got 0x%08h", rd_val))
            end

            // Wait for 2-byte staging FIFO TLAST drain under backpressure + AXI4 DRAM B-responses
            drain_wait_cycles = 0;
            while (env.sb.bs_pkts_rcvd < 1 || vif.m_axis_bitstream_tvalid === 1'b1) begin
                @(posedge vif.clk);
                drain_wait_cycles++;
                if (drain_wait_cycles > 5000) begin
                    `uvm_error("FULL_UVM", "Timed out waiting for bitstream TLAST packet capture")
                    break;
                end
            end
            repeat (50) @(posedge vif.clk);

            phase.drop_objection(this);
        endtask
    endclass

endpackage
