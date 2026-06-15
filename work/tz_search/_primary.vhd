library verilog;
use verilog.vl_types.all;
entity tz_search is
    generic(
        PIXEL_WIDTH     : integer := 10;
        MV_W            : integer := 10;
        CU_COORD_W      : integer := 12;
        SRCH_RNG        : integer := 64;
        N_STEPS         : integer := 6;
        N_REFINE        : integer := 4;
        SAD_W           : integer := 12;
        BEST_SAD_W      : vl_notype
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        search_valid    : in     vl_logic;
        search_ready    : out    vl_logic;
        cu_orig_flat    : in     vl_logic_vector;
        cu_x            : in     vl_logic_vector;
        cu_y            : in     vl_logic_vector;
        mvp_x           : in     vl_logic_vector;
        mvp_y           : in     vl_logic_vector;
        ref_req_valid   : out    vl_logic;
        ref_req_x       : out    vl_logic_vector(11 downto 0);
        ref_req_y       : out    vl_logic_vector(11 downto 0);
        ref_req_ready   : in     vl_logic;
        ref_resp_valid  : in     vl_logic;
        ref_resp_data   : in     vl_logic_vector;
        result_valid    : out    vl_logic;
        best_mv_x       : out    vl_logic_vector;
        best_mv_y       : out    vl_logic_vector;
        best_sad        : out    vl_logic_vector
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of PIXEL_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of MV_W : constant is 1;
    attribute mti_svvh_generic_type of CU_COORD_W : constant is 1;
    attribute mti_svvh_generic_type of SRCH_RNG : constant is 1;
    attribute mti_svvh_generic_type of N_STEPS : constant is 1;
    attribute mti_svvh_generic_type of N_REFINE : constant is 1;
    attribute mti_svvh_generic_type of SAD_W : constant is 1;
    attribute mti_svvh_generic_type of BEST_SAD_W : constant is 3;
end tz_search;
