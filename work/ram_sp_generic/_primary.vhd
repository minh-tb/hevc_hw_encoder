library verilog;
use verilog.vl_types.all;
entity ram_sp_generic is
    generic(
        DATA_WIDTH      : integer := 8;
        DEPTH           : integer := 256;
        ADDR_WIDTH      : vl_notype;
        READ_LATENCY    : integer := 1;
        INIT_VAL        : integer := 0
    );
    port(
        clk             : in     vl_logic;
        en              : in     vl_logic;
        we              : in     vl_logic;
        addr            : in     vl_logic_vector;
        din             : in     vl_logic_vector;
        dout            : out    vl_logic_vector
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of DATA_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of DEPTH : constant is 1;
    attribute mti_svvh_generic_type of ADDR_WIDTH : constant is 3;
    attribute mti_svvh_generic_type of READ_LATENCY : constant is 1;
    attribute mti_svvh_generic_type of INIT_VAL : constant is 1;
end ram_sp_generic;
