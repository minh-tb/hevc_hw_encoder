library verilog;
use verilog.vl_types.all;
entity nal_parser is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        in_valid        : in     vl_logic;
        in_ready        : out    vl_logic;
        in_byte         : in     vl_logic_vector(7 downto 0);
        in_last         : in     vl_logic;
        out_valid       : out    vl_logic;
        out_ready       : in     vl_logic;
        out_byte        : out    vl_logic_vector(7 downto 0);
        out_last        : out    vl_logic
    );
end nal_parser;
