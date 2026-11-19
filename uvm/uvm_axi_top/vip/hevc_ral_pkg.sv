`timescale 1ns / 1ps
//=============================================================================
// hevc_ral_pkg.sv
// UVM Register Abstraction Layer (RAL) & AXI4-Lite Transaction / Adapter
// for hevc_encoder_axi_top
//=============================================================================

package hevc_ral_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    //=========================================================================
    // AXI4-Lite Bus Transaction
    //=========================================================================
    class axi_lite_txn extends uvm_sequence_item;
        rand bit        is_write;
        rand bit [11:0] addr;
        rand bit [31:0] data;
        rand bit [3:0]  wstrb;
        bit [1:0]       resp;

        constraint c_wstrb_default { wstrb == 4'hF; }
        constraint c_addr_align    { addr[1:0] == 2'b00; }

        `uvm_object_utils_begin(axi_lite_txn)
            `uvm_field_int(is_write, UVM_ALL_ON)
            `uvm_field_int(addr,     UVM_ALL_ON)
            `uvm_field_int(data,     UVM_ALL_ON)
            `uvm_field_int(wstrb,    UVM_ALL_ON)
            `uvm_field_int(resp,     UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "axi_lite_txn");
            super.new(name);
            wstrb = 4'hF;
        endfunction

        virtual function string convert2string();
            return $sformatf("%s addr=0x%03h data=0x%08h wstrb=0x%01h resp=%0b",
                             is_write ? "WR" : "RD", addr, data, wstrb, resp);
        endfunction
    endclass

    //=========================================================================
    // UVM RAL <-> AXI4-Lite Adapter
    //=========================================================================
    class reg2axi_lite_adapter extends uvm_reg_adapter;
        `uvm_object_utils(reg2axi_lite_adapter)

        function new(string name = "reg2axi_lite_adapter");
            super.new(name);
            supports_byte_enable = 1;
            provides_responses    = 0;
        endfunction

        virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
            axi_lite_txn txn = axi_lite_txn::type_id::create("txn");
            txn.is_write = (rw.kind == UVM_WRITE || rw.kind == UVM_BURST_WRITE);
            txn.addr     = rw.addr[11:0];
            txn.data     = rw.data[31:0];
            txn.wstrb    = (rw.byte_en[3:0] != 4'h0) ? rw.byte_en[3:0] : 4'hF;
            return txn;
        endfunction

        virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
            axi_lite_txn txn;
            if (!$cast(txn, bus_item)) begin
                `uvm_fatal("REG2AXI_ADAPTER", "bus_item is not of type axi_lite_txn")
                return;
            end
            rw.kind    = txn.is_write ? UVM_WRITE : UVM_READ;
            rw.addr    = {20'd0, txn.addr};
            rw.data    = {32'd0, txn.data};
            rw.byte_en = txn.wstrb;
            rw.status  = (txn.resp == 2'b00) ? UVM_IS_OK : UVM_NOT_OK;
        endfunction
    endclass

    //=========================================================================
    // 0x00: CTRL (RW) - start[0] (self-clearing pulse, volatile), soft_rst[1], irq_en[2]
    //=========================================================================
    class hevc_ctrl_reg extends uvm_reg;
        `uvm_object_utils(hevc_ctrl_reg)

        rand uvm_reg_field start;
        rand uvm_reg_field soft_rst;
        rand uvm_reg_field irq_en;

        function new(string name = "hevc_ctrl_reg");
            super.new(name, 32, UVM_NO_COVERAGE);
        endfunction

        virtual function void build();
            start    = uvm_reg_field::type_id::create("start");
            soft_rst = uvm_reg_field::type_id::create("soft_rst");
            irq_en   = uvm_reg_field::type_id::create("irq_en");

            // start is a self-clearing single-cycle pulse in RTL (always reads 0)
            start.configure   (this, 1, 0, "RW", 1, 1'b0, 1, 1, 0);
            soft_rst.configure(this, 1, 1, "RW", 0, 1'b0, 1, 1, 0);
            irq_en.configure  (this, 1, 2, "RW", 0, 1'b0, 1, 1, 0);
        endfunction
    endclass

    //=========================================================================
    // 0x04: STATUS (RO, volatile, reset 32'h4) - done[0], busy[1], ready[2]
    //=========================================================================
    class hevc_status_reg extends uvm_reg;
        `uvm_object_utils(hevc_status_reg)

        rand uvm_reg_field done;
        rand uvm_reg_field busy;
        rand uvm_reg_field ready;

        function new(string name = "hevc_status_reg");
            super.new(name, 32, UVM_NO_COVERAGE);
        endfunction

        virtual function void build();
            done  = uvm_reg_field::type_id::create("done");
            busy  = uvm_reg_field::type_id::create("busy");
            ready = uvm_reg_field::type_id::create("ready");

            done.configure (this, 1, 0, "RO", 1, 1'b0, 1, 0, 0);
            busy.configure (this, 1, 1, "RO", 1, 1'b0, 1, 0, 0);
            ready.configure(this, 1, 2, "RO", 1, 1'b1, 1, 0, 0);
        endfunction
    endclass

    //=========================================================================
    // 0x08: IRQ_STATUS (W1C, volatile, reset 32'h0) - irq_status[0]
    //=========================================================================
    class hevc_irq_status_reg extends uvm_reg;
        `uvm_object_utils(hevc_irq_status_reg)

        rand uvm_reg_field irq_status;

        function new(string name = "hevc_irq_status_reg");
            super.new(name, 32, UVM_NO_COVERAGE);
        endfunction

        virtual function void build();
            irq_status = uvm_reg_field::type_id::create("irq_status");
            irq_status.configure(this, 1, 0, "W1C", 1, 1'b0, 1, 1, 0);
        endfunction
    endclass

    //=========================================================================
    // 0x0C: TOTAL_FRAMES (RW, reset 32'h1) - total_frames[15:0]
    //=========================================================================
    class hevc_total_frames_reg extends uvm_reg;
        `uvm_object_utils(hevc_total_frames_reg)

        rand uvm_reg_field total_frames;

        function new(string name = "hevc_total_frames_reg");
            super.new(name, 32, UVM_NO_COVERAGE);
        endfunction

        virtual function void build();
            total_frames = uvm_reg_field::type_id::create("total_frames");
            total_frames.configure(this, 16, 0, "RW", 0, 16'd1, 1, 1, 0);
        endfunction
    endclass

    //=========================================================================
    // 0x10: BASE_QP (RW, reset 32'd28) - base_qp[5:0]
    //=========================================================================
    class hevc_base_qp_reg extends uvm_reg;
        `uvm_object_utils(hevc_base_qp_reg)

        rand uvm_reg_field base_qp;
        bit [5:0]          reset_val = 6'd28;

        function new(string name = "hevc_base_qp_reg");
            super.new(name, 32, UVM_NO_COVERAGE);
        endfunction

        virtual function void build();
            base_qp = uvm_reg_field::type_id::create("base_qp");
            base_qp.configure(this, 6, 0, "RW", 0, reset_val, 1, 1, 0);
        endfunction
    endclass

    //=========================================================================
    // 0x14: GOP_STRUCTURE (RW, reset 32'd0) - gop_structure[1:0]
    //=========================================================================
    class hevc_gop_structure_reg extends uvm_reg;
        `uvm_object_utils(hevc_gop_structure_reg)

        rand uvm_reg_field gop_structure;
        bit [1:0]          reset_val = 2'd0;

        function new(string name = "hevc_gop_structure_reg");
            super.new(name, 32, UVM_NO_COVERAGE);
        endfunction

        virtual function void build();
            gop_structure = uvm_reg_field::type_id::create("gop_structure");
            gop_structure.configure(this, 2, 0, "RW", 0, reset_val, 1, 1, 0);
        endfunction
    endclass

    //=========================================================================
    // 0x18: TARGET_BITRATE (RW, reset 32'd5000) - target_bitrate[15:0]
    //=========================================================================
    class hevc_target_bitrate_reg extends uvm_reg;
        `uvm_object_utils(hevc_target_bitrate_reg)

        rand uvm_reg_field target_bitrate;
        bit [15:0]         reset_val = 16'd5000;

        function new(string name = "hevc_target_bitrate_reg");
            super.new(name, 32, UVM_NO_COVERAGE);
        endfunction

        virtual function void build();
            target_bitrate = uvm_reg_field::type_id::create("target_bitrate");
            target_bitrate.configure(this, 16, 0, "RW", 0, reset_val, 1, 1, 0);
        endfunction
    endclass

    //=========================================================================
    // 0x1C: MAGIC_ID (RO, reset 32'h48455643)
    // Note: In RTL, writes to 0x1C modify internal reg_rc_enable[0] and
    // reg_sao_enable[1], while reads always return 32'h48455643 ("HEVC").
    // Modeled as RO with reset 32'h48455643 for RAL audit/mirror checks.
    //=========================================================================
    class hevc_magic_id_reg extends uvm_reg;
        `uvm_object_utils(hevc_magic_id_reg)

        rand uvm_reg_field magic_id;

        function new(string name = "hevc_magic_id_reg");
            super.new(name, 32, UVM_NO_COVERAGE);
        endfunction

        virtual function void build();
            magic_id = uvm_reg_field::type_id::create("magic_id");
            magic_id.configure(this, 32, 0, "RO", 0, 32'h48455643, 1, 0, 0);
        endfunction
    endclass

    //=========================================================================
    // 0x20: RESOLUTION (RO, reset 32'h00400040) - width[31:16], height[15:0]
    //=========================================================================
    class hevc_resolution_reg extends uvm_reg;
        `uvm_object_utils(hevc_resolution_reg)

        rand uvm_reg_field height;
        rand uvm_reg_field width;
        bit [15:0]         reset_width  = 16'd64;
        bit [15:0]         reset_height = 16'd64;

        function new(string name = "hevc_resolution_reg");
            super.new(name, 32, UVM_NO_COVERAGE);
        endfunction

        virtual function void build();
            height = uvm_reg_field::type_id::create("height");
            width  = uvm_reg_field::type_id::create("width");

            height.configure(this, 16, 0,  "RO", 0, reset_height, 1, 0, 0);
            width.configure (this, 16, 16, "RO", 0, reset_width,  1, 0, 0);
        endfunction
    endclass

    //=========================================================================
    // 0x24: VBV_FULLNESS (RO, volatile, reset 32'h0) - vbv_pct[15:0]
    //=========================================================================
    class hevc_vbv_fullness_reg extends uvm_reg;
        `uvm_object_utils(hevc_vbv_fullness_reg)

        rand uvm_reg_field vbv_pct;

        function new(string name = "hevc_vbv_fullness_reg");
            super.new(name, 32, UVM_NO_COVERAGE);
        endfunction

        virtual function void build();
            vbv_pct = uvm_reg_field::type_id::create("vbv_pct");
            vbv_pct.configure(this, 16, 0, "RO", 1, 16'd0, 1, 0, 0);
        endfunction
    endclass

    //=========================================================================
    // Top-Level HEVC Encoder Register Block
    //=========================================================================
    class hevc_reg_block extends uvm_reg_block;
        `uvm_object_utils(hevc_reg_block)

        rand hevc_ctrl_reg           CTRL;
        rand hevc_status_reg         STATUS;
        rand hevc_irq_status_reg     IRQ_STATUS;
        rand hevc_total_frames_reg   TOTAL_FRAMES;
        rand hevc_base_qp_reg        BASE_QP;
        rand hevc_gop_structure_reg  GOP_STRUCTURE;
        rand hevc_target_bitrate_reg TARGET_BITRATE;
        rand hevc_magic_id_reg       MAGIC_ID;
        rand hevc_resolution_reg     RESOLUTION;
        rand hevc_vbv_fullness_reg   VBV_FULLNESS;

        bit [15:0] cfg_frame_width         = 16'd64;
        bit [15:0] cfg_frame_height        = 16'd64;
        bit [5:0]  cfg_base_qp             = 6'd28;
        bit [1:0]  cfg_gop_structure       = 2'd0;
        bit [15:0] cfg_target_bitrate_kbps = 16'd5000;

        uvm_reg_map default_map;

        function new(string name = "hevc_reg_block");
            super.new(name, UVM_NO_COVERAGE);
        endfunction

        virtual function void set_default_params(
            bit [15:0] frame_width         = 16'd64,
            bit [15:0] frame_height        = 16'd64,
            bit [5:0]  base_qp             = 6'd28,
            bit [1:0]  gop_structure       = 2'd0,
            bit [15:0] target_bitrate_kbps = 16'd5000
        );
            cfg_frame_width         = frame_width;
            cfg_frame_height        = frame_height;
            cfg_base_qp             = base_qp;
            cfg_gop_structure       = gop_structure;
            cfg_target_bitrate_kbps = target_bitrate_kbps;
        endfunction

        virtual function void build();
            CTRL           = hevc_ctrl_reg::type_id::create("CTRL");
            STATUS         = hevc_status_reg::type_id::create("STATUS");
            IRQ_STATUS     = hevc_irq_status_reg::type_id::create("IRQ_STATUS");
            TOTAL_FRAMES   = hevc_total_frames_reg::type_id::create("TOTAL_FRAMES");
            BASE_QP        = hevc_base_qp_reg::type_id::create("BASE_QP");
            GOP_STRUCTURE  = hevc_gop_structure_reg::type_id::create("GOP_STRUCTURE");
            TARGET_BITRATE = hevc_target_bitrate_reg::type_id::create("TARGET_BITRATE");
            MAGIC_ID       = hevc_magic_id_reg::type_id::create("MAGIC_ID");
            RESOLUTION     = hevc_resolution_reg::type_id::create("RESOLUTION");
            VBV_FULLNESS   = hevc_vbv_fullness_reg::type_id::create("VBV_FULLNESS");

            BASE_QP.reset_val        = cfg_base_qp;
            GOP_STRUCTURE.reset_val  = cfg_gop_structure;
            TARGET_BITRATE.reset_val = cfg_target_bitrate_kbps;
            RESOLUTION.reset_width   = cfg_frame_width;
            RESOLUTION.reset_height  = cfg_frame_height;

            CTRL.configure          (this); CTRL.build();
            STATUS.configure        (this); STATUS.build();
            IRQ_STATUS.configure    (this); IRQ_STATUS.build();
            TOTAL_FRAMES.configure  (this); TOTAL_FRAMES.build();
            BASE_QP.configure       (this); BASE_QP.build();
            GOP_STRUCTURE.configure (this); GOP_STRUCTURE.build();
            TARGET_BITRATE.configure(this); TARGET_BITRATE.build();
            MAGIC_ID.configure      (this); MAGIC_ID.build();
            RESOLUTION.configure    (this); RESOLUTION.build();
            VBV_FULLNESS.configure  (this); VBV_FULLNESS.build();

            default_map = create_map("default_map", 'h0, 4, UVM_LITTLE_ENDIAN);
            default_map.add_reg(CTRL,           'h00, "RW");
            default_map.add_reg(STATUS,         'h04, "RO");
            default_map.add_reg(IRQ_STATUS,     'h08, "RW");
            default_map.add_reg(TOTAL_FRAMES,   'h0C, "RW");
            default_map.add_reg(BASE_QP,        'h10, "RW");
            default_map.add_reg(GOP_STRUCTURE,  'h14, "RW");
            default_map.add_reg(TARGET_BITRATE, 'h18, "RW");
            default_map.add_reg(MAGIC_ID,       'h1C, "RO");
            default_map.add_reg(RESOLUTION,     'h20, "RO");
            default_map.add_reg(VBV_FULLNESS,   'h24, "RO");

            lock_model();
        endfunction
    endclass

endpackage
