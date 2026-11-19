`timescale 1ns/1ps
//=============================================================================
// cabac_uvm_pkg.sv
// UVM 1.2 Verification Package for HEVC CABAC M-Coder (rtl/entropy/range_coder.v)
//
// Contains:
//   - cabac_item, cabac_byte_item
//   - cabac_sequencer, cabac_driver, cabac_sink_driver, cabac_monitor, cabac_agent
//   - cabac_scoreboard (bit-exact HM 18.0 TEncBinCABAC reference model)
//   - cabac_coverage (functional covergroup cg_cabac)
//   - cabac_env
//   - Sequences: cabac_carry_ripple_seq, cabac_lps_extreme_seq, cabac_random_stress_seq
//   - Test: cabac_uvm_test
//=============================================================================

package cabac_uvm_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // Dual analysis port imp suffixes for scoreboard
    `uvm_analysis_imp_decl(_in)
    `uvm_analysis_imp_decl(_out)

    // -------------------------------------------------------------------------
    // Operation Type Enum
    // -------------------------------------------------------------------------
    typedef enum int {
        OP_INIT    = 0,
        OP_REG_BIN = 1,
        OP_EP_BIN  = 2,
        OP_TRM_BIN = 3,
        OP_FLUSH   = 4
    } cabac_op_e;

    // -------------------------------------------------------------------------
    // Sequence Item: Input Operation to range_coder
    // -------------------------------------------------------------------------
    class cabac_item extends uvm_sequence_item;
        rand cabac_op_e    op_type;
        rand bit           bin_val;
        rand bit [5:0]     pstate;
        rand bit           valmps;
        rand bit [7:0]     ctx_id;
        rand int unsigned  pre_delay;

        constraint c_pre_delay {
            pre_delay inside {[0:2]};
        }
        constraint c_ctx_id {
            ctx_id inside {[0:185]};
        }

        `uvm_object_utils_begin(cabac_item)
            `uvm_field_enum(cabac_op_e, op_type, UVM_ALL_ON)
            `uvm_field_int(bin_val,   UVM_ALL_ON)
            `uvm_field_int(pstate,    UVM_ALL_ON)
            `uvm_field_int(valmps,    UVM_ALL_ON)
            `uvm_field_int(ctx_id,    UVM_ALL_ON)
            `uvm_field_int(pre_delay, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "cabac_item");
            super.new(name);
        endfunction

        virtual function string convert2string();
            return $sformatf("op=%s bin=%0b ps=%0d valmps=%0b ctx=%0d delay=%0d",
                             op_type.name(), bin_val, pstate, valmps, ctx_id, pre_delay);
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Sequence Item: Output Byte / Flush Marker from range_coder
    // -------------------------------------------------------------------------
    class cabac_byte_item extends uvm_sequence_item;
        bit [7:0] byte_data;
        bit       is_flush_marker;

        `uvm_object_utils_begin(cabac_byte_item)
            `uvm_field_int(byte_data,       UVM_ALL_ON)
            `uvm_field_int(is_flush_marker, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "cabac_byte_item");
            super.new(name);
        endfunction

        virtual function string convert2string();
            if (is_flush_marker)
                return "FLUSH_DONE_MARKER";
            else
                return $sformatf("BYTE=0x%02x", byte_data);
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Sequencer
    // -------------------------------------------------------------------------
    class cabac_sequencer extends uvm_sequencer #(cabac_item);
        `uvm_component_utils(cabac_sequencer)

        function new(string name = "cabac_sequencer", uvm_component parent = null);
            super.new(name, parent);
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Driver: Drives range_coder input channels synchronized to S_READY/bin_ready
    // -------------------------------------------------------------------------
    class cabac_driver extends uvm_driver #(cabac_item);
        `uvm_component_utils(cabac_driver)

        virtual cabac_if vif;

        function new(string name = "cabac_driver", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual cabac_if)::get(this, "", "vif", vif)) begin
                `uvm_fatal("CABAC_DRV", "Failed to get virtual interface 'vif' from uvm_config_db")
            end
        endfunction

        protected virtual task drive_idle();
            vif.coder_init  <= 1'b0;
            vif.bin_valid   <= 1'b0;
            vif.ep_valid    <= 1'b0;
            vif.trm_valid   <= 1'b0;
            vif.flush_valid <= 1'b0;
            vif.bin_value   <= 1'b0;
            vif.bin_pstate  <= 6'd0;
            vif.bin_valmps  <= 1'b0;
            vif.bin_ctx_id  <= 8'd0;
        endtask

        protected virtual task wait_ready_accept();
            do begin
                @(posedge vif.clk);
            end while (vif.bin_ready !== 1'b1 || vif.coder_busy !== 1'b0);
        endtask

        protected virtual task drive_item(cabac_item req);
            if (req.pre_delay > 0) begin
                drive_idle();
                repeat (req.pre_delay) @(posedge vif.clk);
            end

            case (req.op_type)
                OP_INIT: begin
                    // Wait until range_coder is completely quiescent before slice init
                    while (vif.coder_busy !== 1'b0 ||
                           vif.bin_ready  !== 1'b1 ||
                           vif.byte_valid !== 1'b0) begin
                        @(posedge vif.clk);
                    end
                    drive_idle();
                    vif.coder_init <= 1'b1;
                    @(posedge vif.clk);
                    drive_idle();
                end

                OP_REG_BIN: begin
                    vif.coder_init  <= 1'b0;
                    vif.bin_valid   <= 1'b1;
                    vif.ep_valid    <= 1'b0;
                    vif.trm_valid   <= 1'b0;
                    vif.flush_valid <= 1'b0;
                    vif.bin_value   <= req.bin_val;
                    vif.bin_pstate  <= req.pstate;
                    vif.bin_valmps  <= req.valmps;
                    vif.bin_ctx_id  <= req.ctx_id;
                    wait_ready_accept();
                    drive_idle();
                end

                OP_EP_BIN: begin
                    vif.coder_init  <= 1'b0;
                    vif.bin_valid   <= 1'b0;
                    vif.ep_valid    <= 1'b1;
                    vif.trm_valid   <= 1'b0;
                    vif.flush_valid <= 1'b0;
                    vif.bin_value   <= req.bin_val;
                    vif.bin_pstate  <= 6'd0;
                    vif.bin_valmps  <= 1'b0;
                    vif.bin_ctx_id  <= req.ctx_id;
                    wait_ready_accept();
                    drive_idle();
                end

                OP_TRM_BIN: begin
                    vif.coder_init  <= 1'b0;
                    vif.bin_valid   <= 1'b0;
                    vif.ep_valid    <= 1'b0;
                    vif.trm_valid   <= 1'b1;
                    vif.flush_valid <= 1'b0;
                    vif.bin_value   <= req.bin_val;
                    vif.bin_pstate  <= 6'd0;
                    vif.bin_valmps  <= 1'b0;
                    vif.bin_ctx_id  <= req.ctx_id;
                    wait_ready_accept();
                    drive_idle();
                end

                OP_FLUSH: begin
                    vif.coder_init  <= 1'b0;
                    vif.bin_valid   <= 1'b0;
                    vif.ep_valid    <= 1'b0;
                    vif.trm_valid   <= 1'b0;
                    vif.flush_valid <= 1'b1;
                    vif.bin_value   <= 1'b0;
                    vif.bin_pstate  <= 6'd0;
                    vif.bin_valmps  <= 1'b0;
                    vif.bin_ctx_id  <= 8'd0;
                    wait_ready_accept();
                    drive_idle();
                    // Wait for S_FLUSH_1..5 to drain and pulse flush_done
                    do begin
                        @(posedge vif.clk);
                    end while (vif.flush_done !== 1'b1);
                    // Allow monitor one clean cycle after flush_done pulse
                    @(posedge vif.clk);
                end

                default: begin
                    `uvm_error("CABAC_DRV", $sformatf("Unknown op_type: %0d", req.op_type))
                end
            endcase
        endtask

        virtual task run_phase(uvm_phase phase);
            cabac_item req;

            // Initialize outputs during reset
            @(posedge vif.clk);
            drive_idle();
            while (vif.rst_n !== 1'b1) begin
                @(posedge vif.clk);
                drive_idle();
            end

            forever begin
                seq_item_port.get_next_item(req);
                drive_item(req);
                seq_item_port.item_done();
            end
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Sink Driver: Drives byte_ready with configurable random backpressure
    // -------------------------------------------------------------------------
    class cabac_sink_driver extends uvm_component;
        `uvm_component_utils(cabac_sink_driver)

        virtual cabac_if vif;

        bit          enable_backpressure = 1'b1;
        int unsigned stall_pct           = 25;
        int unsigned max_consec_stalls   = 8;

        function new(string name = "cabac_sink_driver", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual cabac_if)::get(this, "", "vif", vif)) begin
                `uvm_fatal("CABAC_SINK", "Failed to get virtual interface 'vif' from uvm_config_db")
            end
            void'(uvm_config_db#(int unsigned)::get(this, "", "stall_pct", stall_pct));
            void'(uvm_config_db#(bit)::get(this, "", "enable_backpressure", enable_backpressure));
        endfunction

        virtual task run_phase(uvm_phase phase);
            int unsigned consec_stalls = 0;

            @(posedge vif.clk);
            vif.byte_ready <= 1'b1;
            while (vif.rst_n !== 1'b1) begin
                @(posedge vif.clk);
                vif.byte_ready <= 1'b1;
            end

            forever begin
                @(posedge vif.clk);
                if (vif.rst_n !== 1'b1) begin
                    vif.byte_ready <= 1'b1;
                    consec_stalls = 0;
                end else if (!enable_backpressure || stall_pct == 0) begin
                    vif.byte_ready <= 1'b1;
                    consec_stalls = 0;
                end else if (consec_stalls >= max_consec_stalls) begin
                    vif.byte_ready <= 1'b1;
                    consec_stalls = 0;
                end else if ($urandom_range(0, 99) < int'(stall_pct)) begin
                    vif.byte_ready <= 1'b0;
                    consec_stalls++;
                end else begin
                    vif.byte_ready <= 1'b1;
                    consec_stalls = 0;
                end
            end
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Monitor: Observes accepted inputs and emitted bytes / flush_done pulses
    // -------------------------------------------------------------------------
    class cabac_monitor extends uvm_monitor;
        `uvm_component_utils(cabac_monitor)

        virtual cabac_if vif;

        uvm_analysis_port #(cabac_item)      ap_in;
        uvm_analysis_port #(cabac_byte_item) ap_out;

        int unsigned byte_stall_cycles = 0;
        int unsigned byte_valid_cycles = 0;

        function new(string name = "cabac_monitor", uvm_component parent = null);
            super.new(name, parent);
            ap_in  = new("ap_in",  this);
            ap_out = new("ap_out", this);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual cabac_if)::get(this, "", "vif", vif)) begin
                `uvm_fatal("CABAC_MON", "Failed to get virtual interface 'vif' from uvm_config_db")
            end
        endfunction

        virtual task run_phase(uvm_phase phase);
            cabac_item      in_tr;
            cabac_byte_item out_tr;

            forever begin
                @(posedge vif.clk);
                if (vif.rst_n === 1'b1) begin
                    // Track backpressure during active byte_valid
                    if (vif.byte_valid === 1'b1) begin
                        byte_valid_cycles++;
                        if (vif.byte_ready === 1'b0) begin
                            byte_stall_cycles++;
                        end
                    end

                    // 1. Accepted input operation (exact RTL priority order)
                    if (vif.coder_init === 1'b1) begin
                        in_tr = cabac_item::type_id::create("in_tr");
                        in_tr.op_type   = OP_INIT;
                        in_tr.bin_val   = 1'b0;
                        in_tr.pstate    = 6'd0;
                        in_tr.valmps    = 1'b0;
                        in_tr.ctx_id    = 8'd0;
                        in_tr.pre_delay = 0;
                        ap_in.write(in_tr);
                    end else if (vif.coder_busy === 1'b0 && vif.bin_ready === 1'b1) begin
                        if (vif.trm_valid === 1'b1) begin
                            in_tr = cabac_item::type_id::create("in_tr");
                            in_tr.op_type   = OP_TRM_BIN;
                            in_tr.bin_val   = vif.bin_value;
                            in_tr.pstate    = 6'd0;
                            in_tr.valmps    = 1'b0;
                            in_tr.ctx_id    = vif.bin_ctx_id;
                            in_tr.pre_delay = 0;
                            ap_in.write(in_tr);
                        end else if (vif.ep_valid === 1'b1) begin
                            in_tr = cabac_item::type_id::create("in_tr");
                            in_tr.op_type   = OP_EP_BIN;
                            in_tr.bin_val   = vif.bin_value;
                            in_tr.pstate    = 6'd0;
                            in_tr.valmps    = 1'b0;
                            in_tr.ctx_id    = vif.bin_ctx_id;
                            in_tr.pre_delay = 0;
                            ap_in.write(in_tr);
                        end else if (vif.bin_valid === 1'b1) begin
                            in_tr = cabac_item::type_id::create("in_tr");
                            in_tr.op_type   = OP_REG_BIN;
                            in_tr.bin_val   = vif.bin_value;
                            in_tr.pstate    = vif.bin_pstate;
                            in_tr.valmps    = vif.bin_valmps;
                            in_tr.ctx_id    = vif.bin_ctx_id;
                            in_tr.pre_delay = 0;
                            ap_in.write(in_tr);
                        end else if (vif.flush_valid === 1'b1) begin
                            in_tr = cabac_item::type_id::create("in_tr");
                            in_tr.op_type   = OP_FLUSH;
                            in_tr.bin_val   = 1'b0;
                            in_tr.pstate    = 6'd0;
                            in_tr.valmps    = 1'b0;
                            in_tr.ctx_id    = 8'd0;
                            in_tr.pre_delay = 0;
                            ap_in.write(in_tr);
                        end
                    end

                    // 2. Output byte accepted by sink
                    if (vif.byte_valid === 1'b1 && vif.byte_ready === 1'b1) begin
                        out_tr = cabac_byte_item::type_id::create("out_tr");
                        out_tr.byte_data       = vif.byte_out;
                        out_tr.is_flush_marker = 1'b0;
                        ap_out.write(out_tr);
                    end

                    // 3. Flush completion pulse
                    if (vif.flush_done === 1'b1) begin
                        out_tr = cabac_byte_item::type_id::create("out_tr");
                        out_tr.byte_data       = 8'h00;
                        out_tr.is_flush_marker = 1'b1;
                        ap_out.write(out_tr);
                    end
                end
            end
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Agent
    // -------------------------------------------------------------------------
    class cabac_agent extends uvm_agent;
        `uvm_component_utils(cabac_agent)

        cabac_sequencer   sequencer;
        cabac_driver      driver;
        cabac_sink_driver sink_driver;
        cabac_monitor     monitor;

        function new(string name = "cabac_agent", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            monitor = cabac_monitor::type_id::create("monitor", this);
            if (get_is_active() == UVM_ACTIVE) begin
                sequencer   = cabac_sequencer::type_id::create("sequencer", this);
                driver      = cabac_driver::type_id::create("driver", this);
                sink_driver = cabac_sink_driver::type_id::create("sink_driver", this);
            end
        endfunction

        virtual function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            if (get_is_active() == UVM_ACTIVE) begin
                driver.seq_item_port.connect(sequencer.seq_item_export);
            end
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Scoreboard: Bit-Exact HM 18.0 TEncBinCABAC Reference Predictor
    // -------------------------------------------------------------------------
    class cabac_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(cabac_scoreboard)

        uvm_analysis_imp_in  #(cabac_item, cabac_scoreboard)      in_imp;
        uvm_analysis_imp_out #(cabac_byte_item, cabac_scoreboard) out_imp;

        // HM 18.0 TEncBinCABAC model state
        bit [8:0]  ref_range;
        bit [31:0] ref_low;
        int        ref_bits_left;
        bit [7:0]  ref_buffered_byte;
        int        ref_num_buffered_bytes;

        bit [7:0]  expected_byte_q[$];

        // Verification statistics
        int unsigned total_inits           = 0;
        int unsigned total_reg_bins        = 0;
        int unsigned total_ep_bins         = 0;
        int unsigned total_trm_bins        = 0;
        int unsigned total_flushes         = 0;
        int unsigned total_bins_coded      = 0;
        int unsigned total_bytes_expected  = 0;
        int unsigned total_bytes_received  = 0;
        int unsigned byte_mismatches       = 0;
        int unsigned flush_mismatches      = 0;
        int unsigned carry_ripple_events   = 0;
        int unsigned noncarry_ff_events    = 0;
        int          max_num_ff_seen       = 0;

        function new(string name = "cabac_scoreboard", uvm_component parent = null);
            super.new(name, parent);
            in_imp  = new("in_imp",  this);
            out_imp = new("out_imp", this);
            ref_init();
        endfunction

        // Exact HM g_aucLPSTable[64][4]
        static function automatic bit [7:0] hm_lps_table(input bit [5:0] ps, input bit [1:0] qr);
            bit [7:0] t [0:255];
            t[  0]=8'd128; t[  1]=8'd176; t[  2]=8'd208; t[  3]=8'd240;
            t[  4]=8'd128; t[  5]=8'd167; t[  6]=8'd197; t[  7]=8'd227;
            t[  8]=8'd128; t[  9]=8'd158; t[ 10]=8'd187; t[ 11]=8'd216;
            t[ 12]=8'd123; t[ 13]=8'd150; t[ 14]=8'd178; t[ 15]=8'd205;
            t[ 16]=8'd116; t[ 17]=8'd142; t[ 18]=8'd169; t[ 19]=8'd195;
            t[ 20]=8'd111; t[ 21]=8'd135; t[ 22]=8'd160; t[ 23]=8'd185;
            t[ 24]=8'd105; t[ 25]=8'd128; t[ 26]=8'd152; t[ 27]=8'd175;
            t[ 28]=8'd100; t[ 29]=8'd122; t[ 30]=8'd144; t[ 31]=8'd166;
            t[ 32]= 8'd95; t[ 33]=8'd116; t[ 34]=8'd137; t[ 35]=8'd158;
            t[ 36]= 8'd90; t[ 37]=8'd110; t[ 38]=8'd130; t[ 39]=8'd150;
            t[ 40]= 8'd85; t[ 41]=8'd104; t[ 42]=8'd123; t[ 43]=8'd142;
            t[ 44]= 8'd81; t[ 45]= 8'd99; t[ 46]=8'd117; t[ 47]=8'd135;
            t[ 48]= 8'd77; t[ 49]= 8'd94; t[ 50]=8'd111; t[ 51]=8'd128;
            t[ 52]= 8'd73; t[ 53]= 8'd89; t[ 54]=8'd105; t[ 55]=8'd122;
            t[ 56]= 8'd69; t[ 57]= 8'd85; t[ 58]=8'd100; t[ 59]=8'd116;
            t[ 60]= 8'd66; t[ 61]= 8'd80; t[ 62]= 8'd95; t[ 63]=8'd110;
            t[ 64]= 8'd62; t[ 65]= 8'd76; t[ 66]= 8'd90; t[ 67]=8'd104;
            t[ 68]= 8'd59; t[ 69]= 8'd72; t[ 70]= 8'd86; t[ 71]= 8'd99;
            t[ 72]= 8'd56; t[ 73]= 8'd69; t[ 74]= 8'd81; t[ 75]= 8'd94;
            t[ 76]= 8'd53; t[ 77]= 8'd65; t[ 78]= 8'd77; t[ 79]= 8'd89;
            t[ 80]= 8'd51; t[ 81]= 8'd62; t[ 82]= 8'd73; t[ 83]= 8'd85;
            t[ 84]= 8'd48; t[ 85]= 8'd59; t[ 86]= 8'd69; t[ 87]= 8'd80;
            t[ 88]= 8'd46; t[ 89]= 8'd56; t[ 90]= 8'd66; t[ 91]= 8'd76;
            t[ 92]= 8'd43; t[ 93]= 8'd53; t[ 94]= 8'd63; t[ 95]= 8'd72;
            t[ 96]= 8'd41; t[ 97]= 8'd50; t[ 98]= 8'd59; t[ 99]= 8'd69;
            t[100]= 8'd39; t[101]= 8'd48; t[102]= 8'd56; t[103]= 8'd65;
            t[104]= 8'd37; t[105]= 8'd45; t[106]= 8'd54; t[107]= 8'd62;
            t[108]= 8'd35; t[109]= 8'd43; t[110]= 8'd51; t[111]= 8'd59;
            t[112]= 8'd33; t[113]= 8'd41; t[114]= 8'd48; t[115]= 8'd56;
            t[116]= 8'd32; t[117]= 8'd39; t[118]= 8'd46; t[119]= 8'd53;
            t[120]= 8'd30; t[121]= 8'd37; t[122]= 8'd43; t[123]= 8'd50;
            t[124]= 8'd29; t[125]= 8'd35; t[126]= 8'd41; t[127]= 8'd48;
            t[128]= 8'd27; t[129]= 8'd33; t[130]= 8'd39; t[131]= 8'd45;
            t[132]= 8'd26; t[133]= 8'd31; t[134]= 8'd37; t[135]= 8'd43;
            t[136]= 8'd24; t[137]= 8'd30; t[138]= 8'd35; t[139]= 8'd41;
            t[140]= 8'd23; t[141]= 8'd28; t[142]= 8'd33; t[143]= 8'd39;
            t[144]= 8'd22; t[145]= 8'd27; t[146]= 8'd32; t[147]= 8'd37;
            t[148]= 8'd21; t[149]= 8'd26; t[150]= 8'd30; t[151]= 8'd35;
            t[152]= 8'd20; t[153]= 8'd24; t[154]= 8'd29; t[155]= 8'd33;
            t[156]= 8'd19; t[157]= 8'd23; t[158]= 8'd27; t[159]= 8'd31;
            t[160]= 8'd18; t[161]= 8'd22; t[162]= 8'd26; t[163]= 8'd30;
            t[164]= 8'd17; t[165]= 8'd21; t[166]= 8'd25; t[167]= 8'd28;
            t[168]= 8'd16; t[169]= 8'd20; t[170]= 8'd23; t[171]= 8'd27;
            t[172]= 8'd15; t[173]= 8'd19; t[174]= 8'd22; t[175]= 8'd25;
            t[176]= 8'd14; t[177]= 8'd18; t[178]= 8'd21; t[179]= 8'd24;
            t[180]= 8'd14; t[181]= 8'd17; t[182]= 8'd20; t[183]= 8'd23;
            t[184]= 8'd13; t[185]= 8'd16; t[186]= 8'd19; t[187]= 8'd22;
            t[188]= 8'd12; t[189]= 8'd15; t[190]= 8'd18; t[191]= 8'd21;
            t[192]= 8'd12; t[193]= 8'd14; t[194]= 8'd17; t[195]= 8'd20;
            t[196]= 8'd11; t[197]= 8'd14; t[198]= 8'd16; t[199]= 8'd19;
            t[200]= 8'd11; t[201]= 8'd13; t[202]= 8'd15; t[203]= 8'd18;
            t[204]= 8'd10; t[205]= 8'd12; t[206]= 8'd15; t[207]= 8'd17;
            t[208]= 8'd10; t[209]= 8'd12; t[210]= 8'd14; t[211]= 8'd16;
            t[212]=  8'd9; t[213]= 8'd11; t[214]= 8'd13; t[215]= 8'd15;
            t[216]=  8'd9; t[217]= 8'd11; t[218]= 8'd12; t[219]= 8'd14;
            t[220]=  8'd8; t[221]= 8'd10; t[222]= 8'd12; t[223]= 8'd14;
            t[224]=  8'd8; t[225]=  8'd9; t[226]= 8'd11; t[227]= 8'd13;
            t[228]=  8'd7; t[229]=  8'd9; t[230]= 8'd11; t[231]= 8'd12;
            t[232]=  8'd7; t[233]=  8'd9; t[234]= 8'd10; t[235]= 8'd12;
            t[236]=  8'd7; t[237]=  8'd8; t[238]= 8'd10; t[239]= 8'd11;
            t[240]=  8'd6; t[241]=  8'd8; t[242]=  8'd9; t[243]= 8'd11;
            t[244]=  8'd6; t[245]=  8'd7; t[246]=  8'd9; t[247]= 8'd10;
            t[248]=  8'd6; t[249]=  8'd7; t[250]=  8'd8; t[251]=  8'd9;
            t[252]=  8'd2; t[253]=  8'd2; t[254]=  8'd2; t[255]=  8'd2;
            return t[{ps, qr}];
        endfunction

        static function automatic [2:0] hm_renorm_lzc(input bit [7:0] lps_val);
            casez (lps_val)
                8'b1???????: return 3'd1;
                8'b01??????: return 3'd2;
                8'b001?????: return 3'd3;
                8'b0001????: return 3'd4;
                8'b00001???: return 3'd5;
                8'b000001??: return 3'd6;
                8'b0000001?: return 3'd7;
                default:     return 3'd7;
            endcase
        endfunction

        protected function void push_expected_byte(bit [7:0] b);
            expected_byte_q.push_back(b);
            total_bytes_expected++;
        endfunction

        protected function void ref_init();
            ref_range              = 9'd510;
            ref_low                = 32'd0;
            ref_bits_left          = 23;
            ref_buffered_byte      = 8'hFF;
            ref_num_buffered_bytes = 0;
        endfunction

        protected function void ref_write_out();
            bit [8:0] lead_byte;
            int       shift_val;
            bit       carry;

            shift_val      = 24 - ref_bits_left;
            lead_byte      = (ref_low >> shift_val) & 9'h1FF;
            ref_bits_left += 8;
            ref_low        = ref_low & (32'hFFFF_FFFF >> ref_bits_left);

            if (lead_byte == 9'h0FF) begin
                ref_num_buffered_bytes++;
                if (ref_num_buffered_bytes > max_num_ff_seen)
                    max_num_ff_seen = ref_num_buffered_bytes;
            end else begin
                if (ref_num_buffered_bytes > 0) begin
                    carry = lead_byte[8];
                    if (ref_num_buffered_bytes > 1) begin
                        if (carry) carry_ripple_events++;
                        else       noncarry_ff_events++;
                    end
                    push_expected_byte(ref_buffered_byte + {7'd0, carry});
                    while (ref_num_buffered_bytes > 1) begin
                        push_expected_byte(carry ? 8'h00 : 8'hFF);
                        ref_num_buffered_bytes--;
                    end
                end
                ref_buffered_byte      = lead_byte[7:0];
                ref_num_buffered_bytes = 1;
            end
        endfunction

        protected function void ref_test_and_write_out();
            while (ref_bits_left < 12) begin
                ref_write_out();
            end
        endfunction

        protected function void ref_encode_bin(bit bin_val, bit [5:0] ps, bit valmps);
            bit [7:0] lps_val;
            bit [8:0] mps_range;
            int       renorm_shift;

            lps_val   = hm_lps_table(ps, ref_range[7:6]);
            mps_range = ref_range - {1'b0, lps_val};

            if (bin_val == valmps) begin
                if (mps_range < 9'd256) begin
                    ref_low   = ref_low << 1;
                    ref_range = mps_range << 1;
                    ref_bits_left--;
                    ref_test_and_write_out();
                end else begin
                    ref_range = mps_range;
                end
            end else begin
                renorm_shift = int'(hm_renorm_lzc(lps_val));
                ref_low   = (ref_low + {23'd0, mps_range}) << renorm_shift;
                ref_range = {1'b0, lps_val} << renorm_shift;
                ref_bits_left -= renorm_shift;
                ref_test_and_write_out();
            end
        endfunction

        protected function void ref_encode_ep(bit bin_val);
            ref_low = (ref_low << 1) + (bin_val ? {23'd0, ref_range} : 32'd0);
            ref_bits_left--;
            ref_test_and_write_out();
        endfunction

        protected function void ref_encode_trm(bit bin_val);
            if (bin_val) begin
                ref_low        = (ref_low + {23'd0, ref_range - 9'd2}) << 7;
                ref_range      = 9'd256;
                ref_bits_left -= 7;
                ref_test_and_write_out();
            end else begin
                if ((ref_range - 9'd2) < 9'd256) begin
                    ref_low   = ref_low << 1;
                    ref_range = (ref_range - 9'd2) << 1;
                    ref_bits_left--;
                    ref_test_and_write_out();
                end else begin
                    ref_range = ref_range - 9'd2;
                end
            end
        endfunction

        protected function void ref_flush();
            int        shift_val;
            bit        carry;
            bit [7:0]  ff_b;
            bit [23:0] V;
            bit [23:0] final_val;
            int        P;

            shift_val = 32 - ref_bits_left;
            carry     = ((ref_low >> shift_val) != 32'd0);

            if (ref_num_buffered_bytes > 0) begin
                if (ref_num_buffered_bytes > 1) begin
                    if (carry) carry_ripple_events++;
                    else       noncarry_ff_events++;
                end
                ref_low = carry ? (ref_low - (32'd1 << shift_val)) : ref_low;
                push_expected_byte(ref_buffered_byte + {7'd0, carry});
                ff_b = carry ? 8'h00 : 8'hFF;
                while (ref_num_buffered_bytes > 1) begin
                    push_expected_byte(ff_b);
                    ref_num_buffered_bytes--;
                end
            end else begin
                ref_low = carry ? (ref_low - (32'd1 << shift_val)) : ref_low;
            end

            V = (ref_low >> 8) & ((32'd1 << (24 - ref_bits_left)) - 1);
            if (ref_bits_left >= 17) begin
                P         = ref_bits_left - 17;
                final_val = (V << (P + 1)) | (24'd1 << P);
                push_expected_byte(final_val[7:0]);
            end else if (ref_bits_left >= 9) begin
                P         = ref_bits_left - 9;
                final_val = (V << (P + 1)) | (24'd1 << P);
                push_expected_byte(final_val[15:8]);
                push_expected_byte(final_val[7:0]);
            end else begin
                P         = ref_bits_left - 1;
                final_val = (V << (P + 1)) | (24'd1 << P);
                push_expected_byte(final_val[23:16]);
                push_expected_byte(final_val[15:8]);
                push_expected_byte(final_val[7:0]);
            end

            // Hardware resets M-coder state on flush completion
            ref_init();
        endfunction

        virtual function void write_in(cabac_item t);
            case (t.op_type)
                OP_INIT: begin
                    total_inits++;
                    if (expected_byte_q.size() != 0) begin
                        `uvm_error("CABAC_SB", $sformatf(
                            "OP_INIT arrived with %0d unconsumed expected bytes in queue!",
                            expected_byte_q.size()))
                        expected_byte_q.delete();
                    end
                    ref_init();
                end
                OP_REG_BIN: begin
                    total_reg_bins++;
                    total_bins_coded++;
                    ref_encode_bin(t.bin_val, t.pstate, t.valmps);
                end
                OP_EP_BIN: begin
                    total_ep_bins++;
                    total_bins_coded++;
                    ref_encode_ep(t.bin_val);
                end
                OP_TRM_BIN: begin
                    total_trm_bins++;
                    total_bins_coded++;
                    ref_encode_trm(t.bin_val);
                end
                OP_FLUSH: begin
                    total_flushes++;
                    ref_flush();
                end
                default: begin
                    `uvm_error("CABAC_SB", $sformatf("Unknown input op_type: %0d", t.op_type))
                end
            endcase
        endfunction

        virtual function void write_out(cabac_byte_item t);
            bit [7:0] exp_b;
            if (!t.is_flush_marker) begin
                total_bytes_received++;
                if (expected_byte_q.size() == 0) begin
                    byte_mismatches++;
                    `uvm_error("CABAC_SB", $sformatf(
                        "Byte #%0d unexpected: DUT emitted 0x%02x when expected queue is empty",
                        total_bytes_received, t.byte_data))
                end else begin
                    exp_b = expected_byte_q.pop_front();
                    if (t.byte_data !== exp_b) begin
                        byte_mismatches++;
                        `uvm_error("CABAC_SB", $sformatf(
                            "Byte #%0d mismatch: DUT=0x%02x, EXP=0x%02x",
                            total_bytes_received, t.byte_data, exp_b))
                    end
                end
            end else begin
                if (expected_byte_q.size() != 0) begin
                    flush_mismatches++;
                    `uvm_error("CABAC_SB", $sformatf(
                        "flush_done observed, but %0d expected bytes still remaining in queue!",
                        expected_byte_q.size()))
                    expected_byte_q.delete();
                end
            end
        endfunction

        virtual function void check_phase(uvm_phase phase);
            super.check_phase(phase);
            if (expected_byte_q.size() != 0) begin
                `uvm_error("CABAC_SB", $sformatf(
                    "End of simulation with %0d unverified bytes remaining in expected queue!",
                    expected_byte_q.size()))
            end
        endfunction

        virtual function void report_phase(uvm_phase phase);
            super.report_phase(phase);
            `uvm_info("CABAC_SB", $sformatf({
                "\n==========================================================\n",
                " CABAC M-CODER SCOREBOARD SUMMARY (HM 18.0 Bit-Exact)\n",
                "----------------------------------------------------------\n",
                "  Slice Inits        : %0d\n",
                "  Regular Bins       : %0d\n",
                "  EP Bypass Bins     : %0d\n",
                "  Terminating Bins   : %0d\n",
                "  Total Bins Coded   : %0d\n",
                "  Flushes Completed  : %0d\n",
                "  Bytes Expected     : %0d\n",
                "  Bytes Received     : %0d\n",
                "  Byte Mismatches    : %0d\n",
                "  Flush Mismatches   : %0d\n",
                "  Remaining Bytes    : %0d\n",
                "  Max Buffered 0xFFs : %0d\n",
                "  Carry Ripples (>1) : %0d\n",
                "  Non-Carry FFs (>1) : %0d\n",
                "=========================================================="},
                total_inits, total_reg_bins, total_ep_bins, total_trm_bins,
                total_bins_coded, total_flushes, total_bytes_expected,
                total_bytes_received, byte_mismatches, flush_mismatches,
                expected_byte_q.size(), max_num_ff_seen,
                carry_ripple_events, noncarry_ff_events), UVM_LOW)
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Functional Coverage Collector
    // -------------------------------------------------------------------------
    class cabac_coverage extends uvm_subscriber #(cabac_item);
        `uvm_component_utils(cabac_coverage)

        virtual cabac_if vif;

        cabac_op_e cov_op;
        bit [5:0]  cov_pstate;
        bit        cov_is_lps;
        bit        cov_byte_ready;

        covergroup cg_cabac;
            option.per_instance = 1;

            cp_op: coverpoint cov_op {
                bins op_init    = {OP_INIT};
                bins op_reg_bin = {OP_REG_BIN};
                bins op_ep_bin  = {OP_EP_BIN};
                bins op_trm_bin = {OP_TRM_BIN};
                bins op_flush   = {OP_FLUSH};
            }

            cp_pstate: coverpoint cov_pstate iff (cov_op == OP_REG_BIN) {
                bins ps[64] = {[0:63]};
            }

            cp_mps_lps: coverpoint cov_is_lps iff (cov_op == OP_REG_BIN) {
                bins mps = {1'b0};
                bins lps = {1'b1};
            }

            cp_backpressure: coverpoint cov_byte_ready {
                bins bp_stall = {1'b0};
                bins bp_ready = {1'b1};
            }

            cx_pstate_mps_lps: cross cp_pstate, cp_mps_lps iff (cov_op == OP_REG_BIN);
        endgroup

        function new(string name = "cabac_coverage", uvm_component parent = null);
            super.new(name, parent);
            cg_cabac = new();
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual cabac_if)::get(this, "", "vif", vif)) begin
                `uvm_warning("CABAC_COV", "Virtual interface 'vif' not found; bp coverage defaults to 1")
            end
        endfunction

        virtual function void write(cabac_item t);
            cov_op         = t.op_type;
            cov_pstate     = t.pstate;
            cov_is_lps     = (t.bin_val != t.valmps);
            cov_byte_ready = (vif != null) ? vif.byte_ready : 1'b1;
            cg_cabac.sample();
        endfunction

        virtual function real get_coverage_pct();
            return cg_cabac.get_inst_coverage();
        endfunction

        virtual function void report_phase(uvm_phase phase);
            super.report_phase(phase);
            `uvm_info("CABAC_COV", $sformatf({
                "\n----------------------------------------------------------\n",
                " CABAC FUNCTIONAL COVERAGE (cg_cabac)\n",
                "  Overall cg_cabac     : %0.2f%%\n",
                "  cp_op                : %0.2f%%\n",
                "  cp_pstate            : %0.2f%%\n",
                "  cp_mps_lps           : %0.2f%%\n",
                "  cp_backpressure      : %0.2f%%\n",
                "  cx_pstate_mps_lps    : %0.2f%%\n",
                "----------------------------------------------------------"},
                cg_cabac.get_inst_coverage(),
                cg_cabac.cp_op.get_inst_coverage(),
                cg_cabac.cp_pstate.get_inst_coverage(),
                cg_cabac.cp_mps_lps.get_inst_coverage(),
                cg_cabac.cp_backpressure.get_inst_coverage(),
                cg_cabac.cx_pstate_mps_lps.get_inst_coverage()), UVM_LOW)
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Environment
    // -------------------------------------------------------------------------
    class cabac_env extends uvm_env;
        `uvm_component_utils(cabac_env)

        cabac_agent      agent;
        cabac_scoreboard scoreboard;
        cabac_coverage   coverage;

        function new(string name = "cabac_env", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent      = cabac_agent::type_id::create("agent", this);
            scoreboard = cabac_scoreboard::type_id::create("scoreboard", this);
            coverage   = cabac_coverage::type_id::create("coverage", this);
        endfunction

        virtual function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            agent.monitor.ap_in.connect(scoreboard.in_imp);
            agent.monitor.ap_in.connect(coverage.analysis_export);
            agent.monitor.ap_out.connect(scoreboard.out_imp);
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Base Sequence Helper
    // -------------------------------------------------------------------------
    class cabac_base_seq extends uvm_sequence #(cabac_item);
        `uvm_object_utils(cabac_base_seq)

        function new(string name = "cabac_base_seq");
            super.new(name);
        endfunction

        protected task send_op(
            cabac_op_e    op,
            bit           bval   = 1'b0,
            bit [5:0]     ps     = 6'd0,
            bit           vmps   = 1'b0,
            bit [7:0]     cid    = 8'd0,
            int unsigned  delay  = 0
        );
            cabac_item tr = cabac_item::type_id::create("tr");
            start_item(tr);
            tr.op_type   = op;
            tr.bin_val   = bval;
            tr.pstate    = ps;
            tr.valmps    = vmps;
            tr.ctx_id    = cid;
            tr.pre_delay = delay;
            finish_item(tr);
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Sequence 1: Multi-Byte 0xFF Carry Buffering & Ripple Stress
    // -------------------------------------------------------------------------
    class cabac_carry_ripple_seq extends cabac_base_seq;
        `uvm_object_utils(cabac_carry_ripple_seq)

        function new(string name = "cabac_carry_ripple_seq");
            super.new(name);
        endfunction

        virtual task body();
            int i, g;
            `uvm_info("CABAC_SEQ", "Starting cabac_carry_ripple_seq (0xFF buffering + carry ripple under backpressure)", UVM_LOW)

            // Slice A: Force 7 consecutive 0xFF bytes buffered, then push carry=1 ripple -> 0x00 burst
            send_op(OP_INIT);
            // Prefix [0,0,0,0] puts low remainder inside (0, range) boundary
            for (i = 0; i < 4; i++) send_op(OP_EP_BIN, 1'b0);
            // 7 groups of [1,0,0,0,0,0,0,0] lock lead_byte=0xFF each byte while 0 < D < range
            for (g = 0; g < 7; g++) begin
                send_op(OP_EP_BIN, 1'b1);
                for (i = 0; i < 7; i++) send_op(OP_EP_BIN, 1'b0);
            end
            // Push across 0x100 boundary to ripple carry through all 7 buffered bytes
            for (i = 0; i < 12; i++) send_op(OP_EP_BIN, 1'b1);
            send_op(OP_TRM_BIN, 1'b1);
            send_op(OP_FLUSH);

            // Slice B: Force 6 consecutive 0xFF bytes buffered, then resolve with carry=0 -> 0xFF burst
            send_op(OP_INIT);
            for (i = 0; i < 4; i++) send_op(OP_EP_BIN, 1'b0);
            for (g = 0; g < 6; g++) begin
                send_op(OP_EP_BIN, 1'b1);
                for (i = 0; i < 7; i++) send_op(OP_EP_BIN, 1'b0);
            end
            // Resolve downwards without carry
            for (i = 0; i < 12; i++) send_op(OP_EP_BIN, 1'b0);
            send_op(OP_TRM_BIN, 1'b1);
            send_op(OP_FLUSH);

            // Slice C: Force 5 consecutive 0xFF bytes resolved with carry=0 inside S_FLUSH_1 / S_FLUSH_2 (bits_left=19)
            send_op(OP_INIT);
            for (i = 0; i < 4; i++) send_op(OP_EP_BIN, 1'b0);
            for (g = 0; g < 5; g++) begin
                send_op(OP_EP_BIN, 1'b1);
                for (i = 0; i < 7; i++) send_op(OP_EP_BIN, 1'b0);
            end
            send_op(OP_FLUSH);

            // Slice D: Force 5 consecutive 0xFF bytes resolved with carry=1 inside S_FLUSH_1 / S_FLUSH_2 (bits_left=14, 2-byte flush)
            send_op(OP_INIT);
            for (i = 0; i < 4; i++) send_op(OP_EP_BIN, 1'b0);
            for (g = 0; g < 5; g++) begin
                send_op(OP_EP_BIN, 1'b1);
                for (i = 0; i < 7; i++) send_op(OP_EP_BIN, 1'b0);
            end
            for (i = 0; i < 5; i++) send_op(OP_EP_BIN, 1'b1);
            send_op(OP_FLUSH);

            // Slice E: Short slice where num_ff == 0 on entry to S_FLUSH_1
            send_op(OP_INIT);
            send_op(OP_REG_BIN, 1'b0, 6'd10, 1'b0, 8'd0, 0);
            send_op(OP_FLUSH);
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Sequence 2: Extreme Low-Probability LPS Bursts & Terminating Bins
    // -------------------------------------------------------------------------
    class cabac_lps_extreme_seq extends cabac_base_seq;
        `uvm_object_utils(cabac_lps_extreme_seq)

        function new(string name = "cabac_lps_extreme_seq");
            super.new(name);
        endfunction

        virtual task body();
            int i;
            `uvm_info("CABAC_SEQ", "Starting cabac_lps_extreme_seq (pstate=62,63 LPS bursts + TRM(0)/TRM(1)/FLUSH)", UVM_LOW)

            // Slice 1: Back-to-back pstate=63 LPS (lps_val=2, 7-bit renorm) + TRM(0) + TRM(1)
            send_op(OP_INIT);
            for (i = 0; i < 24; i++) begin
                // Alternating valmps, bin_val != valmps => LPS
                send_op(OP_REG_BIN, ~i[0], 6'd63, i[0], 8'(i & 8'hFF), 0);
            end
            for (i = 0; i < 16; i++) begin
                send_op(OP_REG_BIN, ~i[0], 6'd62, i[0], 8'((i + 32) & 8'hFF), 0);
            end
            // Repeated encodeBinTrm(0) exercises both renorm and non-renorm paths (256->508->506->...)
            for (i = 0; i < 6; i++) begin
                send_op(OP_TRM_BIN, 1'b0, 6'd0, 1'b0, 8'd0, (i % 2));
            end
            // Terminating bin=1 forces range=256 and 7-bit low shift
            send_op(OP_TRM_BIN, 1'b1);
            send_op(OP_FLUSH);

            // Slice 2: Mixed pstate=62/63 MPS/LPS with pre_delays 0..2, immediate TRM(1) + FLUSH
            send_op(OP_INIT);
            for (i = 0; i < 20; i++) begin
                bit [5:0] ps   = (i[0]) ? 6'd63 : 6'd62;
                bit       vmps = i[1];
                bit       bval = (i % 3 == 0) ? vmps : ~vmps; // 2/3 LPS, 1/3 MPS
                send_op(OP_REG_BIN, bval, ps, vmps, 8'(i), (i % 3));
            end
            send_op(OP_TRM_BIN, 1'b0);
            send_op(OP_TRM_BIN, 1'b1);
            send_op(OP_FLUSH);
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Sequence 3: 5,500+ Constrained-Random Bins Across Multiple Slices
    // -------------------------------------------------------------------------
    class cabac_random_stress_seq extends cabac_base_seq;
        `uvm_object_utils(cabac_random_stress_seq)

        int unsigned num_slices      = 10;
        int unsigned bins_per_slice  = 550;

        function new(string name = "cabac_random_stress_seq");
            super.new(name);
        endfunction

        virtual task body();
            cabac_item tr;
            int        idx_list[128];
            int        tmp, j;

            `uvm_info("CABAC_SEQ", $sformatf(
                "Starting cabac_random_stress_seq (%0d slices x %0d bins + 128-point pstate x MPS/LPS sweep)",
                num_slices, bins_per_slice), UVM_LOW)

            // Slice 0: Shuffled sweep over all 64 pstates x {MPS, LPS} + random EP/TRM/FLUSH
            for (int k = 0; k < 128; k++) idx_list[k] = k;
            for (int k = 127; k > 0; k--) begin
                j = $urandom_range(0, k);
                tmp = idx_list[k];
                idx_list[k] = idx_list[j];
                idx_list[j] = tmp;
            end

            send_op(OP_INIT);
            for (int k = 0; k < 128; k++) begin
                bit [5:0] ps     = idx_list[k] >> 1;
                bit       is_lps = idx_list[k] & 1;
                bit       vmps   = $urandom_range(0, 1);
                tr = cabac_item::type_id::create("tr");
                start_item(tr);
                if (!tr.randomize() with {
                    op_type   == OP_REG_BIN;
                    pstate    == local::ps;
                    valmps    == local::vmps;
                    bin_val   == (local::is_lps ? ~local::vmps : local::vmps);
                    pre_delay dist {0 := 70, 1 := 20, 2 := 10};
                }) `uvm_fatal("CABAC_SEQ", "Randomization failed in pstate sweep")
                finish_item(tr);
            end
            send_op(OP_TRM_BIN, 1'b1);
            send_op(OP_FLUSH);

            // Slices 1..num_slices: pure constrained-random bins (REG 88% + EP 11% + TRM(0) 1%)
            for (int s = 0; s < int'(num_slices); s++) begin
                send_op(OP_INIT);
                for (int b = 0; b < int'(bins_per_slice); b++) begin
                    int        op_roll    = $urandom_range(0, 99);
                    int        delay_roll = $urandom_range(0, 99);
                    cabac_op_e chosen_op  = (op_roll < 88) ? OP_REG_BIN :
                                            ((op_roll < 99) ? OP_EP_BIN : OP_TRM_BIN);
                    int unsigned chosen_delay = (delay_roll < 75) ? 0 :
                                                ((delay_roll < 90) ? 1 : 2);
                    tr = cabac_item::type_id::create("tr");
                    start_item(tr);
                    if (!tr.randomize() with {
                        op_type   == local::chosen_op;
                        pre_delay == local::chosen_delay;
                        (op_type == OP_TRM_BIN) -> (bin_val == 1'b0);
                    }) `uvm_fatal("CABAC_SEQ", "Randomization failed in stress slice")
                    finish_item(tr);
                end
                send_op(OP_TRM_BIN, 1'b1);
                send_op(OP_FLUSH);
            end
        endtask
    endclass

    // -------------------------------------------------------------------------
    // UVM Test: Executes all 3 sequences & enforces coverage/error gates
    // -------------------------------------------------------------------------
    class cabac_uvm_test extends uvm_test;
        `uvm_component_utils(cabac_uvm_test)

        cabac_env env;

        function new(string name = "cabac_uvm_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            uvm_config_db#(int unsigned)::set(this, "env.agent.sink_driver", "stall_pct", 25);
            uvm_config_db#(bit)::set(this, "env.agent.sink_driver", "enable_backpressure", 1'b1);
            env = cabac_env::type_id::create("env", this);
        endfunction

        virtual task run_phase(uvm_phase phase);
            cabac_carry_ripple_seq carry_seq;
            cabac_lps_extreme_seq  lps_seq;
            cabac_random_stress_seq rand_seq;

            phase.raise_objection(this);

            // 1. Carry-ripple sequence under heavier stall pressure (40%)
            env.agent.sink_driver.stall_pct = 40;
            carry_seq = cabac_carry_ripple_seq::type_id::create("carry_seq");
            carry_seq.start(env.agent.sequencer);

            // 2. Extreme pstate=62/63 LPS + TRM(0)/TRM(1) sequence (30% stall)
            env.agent.sink_driver.stall_pct = 30;
            lps_seq = cabac_lps_extreme_seq::type_id::create("lps_seq");
            lps_seq.start(env.agent.sequencer);

            // 3. 5,500+ constrained-random bins across 11 slices (25% stall)
            env.agent.sink_driver.stall_pct = 25;
            rand_seq = cabac_random_stress_seq::type_id::create("rand_seq");
            rand_seq.start(env.agent.sequencer);

            phase.drop_objection(this);
        endtask

        virtual function void check_phase(uvm_phase phase);
            real cov_pct;
            super.check_phase(phase);

            cov_pct = env.coverage.get_coverage_pct();

            if (env.scoreboard.total_bins_coded < 5000) begin
                `uvm_error("CABAC_TEST", $sformatf(
                    "Insufficient bins coded: %0d < 5000 required", env.scoreboard.total_bins_coded))
            end
            if (env.scoreboard.byte_mismatches != 0 || env.scoreboard.flush_mismatches != 0) begin
                `uvm_error("CABAC_TEST", $sformatf(
                    "Scoreboard detected mismatches: byte=%0d flush=%0d",
                    env.scoreboard.byte_mismatches, env.scoreboard.flush_mismatches))
            end
            if (env.scoreboard.carry_ripple_events == 0) begin
                `uvm_error("CABAC_TEST", "No multi-byte 0xFF carry-ripple events were triggered!")
            end
            if (env.agent.monitor.byte_stall_cycles == 0) begin
                `uvm_error("CABAC_TEST", "No byte_valid && !byte_ready backpressure stall cycles observed!")
            end
            if (cov_pct < 95.0) begin
                `uvm_error("CABAC_TEST", $sformatf(
                    "Functional coverage %0.2f%% is below required 95.0%%", cov_pct))
            end
        endfunction

        virtual function void report_phase(uvm_phase phase);
            super.report_phase(phase);
            `uvm_info("CABAC_TEST", $sformatf(
                "Backpressure observed: %0d byte_valid stall cycles out of %0d byte_valid cycles",
                env.agent.monitor.byte_stall_cycles, env.agent.monitor.byte_valid_cycles), UVM_LOW)
        endfunction
    endclass

endpackage
