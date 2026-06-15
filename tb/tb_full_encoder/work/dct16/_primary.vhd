library verilog;
use verilog.vl_types.all;
entity dct16 is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        fwd_inv_n       : in     vl_logic;
        in_valid        : in     vl_logic;
        in_ready        : out    vl_logic;
        in_data         : in     vl_logic_vector(4095 downto 0);
        out_valid       : out    vl_logic;
        out_ready       : in     vl_logic;
        out_data        : out    vl_logic_vector(4095 downto 0)
    );
end dct16;
