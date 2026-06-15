library verilog;
use verilog.vl_types.all;
entity pipeline_reg is
    generic(
        WIDTH           : integer := 1;
        STAGES          : integer := 1
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        en              : in     vl_logic;
        din             : in     vl_logic_vector;
        dout            : out    vl_logic_vector
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of WIDTH : constant is 1;
    attribute mti_svvh_generic_type of STAGES : constant is 1;
end pipeline_reg;
