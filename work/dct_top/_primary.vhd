library verilog;
use verilog.vl_types.all;
entity dct_top is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        fwd_inv_n       : in     vl_logic;
        tu_size_log2    : in     vl_logic_vector(2 downto 0);
        in_valid        : in     vl_logic;
        in_ready        : out    vl_logic;
        in_data         : in     vl_logic_vector(16383 downto 0);
        out_valid       : out    vl_logic;
        out_ready       : in     vl_logic;
        out_data        : out    vl_logic_vector(16383 downto 0);
        out_tu_size_log2: out    vl_logic_vector(2 downto 0);
        out_fwd_inv_n   : out    vl_logic
    );
end dct_top;
