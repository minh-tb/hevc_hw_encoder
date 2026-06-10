library verilog;
use verilog.vl_types.all;
entity tb_mvp_predictor is
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
end tb_mvp_predictor;
