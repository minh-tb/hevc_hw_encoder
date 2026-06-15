library verilog;
use verilog.vl_types.all;
entity decoder_inloop_filters is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        in_valid        : in     vl_logic;
        in_pixel        : in     vl_logic_vector(9 downto 0);
        in_x            : in     vl_logic_vector(5 downto 0);
        in_y            : in     vl_logic_vector(5 downto 0);
        out_valid       : out    vl_logic;
        out_pixel       : out    vl_logic_vector(9 downto 0);
        out_abs_x       : out    vl_logic_vector(11 downto 0);
        out_abs_y       : out    vl_logic_vector(11 downto 0)
    );
end decoder_inloop_filters;
