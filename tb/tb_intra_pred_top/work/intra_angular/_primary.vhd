library verilog;
use verilog.vl_types.all;
entity intra_angular is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        pu_size_log2    : in     vl_logic_vector(2 downto 0);
        intra_mode      : in     vl_logic_vector(5 downto 0);
        is_luma         : in     vl_logic;
        in_valid        : in     vl_logic;
        in_ready        : out    vl_logic;
        in_sample       : in     vl_logic_vector(9 downto 0);
        in_idx          : in     vl_logic_vector(7 downto 0);
        in_last         : in     vl_logic;
        out_valid       : out    vl_logic;
        out_ready       : in     vl_logic;
        out_pixel       : out    vl_logic_vector(9 downto 0);
        out_x           : out    vl_logic_vector(5 downto 0);
        out_y           : out    vl_logic_vector(5 downto 0);
        out_last        : out    vl_logic
    );
end intra_angular;
