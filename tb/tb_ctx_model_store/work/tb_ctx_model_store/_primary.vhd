library verilog;
use verilog.vl_types.all;
entity tb_ctx_model_store is
    generic(
        N_CTX           : integer := 154;
        CTX_W           : integer := 7;
        CTX_ID_W        : integer := 8
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of N_CTX : constant is 1;
    attribute mti_svvh_generic_type of CTX_W : constant is 1;
    attribute mti_svvh_generic_type of CTX_ID_W : constant is 1;
end tb_ctx_model_store;
