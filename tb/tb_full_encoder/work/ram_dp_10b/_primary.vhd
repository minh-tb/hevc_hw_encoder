library verilog;
use verilog.vl_types.all;
entity ram_dp_10b is
    generic(
        DATA_WIDTH      : integer := 10;
        ADDR_WIDTH      : integer := 12;
        DEPTH           : vl_notype;
        INIT_FILE       : string  := ""
    );
    port(
        clk_a           : in     vl_logic;
        en_a            : in     vl_logic;
        we_a            : in     vl_logic;
        addr_a          : in     vl_logic_vector;
        din_a           : in     vl_logic_vector;
        dout_a          : out    vl_logic_vector;
        clk_b           : in     vl_logic;
        en_b            : in     vl_logic;
        we_b            : in     vl_logic;
        addr_b          : in     vl_logic_vector;
        din_b           : in     vl_logic_vector;
        dout_b          : out    vl_logic_vector
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of DATA_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of ADDR_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of DEPTH : constant is 3;
    attribute mti_svvh_generic_type of INIT_FILE : constant is 1;
end ram_dp_10b;
