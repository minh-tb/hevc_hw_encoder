library verilog;
use verilog.vl_types.all;
entity tb_mvp_predictor_file is
    generic(
        MV_W            : integer := 10;
        RIF_W           : integer := 4;
        N_MERGE         : integer := 5;
        N_NBR           : integer := 5
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of MV_W : constant is 1;
    attribute mti_svvh_generic_type of RIF_W : constant is 1;
    attribute mti_svvh_generic_type of N_MERGE : constant is 1;
    attribute mti_svvh_generic_type of N_NBR : constant is 1;
end tb_mvp_predictor_file;
