library verilog;
use verilog.vl_types.all;
entity ctu_partitioner is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        ctu_valid       : in     vl_logic;
        ctu_ready       : out    vl_logic;
        ctu_addr        : in     vl_logic_vector(15 downto 0);
        ctu_x           : in     vl_logic_vector(9 downto 0);
        ctu_y           : in     vl_logic_vector(9 downto 0);
        poc             : in     vl_logic_vector(9 downto 0);
        slice_type      : in     vl_logic_vector(1 downto 0);
        qp              : in     vl_logic_vector(5 downto 0);
        cu_valid        : out    vl_logic;
        cu_ready        : in     vl_logic;
        cu_x            : out    vl_logic_vector(5 downto 0);
        cu_y            : out    vl_logic_vector(5 downto 0);
        cu_size         : out    vl_logic_vector(6 downto 0);
        cu_depth        : out    vl_logic_vector(1 downto 0);
        cu_ctu_addr     : out    vl_logic_vector(15 downto 0);
        cu_ctu_x        : out    vl_logic_vector(9 downto 0);
        cu_ctu_y        : out    vl_logic_vector(9 downto 0);
        cu_poc          : out    vl_logic_vector(9 downto 0);
        cu_slice_type   : out    vl_logic_vector(1 downto 0);
        cu_qp           : out    vl_logic_vector(5 downto 0);
        cu_is_last_in_ctu: out    vl_logic;
        split_valid     : in     vl_logic;
        split_flag      : in     vl_logic;
        split_ready     : out    vl_logic
    );
end ctu_partitioner;
