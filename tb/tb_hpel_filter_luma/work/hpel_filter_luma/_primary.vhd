library verilog;
use verilog.vl_types.all;
entity hpel_filter_luma is
    generic(
        PIXEL_WIDTH     : integer := 10;
        BLK_SIZE        : integer := 4;
        BLK_EXT         : vl_notype;
        H_INT_W         : vl_notype;
        HV_SUM_W        : vl_notype;
        PAIR_W          : vl_notype;
        HV_PAIR_W       : vl_notype
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        valid_in        : in     vl_logic;
        ref_ext_flat    : in     vl_logic_vector;
        valid_out       : out    vl_logic;
        h_out_flat      : out    vl_logic_vector;
        v_out_flat      : out    vl_logic_vector;
        hv_out_flat     : out    vl_logic_vector
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of PIXEL_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of BLK_SIZE : constant is 1;
    attribute mti_svvh_generic_type of BLK_EXT : constant is 3;
    attribute mti_svvh_generic_type of H_INT_W : constant is 3;
    attribute mti_svvh_generic_type of HV_SUM_W : constant is 3;
    attribute mti_svvh_generic_type of PAIR_W : constant is 3;
    attribute mti_svvh_generic_type of HV_PAIR_W : constant is 3;
end hpel_filter_luma;
