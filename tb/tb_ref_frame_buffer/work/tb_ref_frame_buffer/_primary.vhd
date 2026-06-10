library verilog;
use verilog.vl_types.all;
entity tb_ref_frame_buffer is
    generic(
        PIXEL_WIDTH     : integer := 10;
        BLK_SIZE        : integer := 4;
        BLK_EXT_Y       : integer := 11;
        BLK_EXT_C       : integer := 5;
        FRAME_W_Y       : integer := 64;
        FRAME_H_Y       : integer := 64;
        FRAME_W_C       : integer := 32;
        FRAME_H_C       : integer := 32;
        AXI_DW          : integer := 256;
        AXI_AW          : integer := 33;
        PX_EXT_Y        : vl_notype;
        PX_EXT_C        : vl_notype
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of PIXEL_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of BLK_SIZE : constant is 1;
    attribute mti_svvh_generic_type of BLK_EXT_Y : constant is 1;
    attribute mti_svvh_generic_type of BLK_EXT_C : constant is 1;
    attribute mti_svvh_generic_type of FRAME_W_Y : constant is 1;
    attribute mti_svvh_generic_type of FRAME_H_Y : constant is 1;
    attribute mti_svvh_generic_type of FRAME_W_C : constant is 1;
    attribute mti_svvh_generic_type of FRAME_H_C : constant is 1;
    attribute mti_svvh_generic_type of AXI_DW : constant is 1;
    attribute mti_svvh_generic_type of AXI_AW : constant is 1;
    attribute mti_svvh_generic_type of PX_EXT_Y : constant is 3;
    attribute mti_svvh_generic_type of PX_EXT_C : constant is 3;
end tb_ref_frame_buffer;
