`timescale 1ns / 1ps
//=============================================================================
// hevc_axi_vip_pkg.sv
// SoC AMBA VIP Package for hevc_encoder_axi_top:
//   1. axi_lite_agent      (AXI4-Lite Master Agent + Monitor)
//   2. axis_video_agent    (AXI4-Stream 32-bit YUV Video Master Agent)
//   3. axis_bitstream_agent(AXI4-Stream 8-bit Bitstream Reactive Slave Agent)
//   4. axi4_mem_agent      (AXI4 256-bit DRAM Reactive Slave Agent)
//=============================================================================

package hevc_axi_vip_pkg;

    import uvm_pkg::*;
    import hevc_ral_pkg::*;
    `include "uvm_macros.svh"

    //=========================================================================
    // AGENT 1: AXI4-Lite Master VIP
    //=========================================================================
    class axi_lite_sequencer extends uvm_sequencer #(axi_lite_txn);
        `uvm_component_utils(axi_lite_sequencer)

        function new(string name = "axi_lite_sequencer", uvm_component parent = null);
            super.new(name, parent);
        endfunction
    endclass

    class axi_lite_driver extends uvm_driver #(axi_lite_txn);
        `uvm_component_utils(axi_lite_driver)

        virtual hevc_axi_if vif;

        function new(string name = "axi_lite_driver", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual hevc_axi_if)::get(this, "", "vif", vif)) begin
                `uvm_fatal("NOVIF", "axi_lite_driver could not find virtual interface 'vif'")
            end
        endfunction

        virtual task reset_signals();
            vif.s_axi_lite_awaddr  <= 12'd0;
            vif.s_axi_lite_awprot  <= 3'd0;
            vif.s_axi_lite_awvalid <= 1'b0;
            vif.s_axi_lite_wdata   <= 32'd0;
            vif.s_axi_lite_wstrb   <= 4'd0;
            vif.s_axi_lite_wvalid  <= 1'b0;
            vif.s_axi_lite_bready  <= 1'b0;
            vif.s_axi_lite_araddr  <= 12'd0;
            vif.s_axi_lite_arprot  <= 3'd0;
            vif.s_axi_lite_arvalid <= 1'b0;
            vif.s_axi_lite_rready  <= 1'b0;
        endtask

        virtual task drive_write(axi_lite_txn req);
            bit aw_done = 1'b0;
            bit w_done  = 1'b0;
            bit b_done  = 1'b0;

            @(posedge vif.clk);
            if (!vif.rst_n) begin
                reset_signals();
                req.resp = 2'b10;
                return;
            end

            vif.s_axi_lite_awaddr  <= req.addr;
            vif.s_axi_lite_awprot  <= 3'b000;
            vif.s_axi_lite_awvalid <= 1'b1;
            vif.s_axi_lite_wdata   <= req.data;
            vif.s_axi_lite_wstrb   <= req.wstrb;
            vif.s_axi_lite_wvalid  <= 1'b1;
            vif.s_axi_lite_bready  <= 1'b1;

            while (!(aw_done && w_done && b_done)) begin
                @(posedge vif.clk);
                if (!vif.rst_n) begin
                    reset_signals();
                    req.resp = 2'b10;
                    return;
                end
                if (!aw_done && vif.s_axi_lite_awvalid && vif.s_axi_lite_awready) begin
                    aw_done = 1'b1;
                    vif.s_axi_lite_awvalid <= 1'b0;
                end
                if (!w_done && vif.s_axi_lite_wvalid && vif.s_axi_lite_wready) begin
                    w_done = 1'b1;
                    vif.s_axi_lite_wvalid <= 1'b0;
                end
                if (aw_done && w_done && vif.s_axi_lite_bvalid && vif.s_axi_lite_bready) begin
                    req.resp = vif.s_axi_lite_bresp;
                    b_done   = 1'b1;
                    vif.s_axi_lite_bready <= 1'b0;
                end
            end
        endtask

        virtual task drive_read(axi_lite_txn req);
            bit ar_done = 1'b0;
            bit r_done  = 1'b0;

            @(posedge vif.clk);
            if (!vif.rst_n) begin
                reset_signals();
                req.resp = 2'b10;
                return;
            end

            vif.s_axi_lite_araddr  <= req.addr;
            vif.s_axi_lite_arprot  <= 3'b000;
            vif.s_axi_lite_arvalid <= 1'b1;
            vif.s_axi_lite_rready  <= 1'b1;

            while (!(ar_done && r_done)) begin
                @(posedge vif.clk);
                if (!vif.rst_n) begin
                    reset_signals();
                    req.resp = 2'b10;
                    return;
                end
                if (!ar_done && vif.s_axi_lite_arvalid && vif.s_axi_lite_arready) begin
                    ar_done = 1'b1;
                    vif.s_axi_lite_arvalid <= 1'b0;
                end
                if (ar_done && vif.s_axi_lite_rvalid && vif.s_axi_lite_rready) begin
                    req.data = vif.s_axi_lite_rdata;
                    req.resp = vif.s_axi_lite_rresp;
                    r_done   = 1'b1;
                    vif.s_axi_lite_rready <= 1'b0;
                end
            end
        endtask

        virtual task run_phase(uvm_phase phase);
            reset_signals();
            wait (vif.rst_n === 1'b1);
            @(posedge vif.clk);

            forever begin
                axi_lite_txn req;
                seq_item_port.get_next_item(req);
                if (vif.rst_n !== 1'b1) begin
                    reset_signals();
                    wait (vif.rst_n === 1'b1);
                end
                if (req.is_write)
                    drive_write(req);
                else
                    drive_read(req);
                seq_item_port.item_done();
            end
        endtask
    endclass

    class axi_lite_monitor extends uvm_monitor;
        `uvm_component_utils(axi_lite_monitor)

        virtual hevc_axi_if vif;
        uvm_analysis_port #(axi_lite_txn) ap;

        typedef struct {
            bit [31:0] data;
            bit [3:0]  wstrb;
        } lite_w_beat_t;

        protected bit [11:0]    aw_q[$];
        protected lite_w_beat_t w_q[$];
        protected bit [11:0]    ar_q[$];

        function new(string name = "axi_lite_monitor", uvm_component parent = null);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual hevc_axi_if)::get(this, "", "vif", vif)) begin
                `uvm_fatal("NOVIF", "axi_lite_monitor could not find virtual interface 'vif'")
            end
        endfunction

        virtual task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n !== 1'b1) begin
                    aw_q.delete();
                    w_q.delete();
                    ar_q.delete();
                    continue;
                end

                // Capture address/data channels BEFORE checking response completion
                // because RTL can assert ready and valid responses on the same cycle.
                if (vif.s_axi_lite_awvalid && vif.s_axi_lite_awready) begin
                    aw_q.push_back(vif.s_axi_lite_awaddr);
                end

                if (vif.s_axi_lite_wvalid && vif.s_axi_lite_wready) begin
                    lite_w_beat_t wb;
                    wb.data  = vif.s_axi_lite_wdata;
                    wb.wstrb = vif.s_axi_lite_wstrb;
                    w_q.push_back(wb);
                end

                if (vif.s_axi_lite_bvalid && vif.s_axi_lite_bready) begin
                    if (aw_q.size() > 0 && w_q.size() > 0) begin
                        axi_lite_txn tr = axi_lite_txn::type_id::create("tr");
                        lite_w_beat_t wb = w_q.pop_front();
                        tr.is_write = 1'b1;
                        tr.addr     = aw_q.pop_front();
                        tr.data     = wb.data;
                        tr.wstrb    = wb.wstrb;
                        tr.resp     = vif.s_axi_lite_bresp;
                        ap.write(tr);
                    end else begin
                        `uvm_warning("AXI_LITE_MON", "Observed bvalid && bready without matching AW/W")
                    end
                end

                if (vif.s_axi_lite_arvalid && vif.s_axi_lite_arready) begin
                    ar_q.push_back(vif.s_axi_lite_araddr);
                end

                if (vif.s_axi_lite_rvalid && vif.s_axi_lite_rready) begin
                    if (ar_q.size() > 0) begin
                        axi_lite_txn tr = axi_lite_txn::type_id::create("tr");
                        tr.is_write = 1'b0;
                        tr.addr     = ar_q.pop_front();
                        tr.data     = vif.s_axi_lite_rdata;
                        tr.wstrb    = 4'h0;
                        tr.resp     = vif.s_axi_lite_rresp;
                        ap.write(tr);
                    end else begin
                        `uvm_warning("AXI_LITE_MON", "Observed rvalid && rready without matching AR")
                    end
                end
            end
        endtask
    endclass

    class axi_lite_agent extends uvm_agent;
        `uvm_component_utils(axi_lite_agent)

        axi_lite_sequencer sqr;
        axi_lite_driver    drv;
        axi_lite_monitor   mon;
        uvm_analysis_port #(axi_lite_txn) ap;

        function new(string name = "axi_lite_agent", uvm_component parent = null);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            virtual hevc_axi_if vif_tmp;
            super.build_phase(phase);
            if (uvm_config_db #(virtual hevc_axi_if)::get(this, "", "vif", vif_tmp)) begin
                uvm_config_db #(virtual hevc_axi_if)::set(this, "*", "vif", vif_tmp);
            end
            mon = axi_lite_monitor::type_id::create("mon", this);
            if (get_is_active() == UVM_ACTIVE) begin
                sqr = axi_lite_sequencer::type_id::create("sqr", this);
                drv = axi_lite_driver::type_id::create("drv", this);
            end
        endfunction

        virtual function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            mon.ap.connect(ap);
            if (get_is_active() == UVM_ACTIVE) begin
                drv.seq_item_port.connect(sqr.seq_item_export);
            end
        endfunction
    endclass

    //=========================================================================
    // AGENT 2: AXI4-Stream Video Input Master VIP
    //=========================================================================
    typedef enum int {
        VIDEO_PAT_CONSTANT = 0,
        VIDEO_PAT_GRADIENT = 1,
        VIDEO_PAT_CHECKER  = 2,
        VIDEO_PAT_RANDOM   = 3
    } video_pattern_e;

    class axis_video_frame_item extends uvm_sequence_item;
        rand video_pattern_e pattern;
        rand int unsigned    width;
        rand int unsigned    height;
        rand bit [9:0]       const_y;
        rand bit [9:0]       const_u;
        rand bit [9:0]       const_v;
        rand int unsigned    bubble_prob; // 0..100 percent idle cycle probability

        bit [9:0]  y_pixels[$];
        bit [9:0]  u_pixels[$];
        bit [9:0]  v_pixels[$];
        bit [31:0] tdata_q[$];

        constraint c_dims_default   { width == 64; height == 64; }
        constraint c_bubble_default { bubble_prob inside {[0:50]}; }

        `uvm_object_utils_begin(axis_video_frame_item)
            `uvm_field_enum(video_pattern_e, pattern, UVM_ALL_ON)
            `uvm_field_int(width,       UVM_ALL_ON)
            `uvm_field_int(height,      UVM_ALL_ON)
            `uvm_field_int(const_y,     UVM_ALL_ON)
            `uvm_field_int(const_u,     UVM_ALL_ON)
            `uvm_field_int(const_v,     UVM_ALL_ON)
            `uvm_field_int(bubble_prob, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "axis_video_frame_item");
            super.new(name);
            pattern     = VIDEO_PAT_CONSTANT;
            width       = 64;
            height      = 64;
            const_y     = 10'd512;
            const_u     = 10'd512;
            const_v     = 10'd512;
            bubble_prob = 0;
        endfunction

        virtual function void build_pixels();
            int unsigned total_px = width * height;
            y_pixels.delete();
            u_pixels.delete();
            v_pixels.delete();
            tdata_q.delete();

            for (int unsigned py = 0; py < height; py++) begin
                for (int unsigned px = 0; px < width; px++) begin
                    bit [9:0] y_val, u_val, v_val;
                    case (pattern)
                        VIDEO_PAT_CONSTANT: begin
                            y_val = const_y;
                            u_val = const_u;
                            v_val = const_v;
                        end
                        VIDEO_PAT_GRADIENT: begin
                            y_val = 10'((px * 8 + py * 8) & 10'h3FF);
                            u_val = 10'((10'd256 + px * 4) & 10'h3FF);
                            v_val = 10'((10'd256 + py * 4) & 10'h3FF);
                        end
                        VIDEO_PAT_CHECKER: begin
                            bit chk = ((px >> 3) & 1) ^ ((py >> 3) & 1);
                            y_val = chk ? 10'd800 : 10'd200;
                            u_val = chk ? 10'd640 : 10'd384;
                            v_val = chk ? 10'd384 : 10'd640;
                        end
                        default: begin // VIDEO_PAT_RANDOM
                            y_val = 10'($urandom_range(0, 1023));
                            u_val = 10'($urandom_range(0, 1023));
                            v_val = 10'($urandom_range(0, 1023));
                        end
                    endcase
                    y_pixels.push_back(y_val);
                    u_pixels.push_back(u_val);
                    v_pixels.push_back(v_val);
                    tdata_q.push_back({2'b00, v_val, u_val, y_val});
                end
            end
            if (tdata_q.size() != total_px) begin
                `uvm_error("VID_ITEM", $sformatf("Pixel count mismatch: %0d vs %0d", tdata_q.size(), total_px))
            end
        endfunction

        function void post_randomize();
            build_pixels();
        endfunction

        virtual function void do_copy(uvm_object rhs);
            axis_video_frame_item rhs_item;
            super.do_copy(rhs);
            if (!$cast(rhs_item, rhs)) return;
            y_pixels = rhs_item.y_pixels;
            u_pixels = rhs_item.u_pixels;
            v_pixels = rhs_item.v_pixels;
            tdata_q  = rhs_item.tdata_q;
        endfunction

        virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
            axis_video_frame_item rhs_item;
            if (!super.do_compare(rhs, comparer)) return 1'b0;
            if (!$cast(rhs_item, rhs)) return 1'b0;
            if (tdata_q.size() != rhs_item.tdata_q.size()) return 1'b0;
            foreach (tdata_q[i]) begin
                if (tdata_q[i] !== rhs_item.tdata_q[i]) return 1'b0;
            end
            return 1'b1;
        endfunction

        virtual function string convert2string();
            return $sformatf("pattern=%s %0dx%0d pixels=%0d bubble_prob=%0d%%",
                             pattern.name(), width, height, tdata_q.size(), bubble_prob);
        endfunction
    endclass

    class axis_video_sequencer extends uvm_sequencer #(axis_video_frame_item);
        `uvm_component_utils(axis_video_sequencer)

        function new(string name = "axis_video_sequencer", uvm_component parent = null);
            super.new(name, parent);
        endfunction
    endclass

    class axis_video_driver extends uvm_driver #(axis_video_frame_item);
        `uvm_component_utils(axis_video_driver)

        virtual hevc_axi_if vif;

        function new(string name = "axis_video_driver", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual hevc_axi_if)::get(this, "", "vif", vif)) begin
                `uvm_fatal("NOVIF", "axis_video_driver could not find virtual interface 'vif'")
            end
        endfunction

        virtual task reset_signals();
            vif.s_axis_video_tdata  <= 32'd0;
            vif.s_axis_video_tvalid <= 1'b0;
            vif.s_axis_video_tlast  <= 1'b0;
            vif.s_axis_video_tuser  <= 1'b0;
        endtask

        virtual task drive_frame(axis_video_frame_item req);
            int unsigned total_px;

            if (req.tdata_q.size() == 0) begin
                if (req.y_pixels.size() > 0 &&
                    req.u_pixels.size() == req.y_pixels.size() &&
                    req.v_pixels.size() == req.y_pixels.size()) begin
                    for (int i = 0; i < req.y_pixels.size(); i++) begin
                        req.tdata_q.push_back({2'b00, req.v_pixels[i], req.u_pixels[i], req.y_pixels[i]});
                    end
                end else begin
                    req.build_pixels();
                end
            end

            total_px = req.tdata_q.size();
            @(posedge vif.clk);
            if (!vif.rst_n) begin
                reset_signals();
                return;
            end

            for (int unsigned i = 0; i < total_px; i++) begin
                int unsigned bubble_guard = 0;
                // Optional idle bubbles strictly BEFORE asserting tvalid
                while ((req.bubble_prob > 0) &&
                       ($urandom_range(0, 99) < req.bubble_prob) &&
                       (bubble_guard < 16)) begin
                    vif.s_axis_video_tvalid <= 1'b0;
                    vif.s_axis_video_tlast  <= 1'b0;
                    vif.s_axis_video_tuser  <= 1'b0;
                    bubble_guard++;
                    @(posedge vif.clk);
                    if (!vif.rst_n) begin
                        reset_signals();
                        return;
                    end
                end

                vif.s_axis_video_tvalid <= 1'b1;
                vif.s_axis_video_tdata  <= req.tdata_q[i];
                vif.s_axis_video_tlast  <= (i == (total_px - 1));
                vif.s_axis_video_tuser  <= (i == 0);

                // Hold signals unchanged until tvalid && tready handshake occurs
                do begin
                    @(posedge vif.clk);
                    if (!vif.rst_n) begin
                        reset_signals();
                        return;
                    end
                end while (!vif.s_axis_video_tready);
            end

            vif.s_axis_video_tvalid <= 1'b0;
            vif.s_axis_video_tlast  <= 1'b0;
            vif.s_axis_video_tuser  <= 1'b0;
        endtask

        virtual task run_phase(uvm_phase phase);
            reset_signals();
            wait (vif.rst_n === 1'b1);
            @(posedge vif.clk);

            forever begin
                axis_video_frame_item req;
                seq_item_port.get_next_item(req);
                if (vif.rst_n !== 1'b1) begin
                    reset_signals();
                    wait (vif.rst_n === 1'b1);
                end
                drive_frame(req);
                seq_item_port.item_done();
            end
        endtask
    endclass

    class axis_video_monitor extends uvm_monitor;
        `uvm_component_utils(axis_video_monitor)

        virtual hevc_axi_if vif;
        uvm_analysis_port #(axis_video_frame_item) ap;

        protected axis_video_frame_item cur_frame;

        function new(string name = "axis_video_monitor", uvm_component parent = null);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual hevc_axi_if)::get(this, "", "vif", vif)) begin
                `uvm_fatal("NOVIF", "axis_video_monitor could not find virtual interface 'vif'")
            end
        endfunction

        virtual task run_phase(uvm_phase phase);
            cur_frame = null;
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n !== 1'b1) begin
                    cur_frame = null;
                    continue;
                end

                if (vif.s_axis_video_tvalid && vif.s_axis_video_tready) begin
                    if (vif.s_axis_video_tuser && (cur_frame != null) && (cur_frame.tdata_q.size() > 0)) begin
                        `uvm_warning("VID_MON", "Observed tuser SOF before previous frame saw tlast; resetting frame buffer")
                        cur_frame = null;
                    end

                    if (cur_frame == null) begin
                        cur_frame = axis_video_frame_item::type_id::create("cur_frame");
                    end

                    cur_frame.tdata_q.push_back(vif.s_axis_video_tdata);
                    cur_frame.y_pixels.push_back(vif.s_axis_video_tdata[9:0]);
                    cur_frame.u_pixels.push_back(vif.s_axis_video_tdata[19:10]);
                    cur_frame.v_pixels.push_back(vif.s_axis_video_tdata[29:20]);

                    if (vif.s_axis_video_tlast) begin
                        int unsigned n_px = cur_frame.tdata_q.size();
                        if (n_px == 4096) begin
                            cur_frame.width  = 64;
                            cur_frame.height = 64;
                        end else if (n_px == 16384) begin
                            cur_frame.width  = 128;
                            cur_frame.height = 128;
                        end else begin
                            cur_frame.width  = n_px;
                            cur_frame.height = 1;
                        end
                        ap.write(cur_frame);
                        cur_frame = null;
                    end
                end
            end
        endtask
    endclass

    class axis_video_agent extends uvm_agent;
        `uvm_component_utils(axis_video_agent)

        axis_video_sequencer sqr;
        axis_video_driver    drv;
        axis_video_monitor   mon;
        uvm_analysis_port #(axis_video_frame_item) ap;

        function new(string name = "axis_video_agent", uvm_component parent = null);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            virtual hevc_axi_if vif_tmp;
            super.build_phase(phase);
            if (uvm_config_db #(virtual hevc_axi_if)::get(this, "", "vif", vif_tmp)) begin
                uvm_config_db #(virtual hevc_axi_if)::set(this, "*", "vif", vif_tmp);
            end
            mon = axis_video_monitor::type_id::create("mon", this);
            if (get_is_active() == UVM_ACTIVE) begin
                sqr = axis_video_sequencer::type_id::create("sqr", this);
                drv = axis_video_driver::type_id::create("drv", this);
            end
        endfunction

        virtual function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            mon.ap.connect(ap);
            if (get_is_active() == UVM_ACTIVE) begin
                drv.seq_item_port.connect(sqr.seq_item_export);
            end
        endfunction
    endclass

    //=========================================================================
    // AGENT 3: AXI4-Stream Bitstream Output Reactive Slave VIP
    //=========================================================================
    class axis_bitstream_pkt extends uvm_sequence_item;
        byte unsigned data[$];
        int unsigned  tlast_cnt;
        int unsigned  pkt_id;

        `uvm_object_utils_begin(axis_bitstream_pkt)
            `uvm_field_int(tlast_cnt, UVM_ALL_ON)
            `uvm_field_int(pkt_id,    UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "axis_bitstream_pkt");
            super.new(name);
            tlast_cnt = 0;
            pkt_id    = 0;
        endfunction

        virtual function void do_copy(uvm_object rhs);
            axis_bitstream_pkt rhs_pkt;
            super.do_copy(rhs);
            if (!$cast(rhs_pkt, rhs)) return;
            data = rhs_pkt.data;
        endfunction

        virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
            axis_bitstream_pkt rhs_pkt;
            if (!super.do_compare(rhs, comparer)) return 1'b0;
            if (!$cast(rhs_pkt, rhs)) return 1'b0;
            if (data.size() != rhs_pkt.data.size()) return 1'b0;
            foreach (data[i]) begin
                if (data[i] !== rhs_pkt.data[i]) return 1'b0;
            end
            return 1'b1;
        endfunction

        virtual function string convert2string();
            return $sformatf("pkt_id=%0d bytes=%0d tlast_cnt=%0d", pkt_id, data.size(), tlast_cnt);
        endfunction
    endclass

    class axis_bitstream_slave_driver extends uvm_driver #(axis_bitstream_pkt);
        `uvm_component_utils(axis_bitstream_slave_driver)

        virtual hevc_axi_if vif;
        int unsigned stall_prob = 0; // 0..100 percent probability of tready=0

        function new(string name = "axis_bitstream_slave_driver", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            int          signed_prob;
            int unsigned unsigned_prob;
            super.build_phase(phase);
            if (!uvm_config_db #(virtual hevc_axi_if)::get(this, "", "vif", vif)) begin
                `uvm_fatal("NOVIF", "axis_bitstream_slave_driver could not find virtual interface 'vif'")
            end
            if (uvm_config_db #(int unsigned)::get(this, "", "stall_prob", unsigned_prob)) begin
                stall_prob = unsigned_prob;
            end else if (uvm_config_db #(int)::get(this, "", "stall_prob", signed_prob)) begin
                stall_prob = (signed_prob < 0) ? 0 : unsigned'(signed_prob);
            end
        endfunction

        virtual task run_phase(uvm_phase phase);
            vif.m_axis_bitstream_tready <= 1'b0;
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n !== 1'b1) begin
                    vif.m_axis_bitstream_tready <= 1'b0;
                end else if (stall_prob == 0) begin
                    vif.m_axis_bitstream_tready <= 1'b1;
                end else begin
                    vif.m_axis_bitstream_tready <= ($urandom_range(0, 99) >= stall_prob);
                end
            end
        endtask
    endclass

    class axis_bitstream_monitor extends uvm_monitor;
        `uvm_component_utils(axis_bitstream_monitor)

        virtual hevc_axi_if vif;
        uvm_analysis_port #(axis_bitstream_pkt) ap;

        protected byte unsigned buf_q[$];
        protected int unsigned  frame_seq_id;

        function new(string name = "axis_bitstream_monitor", uvm_component parent = null);
            super.new(name, parent);
            ap           = new("ap", this);
            frame_seq_id = 0;
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual hevc_axi_if)::get(this, "", "vif", vif)) begin
                `uvm_fatal("NOVIF", "axis_bitstream_monitor could not find virtual interface 'vif'")
            end
        endfunction

        virtual task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n !== 1'b1) begin
                    buf_q.delete();
                    continue;
                end

                if (vif.m_axis_bitstream_tvalid && vif.m_axis_bitstream_tready) begin
                    buf_q.push_back(vif.m_axis_bitstream_tdata);
                    if (vif.m_axis_bitstream_tlast) begin
                        axis_bitstream_pkt pkt = axis_bitstream_pkt::type_id::create("pkt");
                        pkt.data      = buf_q;
                        pkt.tlast_cnt = 1;
                        pkt.pkt_id    = frame_seq_id;
                        frame_seq_id++;
                        ap.write(pkt);
                        buf_q.delete();
                    end
                end
            end
        endtask
    endclass

    class axis_bitstream_agent extends uvm_agent;
        `uvm_component_utils(axis_bitstream_agent)

        axis_bitstream_slave_driver drv;
        axis_bitstream_monitor      mon;
        uvm_analysis_port #(axis_bitstream_pkt) ap;

        function new(string name = "axis_bitstream_agent", uvm_component parent = null);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            virtual hevc_axi_if vif_tmp;
            int          signed_prob;
            int unsigned unsigned_prob;
            super.build_phase(phase);
            if (uvm_config_db #(virtual hevc_axi_if)::get(this, "", "vif", vif_tmp)) begin
                uvm_config_db #(virtual hevc_axi_if)::set(this, "*", "vif", vif_tmp);
            end
            mon = axis_bitstream_monitor::type_id::create("mon", this);
            if (get_is_active() == UVM_ACTIVE) begin
                drv = axis_bitstream_slave_driver::type_id::create("drv", this);
                if (uvm_config_db #(int unsigned)::get(this, "", "stall_prob", unsigned_prob)) begin
                    drv.stall_prob = unsigned_prob;
                end else if (uvm_config_db #(int)::get(this, "", "stall_prob", signed_prob)) begin
                    drv.stall_prob = (signed_prob < 0) ? 0 : unsigned'(signed_prob);
                end
            end
        endfunction

        virtual function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            mon.ap.connect(ap);
        endfunction

        virtual function void set_stall_prob(int unsigned p);
            if (drv != null) drv.stall_prob = p;
        endfunction
    endclass

    //=========================================================================
    // AGENT 4: AXI4 256-bit Memory Reactive Slave VIP
    //=========================================================================
    class axi4_mem_txn extends uvm_sequence_item;
        bit         is_write;
        bit [0:0]   id;
        bit [32:0]  addr;
        bit [7:0]   len;
        bit [2:0]   size;
        bit [1:0]   burst;
        bit [255:0] data[$];
        bit [31:0]  wstrb[$];
        bit [1:0]   resp;

        `uvm_object_utils_begin(axi4_mem_txn)
            `uvm_field_int(is_write, UVM_ALL_ON)
            `uvm_field_int(id,       UVM_ALL_ON)
            `uvm_field_int(addr,     UVM_ALL_ON)
            `uvm_field_int(len,      UVM_ALL_ON)
            `uvm_field_int(size,     UVM_ALL_ON)
            `uvm_field_int(burst,    UVM_ALL_ON)
            `uvm_field_int(resp,     UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "axi4_mem_txn");
            super.new(name);
            size  = 3'b101;
            burst = 2'b01;
            resp  = 2'b00;
        endfunction

        virtual function void do_copy(uvm_object rhs);
            axi4_mem_txn rhs_t;
            super.do_copy(rhs);
            if (!$cast(rhs_t, rhs)) return;
            data  = rhs_t.data;
            wstrb = rhs_t.wstrb;
        endfunction

        virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
            axi4_mem_txn rhs_t;
            if (!super.do_compare(rhs, comparer)) return 1'b0;
            if (!$cast(rhs_t, rhs)) return 1'b0;
            if (data.size() != rhs_t.data.size()) return 1'b0;
            foreach (data[i]) begin
                if (data[i] !== rhs_t.data[i]) return 1'b0;
            end
            if (is_write) begin
                if (wstrb.size() != rhs_t.wstrb.size()) return 1'b0;
                foreach (wstrb[i]) begin
                    if (wstrb[i] !== rhs_t.wstrb[i]) return 1'b0;
                end
            end
            return 1'b1;
        endfunction

        virtual function string convert2string();
            return $sformatf("%s id=%0d addr=0x%09h len=%0d size=%0d burst=%0d beats=%0d resp=%0b",
                             is_write ? "WR" : "RD", id, addr, len, size, burst, data.size(), resp);
        endfunction
    endclass

    class axi4_mem_slave_driver extends uvm_driver #(axi4_mem_txn);
        `uvm_component_utils(axi4_mem_slave_driver)

        virtual hevc_axi_if vif;

        // Associative DRAM storage keyed by 32-byte aligned 33-bit word address
        bit [255:0] dram [bit[32:0]];

        // Configurable 0..2 cycle ready/response latency defaults
        int unsigned min_ready_delay = 0;
        int unsigned max_ready_delay = 2;
        int unsigned min_resp_delay  = 0;
        int unsigned max_resp_delay  = 2;

        typedef struct {
            bit [0:0]    id;
            bit [32:0]   addr;
            bit [7:0]    len;
            bit [2:0]    size;
            bit [1:0]    burst;
            int unsigned wait_cnt;
        } axi_req_t;

        typedef struct {
            bit [255:0] wdata;
            bit [31:0]  wstrb;
            bit         wlast;
        } axi_w_beat_t;

        typedef struct {
            bit [0:0]    id;
            int unsigned wait_cnt;
        } axi_b_pend_t;

        function new(string name = "axi4_mem_slave_driver", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            int unsigned uval;
            super.build_phase(phase);
            if (!uvm_config_db #(virtual hevc_axi_if)::get(this, "", "vif", vif)) begin
                `uvm_fatal("NOVIF", "axi4_mem_slave_driver could not find virtual interface 'vif'")
            end
            if (uvm_config_db #(int unsigned)::get(this, "", "min_ready_delay", uval)) min_ready_delay = uval;
            if (uvm_config_db #(int unsigned)::get(this, "", "max_ready_delay", uval)) max_ready_delay = uval;
            if (uvm_config_db #(int unsigned)::get(this, "", "min_resp_delay",  uval)) min_resp_delay  = uval;
            if (uvm_config_db #(int unsigned)::get(this, "", "max_resp_delay",  uval)) max_resp_delay  = uval;
        endfunction

        virtual function void set_latency(
            int unsigned min_rdy,
            int unsigned max_rdy,
            int unsigned min_rsp,
            int unsigned max_rsp
        );
            min_ready_delay = min_rdy;
            max_ready_delay = (max_rdy < min_rdy) ? min_rdy : max_rdy;
            min_resp_delay  = min_rsp;
            max_resp_delay  = (max_rsp < min_rsp) ? min_rsp : max_rsp;
        endfunction

        virtual function void clear_mem();
            dram.delete();
        endfunction

        virtual function bit [255:0] read_word(bit [32:0] addr);
            bit [32:0] aligned_addr = addr & ~33'h1F;
            return dram.exists(aligned_addr) ? dram[aligned_addr] : 256'd0;
        endfunction

        virtual function void write_word(
            bit [32:0]  addr,
            bit [255:0] data,
            bit [31:0]  strb = 32'hFFFF_FFFF
        );
            bit [32:0]  aligned_addr = addr & ~33'h1F;
            bit [255:0] cur_word     = read_word(aligned_addr);
            for (int b = 0; b < 32; b++) begin
                if (strb[b]) begin
                    cur_word[b*8 +: 8] = data[b*8 +: 8];
                end
            end
            dram[aligned_addr] = cur_word;
        endfunction

        static function bit [32:0] calc_beat_addr(
            bit [32:0]   base_addr,
            bit [7:0]    len,
            bit [2:0]    size,
            bit [1:0]    burst,
            int unsigned beat_idx
        );
            bit [32:0] step = 33'd1 << size;
            bit [32:0] aligned_base = base_addr & ~(step - 33'd1);
            if (burst == 2'b00) begin
                // FIXED
                return base_addr;
            end else if (burst == 2'b10) begin
                // WRAP
                bit [32:0] wrap_size = (33'(len) + 33'd1) * step;
                bit [32:0] wrap_mask = wrap_size - 33'd1;
                bit [32:0] wrap_base = aligned_base & ~wrap_mask;
                return wrap_base | ((aligned_base + (33'(beat_idx) * step)) & wrap_mask);
            end else begin
                // INCR (2'b01)
                if (beat_idx == 0) return base_addr;
                return aligned_base + (33'(beat_idx) * step);
            end
        endfunction

        virtual task run_write_channel();
            axi_req_t    aw_q[$];
            axi_w_beat_t w_q[$];
            axi_b_pend_t b_pend_q[$];

            int unsigned aw_delay = 0;
            int unsigned w_delay  = 0;
            bit          wr_active = 1'b0;
            axi_req_t    wr_cur;
            int unsigned wr_beat_idx = 0;
            bit          b_in_flight = 1'b0;

            vif.m_axi_mem_awready <= 1'b0;
            vif.m_axi_mem_wready  <= 1'b0;
            vif.m_axi_mem_bvalid  <= 1'b0;
            vif.m_axi_mem_bresp   <= 2'b00;
            vif.m_axi_mem_bid     <= 1'b0;

            forever begin
                @(posedge vif.clk);
                if (vif.rst_n !== 1'b1) begin
                    aw_q.delete();
                    w_q.delete();
                    b_pend_q.delete();
                    wr_active   = 1'b0;
                    wr_beat_idx = 0;
                    b_in_flight = 1'b0;
                    aw_delay    = $urandom_range(min_ready_delay, max_ready_delay);
                    w_delay     = $urandom_range(min_ready_delay, max_ready_delay);
                    vif.m_axi_mem_awready <= 1'b0;
                    vif.m_axi_mem_wready  <= 1'b0;
                    vif.m_axi_mem_bvalid  <= 1'b0;
                    vif.m_axi_mem_bresp   <= 2'b00;
                    vif.m_axi_mem_bid     <= 1'b0;
                    continue;
                end

                // 1. Sample AW, W, B handshakes
                if (vif.m_axi_mem_awvalid && vif.m_axi_mem_awready) begin
                    axi_req_t req;
                    req.id       = vif.m_axi_mem_awid;
                    req.addr     = vif.m_axi_mem_awaddr;
                    req.len      = vif.m_axi_mem_awlen;
                    req.size     = vif.m_axi_mem_awsize;
                    req.burst    = vif.m_axi_mem_awburst;
                    req.wait_cnt = 0;
                    aw_q.push_back(req);
                    aw_delay = $urandom_range(min_ready_delay, max_ready_delay);
                end

                if (vif.m_axi_mem_wvalid && vif.m_axi_mem_wready) begin
                    axi_w_beat_t wb;
                    wb.wdata = vif.m_axi_mem_wdata;
                    wb.wstrb = vif.m_axi_mem_wstrb;
                    wb.wlast = vif.m_axi_mem_wlast;
                    w_q.push_back(wb);
                    w_delay = $urandom_range(min_ready_delay, max_ready_delay);
                end

                if (vif.m_axi_mem_bvalid && vif.m_axi_mem_bready) begin
                    b_in_flight = 1'b0;
                    vif.m_axi_mem_bvalid <= 1'b0;
                end

                // 2. Drive next-cycle AWREADY & WREADY with 0..max_ready_delay stall
                if (aw_q.size() >= 16) begin
                    vif.m_axi_mem_awready <= 1'b0;
                end else if (aw_delay == 0) begin
                    vif.m_axi_mem_awready <= 1'b1;
                end else begin
                    if (vif.m_axi_mem_awvalid && !vif.m_axi_mem_awready) begin
                        aw_delay--;
                        vif.m_axi_mem_awready <= (aw_delay == 0);
                    end else begin
                        vif.m_axi_mem_awready <= 1'b0;
                    end
                end

                if (w_q.size() >= 256) begin
                    vif.m_axi_mem_wready <= 1'b0;
                end else if (w_delay == 0) begin
                    vif.m_axi_mem_wready <= 1'b1;
                end else begin
                    if (vif.m_axi_mem_wvalid && !vif.m_axi_mem_wready) begin
                        w_delay--;
                        vif.m_axi_mem_wready <= (w_delay == 0);
                    end else begin
                        vif.m_axi_mem_wready <= 1'b0;
                    end
                end

                // 3. Consume W beats into DRAM using wstrb-masked write
                while ((wr_active || (aw_q.size() > 0)) && (w_q.size() > 0)) begin
                    axi_w_beat_t wb;
                    bit [32:0]   beat_addr;
                    bit          expect_last;

                    if (!wr_active) begin
                        wr_cur      = aw_q.pop_front();
                        wr_active   = 1'b1;
                        wr_beat_idx = 0;
                    end

                    wb          = w_q.pop_front();
                    beat_addr   = calc_beat_addr(wr_cur.addr, wr_cur.len, wr_cur.size, wr_cur.burst, wr_beat_idx);
                    expect_last = (wr_beat_idx == int'(wr_cur.len));

                    write_word(beat_addr, wb.wdata, wb.wstrb);

                    if (wb.wlast !== expect_last) begin
                        `uvm_error("AXI4_MEM_SLV",
                            $sformatf("WLAST mismatch at beat %0d/%0d (addr=0x%09h): got %b expected %b",
                                      wr_beat_idx, wr_cur.len, wr_cur.addr, wb.wlast, expect_last))
                    end

                    if (expect_last) begin
                        axi_b_pend_t bp;
                        bp.id       = wr_cur.id;
                        bp.wait_cnt = $urandom_range(min_resp_delay, max_resp_delay);
                        b_pend_q.push_back(bp);
                        wr_active   = 1'b0;
                        wr_beat_idx = 0;
                    end else begin
                        wr_beat_idx++;
                    end
                end

                // 4. Drive B channel
                if (!b_in_flight && (b_pend_q.size() > 0)) begin
                    if (b_pend_q[0].wait_cnt == 0) begin
                        axi_b_pend_t bp = b_pend_q.pop_front();
                        vif.m_axi_mem_bid    <= bp.id;
                        vif.m_axi_mem_bresp  <= 2'b00;
                        vif.m_axi_mem_bvalid <= 1'b1;
                        b_in_flight           = 1'b1;
                    end else begin
                        b_pend_q[0].wait_cnt--;
                    end
                end
            end
        endtask

        virtual task run_read_channel();
            axi_req_t    ar_q[$];
            int unsigned ar_delay = 0;
            bit          r_burst_active = 1'b0;
            axi_req_t    rd_cur;
            int unsigned rd_beat_idx = 0;

            vif.m_axi_mem_arready <= 1'b0;
            vif.m_axi_mem_rvalid  <= 1'b0;
            vif.m_axi_mem_rdata   <= 256'd0;
            vif.m_axi_mem_rlast   <= 1'b0;
            vif.m_axi_mem_rresp   <= 2'b00;
            vif.m_axi_mem_rid     <= 1'b0;

            forever begin
                bit r_holding;
                @(posedge vif.clk);
                if (vif.rst_n !== 1'b1) begin
                    ar_q.delete();
                    r_burst_active = 1'b0;
                    rd_beat_idx    = 0;
                    ar_delay       = $urandom_range(min_ready_delay, max_ready_delay);
                    vif.m_axi_mem_arready <= 1'b0;
                    vif.m_axi_mem_rvalid  <= 1'b0;
                    vif.m_axi_mem_rdata   <= 256'd0;
                    vif.m_axi_mem_rlast   <= 1'b0;
                    vif.m_axi_mem_rresp   <= 2'b00;
                    vif.m_axi_mem_rid     <= 1'b0;
                    continue;
                end

                // 1. Sample AR and R handshakes
                if (vif.m_axi_mem_arvalid && vif.m_axi_mem_arready) begin
                    axi_req_t req;
                    req.id       = vif.m_axi_mem_arid;
                    req.addr     = vif.m_axi_mem_araddr;
                    req.len      = vif.m_axi_mem_arlen;
                    req.size     = vif.m_axi_mem_arsize;
                    req.burst    = vif.m_axi_mem_arburst;
                    req.wait_cnt = $urandom_range(min_resp_delay, max_resp_delay);
                    ar_q.push_back(req);
                    ar_delay = $urandom_range(min_ready_delay, max_ready_delay);
                end

                r_holding = (vif.m_axi_mem_rvalid && !vif.m_axi_mem_rready);
                if (vif.m_axi_mem_rvalid && vif.m_axi_mem_rready) begin
                    if (vif.m_axi_mem_rlast) begin
                        r_burst_active = 1'b0;
                        rd_beat_idx    = 0;
                    end else begin
                        rd_beat_idx++;
                    end
                end

                // 2. Drive next-cycle ARREADY with 0..max_ready_delay stall
                if (ar_q.size() >= 16) begin
                    vif.m_axi_mem_arready <= 1'b0;
                end else if (ar_delay == 0) begin
                    vif.m_axi_mem_arready <= 1'b1;
                end else begin
                    if (vif.m_axi_mem_arvalid && !vif.m_axi_mem_arready) begin
                        ar_delay--;
                        vif.m_axi_mem_arready <= (ar_delay == 0);
                    end else begin
                        vif.m_axi_mem_arready <= 1'b0;
                    end
                end

                // 3. Drive R channel when not stalled by !rready
                if (!r_holding) begin
                    if (r_burst_active) begin
                        bit [32:0] beat_addr = calc_beat_addr(rd_cur.addr, rd_cur.len, rd_cur.size, rd_cur.burst, rd_beat_idx);
                        vif.m_axi_mem_rid    <= rd_cur.id;
                        vif.m_axi_mem_rdata  <= read_word(beat_addr);
                        vif.m_axi_mem_rresp  <= 2'b00;
                        vif.m_axi_mem_rlast  <= (rd_beat_idx == int'(rd_cur.len));
                        vif.m_axi_mem_rvalid <= 1'b1;
                    end else if (ar_q.size() > 0) begin
                        if (ar_q[0].wait_cnt == 0) begin
                            bit [32:0] beat_addr;
                            rd_cur         = ar_q.pop_front();
                            r_burst_active = 1'b1;
                            rd_beat_idx    = 0;
                            beat_addr      = calc_beat_addr(rd_cur.addr, rd_cur.len, rd_cur.size, rd_cur.burst, 0);
                            vif.m_axi_mem_rid    <= rd_cur.id;
                            vif.m_axi_mem_rdata  <= read_word(beat_addr);
                            vif.m_axi_mem_rresp  <= 2'b00;
                            vif.m_axi_mem_rlast  <= (rd_cur.len == 8'd0);
                            vif.m_axi_mem_rvalid <= 1'b1;
                        end else begin
                            ar_q[0].wait_cnt--;
                            vif.m_axi_mem_rvalid <= 1'b0;
                            vif.m_axi_mem_rlast  <= 1'b0;
                        end
                    end else begin
                        vif.m_axi_mem_rvalid <= 1'b0;
                        vif.m_axi_mem_rlast  <= 1'b0;
                    end
                end
            end
        endtask

        virtual task run_phase(uvm_phase phase);
            fork
                run_write_channel();
                run_read_channel();
            join
        endtask
    endclass

    class axi4_mem_monitor extends uvm_monitor;
        `uvm_component_utils(axi4_mem_monitor)

        virtual hevc_axi_if vif;
        uvm_analysis_port #(axi4_mem_txn) ap;

        typedef struct {
            bit [0:0]  id;
            bit [32:0] addr;
            bit [7:0]  len;
            bit [2:0]  size;
            bit [1:0]  burst;
        } mon_addr_t;

        typedef struct {
            bit [255:0] data[$];
            bit [31:0]  wstrb[$];
        } mon_w_burst_t;

        protected mon_addr_t    aw_q[$];
        protected mon_w_burst_t w_burst_q[$];
        protected mon_w_burst_t cur_w_burst;
        protected mon_addr_t    ar_q[$];
        protected axi4_mem_txn  cur_rd_txn;

        function new(string name = "axi4_mem_monitor", uvm_component parent = null);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual hevc_axi_if)::get(this, "", "vif", vif)) begin
                `uvm_fatal("NOVIF", "axi4_mem_monitor could not find virtual interface 'vif'")
            end
        endfunction

        virtual task run_phase(uvm_phase phase);
            cur_rd_txn = null;
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n !== 1'b1) begin
                    aw_q.delete();
                    w_burst_q.delete();
                    cur_w_burst.data.delete();
                    cur_w_burst.wstrb.delete();
                    ar_q.delete();
                    cur_rd_txn = null;
                    continue;
                end

                // Write Address Channel
                if (vif.m_axi_mem_awvalid && vif.m_axi_mem_awready) begin
                    mon_addr_t aw;
                    aw.id    = vif.m_axi_mem_awid;
                    aw.addr  = vif.m_axi_mem_awaddr;
                    aw.len   = vif.m_axi_mem_awlen;
                    aw.size  = vif.m_axi_mem_awsize;
                    aw.burst = vif.m_axi_mem_awburst;
                    aw_q.push_back(aw);
                end

                // Write Data Channel
                if (vif.m_axi_mem_wvalid && vif.m_axi_mem_wready) begin
                    cur_w_burst.data.push_back(vif.m_axi_mem_wdata);
                    cur_w_burst.wstrb.push_back(vif.m_axi_mem_wstrb);
                    if (vif.m_axi_mem_wlast) begin
                        w_burst_q.push_back(cur_w_burst);
                        cur_w_burst.data.delete();
                        cur_w_burst.wstrb.delete();
                    end
                end

                // Write Response Channel
                if (vif.m_axi_mem_bvalid && vif.m_axi_mem_bready) begin
                    if (aw_q.size() > 0 && w_burst_q.size() > 0) begin
                        axi4_mem_txn  tr = axi4_mem_txn::type_id::create("wr_tr");
                        mon_addr_t    aw = aw_q.pop_front();
                        mon_w_burst_t wb = w_burst_q.pop_front();
                        tr.is_write = 1'b1;
                        tr.id       = aw.id;
                        tr.addr     = aw.addr;
                        tr.len      = aw.len;
                        tr.size     = aw.size;
                        tr.burst    = aw.burst;
                        tr.data     = wb.data;
                        tr.wstrb    = wb.wstrb;
                        tr.resp     = vif.m_axi_mem_bresp;
                        ap.write(tr);
                    end else begin
                        `uvm_warning("AXI4_MEM_MON", "Observed bvalid && bready without matching AW/W burst")
                    end
                end

                // Read Address Channel
                if (vif.m_axi_mem_arvalid && vif.m_axi_mem_arready) begin
                    mon_addr_t ar;
                    ar.id    = vif.m_axi_mem_arid;
                    ar.addr  = vif.m_axi_mem_araddr;
                    ar.len   = vif.m_axi_mem_arlen;
                    ar.size  = vif.m_axi_mem_arsize;
                    ar.burst = vif.m_axi_mem_arburst;
                    ar_q.push_back(ar);
                end

                // Read Data Channel
                if (vif.m_axi_mem_rvalid && vif.m_axi_mem_rready) begin
                    if (cur_rd_txn == null) begin
                        if (ar_q.size() > 0) begin
                            mon_addr_t ar = ar_q.pop_front();
                            cur_rd_txn = axi4_mem_txn::type_id::create("rd_tr");
                            cur_rd_txn.is_write = 1'b0;
                            cur_rd_txn.id       = ar.id;
                            cur_rd_txn.addr     = ar.addr;
                            cur_rd_txn.len      = ar.len;
                            cur_rd_txn.size     = ar.size;
                            cur_rd_txn.burst    = ar.burst;
                            cur_rd_txn.resp     = vif.m_axi_mem_rresp;
                        end else begin
                            `uvm_warning("AXI4_MEM_MON", "Observed rvalid && rready without matching AR")
                        end
                    end
                    if (cur_rd_txn != null) begin
                        cur_rd_txn.data.push_back(vif.m_axi_mem_rdata);
                        if (vif.m_axi_mem_rresp != 2'b00) begin
                            cur_rd_txn.resp = vif.m_axi_mem_rresp;
                        end
                        if (vif.m_axi_mem_rlast) begin
                            ap.write(cur_rd_txn);
                            cur_rd_txn = null;
                        end
                    end
                end
            end
        endtask
    endclass

    class axi4_mem_agent extends uvm_agent;
        `uvm_component_utils(axi4_mem_agent)

        axi4_mem_slave_driver drv;
        axi4_mem_monitor      mon;
        uvm_analysis_port #(axi4_mem_txn) ap;

        function new(string name = "axi4_mem_agent", uvm_component parent = null);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            virtual hevc_axi_if vif_tmp;
            super.build_phase(phase);
            if (uvm_config_db #(virtual hevc_axi_if)::get(this, "", "vif", vif_tmp)) begin
                uvm_config_db #(virtual hevc_axi_if)::set(this, "*", "vif", vif_tmp);
            end
            mon = axi4_mem_monitor::type_id::create("mon", this);
            if (get_is_active() == UVM_ACTIVE) begin
                drv = axi4_mem_slave_driver::type_id::create("drv", this);
            end
        endfunction

        virtual function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            mon.ap.connect(ap);
        endfunction

        virtual function void set_latency(
            int unsigned min_rdy,
            int unsigned max_rdy,
            int unsigned min_rsp,
            int unsigned max_rsp
        );
            if (drv != null) drv.set_latency(min_rdy, max_rdy, min_rsp, max_rsp);
        endfunction
    endclass

endpackage
