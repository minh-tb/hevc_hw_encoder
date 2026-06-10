library verilog;
use verilog.vl_types.all;
entity sao_band_offset is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        band_position   : in     vl_logic_vector(4 downto 0);
        offset          : in     vl_logic_vector(19 downto 0);
        in_valid        : in     vl_logic;
        in_ready        : out    vl_logic;
        pixel_in        : in     vl_logic_vector(9 downto 0);
        in_last         : in     vl_logic;
        out_valid       : out    vl_logic;
        out_ready       : in     vl_logic;
        pixel_out       : out    vl_logic_vector(9 downto 0);
        out_last        : out    vl_logic
    );
end sao_band_offset;
