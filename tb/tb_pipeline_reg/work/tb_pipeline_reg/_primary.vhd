library verilog;
use verilog.vl_types.all;
entity tb_pipeline_reg is
    generic(
        WIDTH           : integer := 8
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of WIDTH : constant is 1;
end tb_pipeline_reg;
