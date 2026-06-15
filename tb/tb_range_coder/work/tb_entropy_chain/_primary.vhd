library verilog;
use verilog.vl_types.all;
entity tb_entropy_chain is
    generic(
        CTX_ID_W        : integer := 8;
        COEFF_W         : integer := 16;
        MVD_W           : integer := 12;
        N_COEFF         : integer := 16
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CTX_ID_W : constant is 2;
    attribute mti_svvh_generic_type of COEFF_W : constant is 2;
    attribute mti_svvh_generic_type of MVD_W : constant is 2;
    attribute mti_svvh_generic_type of N_COEFF : constant is 2;
end tb_entropy_chain;
