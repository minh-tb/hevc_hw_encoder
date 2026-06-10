library verilog;
use verilog.vl_types.all;
entity satd_4x4 is
    generic(
        PIXEL_WIDTH     : integer := 10;
        DIFF_W          : vl_notype;
        BUTT_W          : vl_notype;
        TRAN_W          : vl_notype;
        ABS_W           : vl_notype;
        PSUM_W          : vl_notype;
        SUM_W           : vl_notype;
        RND_W           : vl_notype;
        SAD_SHIFT       : vl_notype;
        SATD_W          : vl_notype
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        valid_in        : in     vl_logic;
        orig_flat       : in     vl_logic_vector;
        ref_flat        : in     vl_logic_vector;
        valid_out       : out    vl_logic;
        satd_out        : out    vl_logic_vector
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of PIXEL_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of DIFF_W : constant is 3;
    attribute mti_svvh_generic_type of BUTT_W : constant is 3;
    attribute mti_svvh_generic_type of TRAN_W : constant is 3;
    attribute mti_svvh_generic_type of ABS_W : constant is 3;
    attribute mti_svvh_generic_type of PSUM_W : constant is 3;
    attribute mti_svvh_generic_type of SUM_W : constant is 3;
    attribute mti_svvh_generic_type of RND_W : constant is 3;
    attribute mti_svvh_generic_type of SAD_SHIFT : constant is 3;
    attribute mti_svvh_generic_type of SATD_W : constant is 3;
end satd_4x4;
