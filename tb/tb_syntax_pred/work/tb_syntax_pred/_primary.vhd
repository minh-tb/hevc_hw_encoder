library verilog;
use verilog.vl_types.all;
entity tb_syntax_pred is
    generic(
        CTX_ID_W        : integer := 8;
        MVD_W           : integer := 12;
        MAX_REF         : integer := 4
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CTX_ID_W : constant is 1;
    attribute mti_svvh_generic_type of MVD_W : constant is 1;
    attribute mti_svvh_generic_type of MAX_REF : constant is 1;
end tb_syntax_pred;
