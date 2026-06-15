library verilog;
use verilog.vl_types.all;
entity mvp_predictor is
    generic(
        MV_W            : integer := 10;
        RIF_W           : integer := 4;
        N_MERGE         : integer := 5;
        N_NBR           : integer := 5;
        NBR_A1          : integer := 0;
        NBR_A0          : integer := 1;
        NBR_B1          : integer := 2;
        NBR_B0          : integer := 3;
        NBR_B2          : integer := 4
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        valid_in        : in     vl_logic;
        target_ref_idx  : in     vl_logic_vector;
        nbr_inter       : in     vl_logic_vector(4 downto 0);
        nbr_mv_x_flat   : in     vl_logic_vector;
        nbr_mv_y_flat   : in     vl_logic_vector;
        nbr_ref_flat    : in     vl_logic_vector;
        valid_out       : out    vl_logic;
        amvp_mv_x_flat  : out    vl_logic_vector;
        amvp_mv_y_flat  : out    vl_logic_vector;
        merge_valid     : out    vl_logic_vector;
        merge_mv_x_flat : out    vl_logic_vector;
        merge_mv_y_flat : out    vl_logic_vector;
        merge_ref_flat  : out    vl_logic_vector
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of MV_W : constant is 1;
    attribute mti_svvh_generic_type of RIF_W : constant is 1;
    attribute mti_svvh_generic_type of N_MERGE : constant is 1;
    attribute mti_svvh_generic_type of N_NBR : constant is 1;
    attribute mti_svvh_generic_type of NBR_A1 : constant is 1;
    attribute mti_svvh_generic_type of NBR_A0 : constant is 1;
    attribute mti_svvh_generic_type of NBR_B1 : constant is 1;
    attribute mti_svvh_generic_type of NBR_B0 : constant is 1;
    attribute mti_svvh_generic_type of NBR_B2 : constant is 1;
end mvp_predictor;
