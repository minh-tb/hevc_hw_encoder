library verilog;
use verilog.vl_types.all;
entity sad_8x8 is
    generic(
        PIXEL_WIDTH     : integer := 10;
        SAD_SHIFT       : vl_notype;
        SAD_4_RAW       : vl_notype;
        SUM_WIDTH       : vl_notype;
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
    attribute mti_svvh_generic_type of SAD_SHIFT : constant is 3;
    attribute mti_svvh_generic_type of SAD_4_RAW : constant is 3;
    attribute mti_svvh_generic_type of SUM_WIDTH : constant is 3;
    attribute mti_svvh_generic_type of SAD_WIDTH : constant is 3;
end sad_8x8;
