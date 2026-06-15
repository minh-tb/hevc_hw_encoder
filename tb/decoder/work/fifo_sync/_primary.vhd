library verilog;
use verilog.vl_types.all;
entity fifo_sync is
    generic(
        DATA_WIDTH      : integer := 10;
        DEPTH           : integer := 512;
        FWFT            : integer := 0;
        FORCE_BRAM      : integer := 0;
        PROG_FULL_THRESH: integer := 0;
        PROG_EMPTY_THRESH: integer := 0;
        ADDR_W          : vl_notype
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        wr_en           : in     vl_logic;
        din             : in     vl_logic_vector;
        full            : out    vl_logic;
        prog_full       : out    vl_logic;
        rd_en           : in     vl_logic;
        dout            : out    vl_logic_vector;
        empty           : out    vl_logic;
        prog_empty      : out    vl_logic;
        count           : out    vl_logic_vector
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of DATA_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of DEPTH : constant is 1;
    attribute mti_svvh_generic_type of FWFT : constant is 1;
    attribute mti_svvh_generic_type of FORCE_BRAM : constant is 1;
    attribute mti_svvh_generic_type of PROG_FULL_THRESH : constant is 1;
    attribute mti_svvh_generic_type of PROG_EMPTY_THRESH : constant is 1;
    attribute mti_svvh_generic_type of ADDR_W : constant is 3;
end fifo_sync;
