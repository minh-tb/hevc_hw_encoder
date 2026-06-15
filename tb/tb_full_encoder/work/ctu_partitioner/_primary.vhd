library verilog;
use verilog.vl_types.all;
entity ctu_partitioner is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        ctu_valid       : in     vl_logic;
        ctu_ready       : out    vl_logic;
        cu_valid        : out    vl_logic;
        cu_ready        : in     vl_logic;
        cu_x            : out    vl_logic_vector(5 downto 0);
        cu_y            : out    vl_logic_vector(5 downto 0);
        cu_size         : out    vl_logic_vector(6 downto 0);
        cu_depth        : out    vl_logic_vector(1 downto 0);
        cu_is_last_in_ctu: out    vl_logic;
        split_valid     : in     vl_logic;
        split_flag      : in     vl_logic;
        split_ready     : out    vl_logic
    );
end ctu_partitioner;
