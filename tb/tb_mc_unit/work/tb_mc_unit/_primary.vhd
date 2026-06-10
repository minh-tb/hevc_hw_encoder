library verilog;
use verilog.vl_types.all;
entity tb_mc_unit is
    generic(
        BLK_SIZE        : integer := 4;
        BLK_C           : integer := 2;
        BLK_EXT_Y       : integer := 11;
        BLK_EXT_C       : integer := 5;
        PX_Y            : vl_notype;
        PX_C            : vl_notype;
        PX_EXT_Y        : vl_notype;
        PX_EXT_C        : vl_notype
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of BLK_SIZE : constant is 1;
    attribute mti_svvh_generic_type of BLK_C : constant is 1;
    attribute mti_svvh_generic_type of BLK_EXT_Y : constant is 1;
    attribute mti_svvh_generic_type of BLK_EXT_C : constant is 1;
    attribute mti_svvh_generic_type of PX_Y : constant is 3;
    attribute mti_svvh_generic_type of PX_C : constant is 3;
    attribute mti_svvh_generic_type of PX_EXT_Y : constant is 3;
    attribute mti_svvh_generic_type of PX_EXT_C : constant is 3;
end tb_mc_unit;
