library verilog;
use verilog.vl_types.all;
entity sad_4x4 is
    generic(
        PIXEL_WIDTH     : integer := 10;
        PIPELINED       : integer := 1;
        SAD_SHIFT       : vl_notype;
        DIFF_WIDTH      : vl_notype;
        ABS_WIDTH       : vl_notype;
        ROW_WIDTH       : vl_notype;
        RAW_WIDTH       : vl_notype;
        SAD_WIDTH       : vl_notype
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        valid_in        : in     vl_logic;
        orig_flat       : in     vl_logic_vector;
        ref_flat        : in     vl_logic_vector;
        valid_out       : out    vl_logic;
        sad_out         : out    vl_logic_vector
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of PIXEL_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of PIPELINED : constant is 1;
    attribute mti_svvh_generic_type of SAD_SHIFT : constant is 3;
    attribute mti_svvh_generic_type of DIFF_WIDTH : constant is 3;
    attribute mti_svvh_generic_type of ABS_WIDTH : constant is 3;
    attribute mti_svvh_generic_type of ROW_WIDTH : constant is 3;
    attribute mti_svvh_generic_type of RAW_WIDTH : constant is 3;
    attribute mti_svvh_generic_type of SAD_WIDTH : constant is 3;
end sad_4x4;
