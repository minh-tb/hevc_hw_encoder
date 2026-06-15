library verilog;
use verilog.vl_types.all;
entity coeff_buffer is
    generic(
        DATA_W          : integer := 16;
        DEPTH           : integer := 1024;
        ADDR_W          : integer := 10
    );
    port(
        clk             : in     vl_logic;
        we              : in     vl_logic;
        waddr           : in     vl_logic_vector;
        wdata           : in     vl_logic_vector;
        re              : in     vl_logic;
        raddr           : in     vl_logic_vector;
        rdata           : out    vl_logic_vector
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of DATA_W : constant is 1;
    attribute mti_svvh_generic_type of DEPTH : constant is 1;
    attribute mti_svvh_generic_type of ADDR_W : constant is 1;
end coeff_buffer;
