library verilog;
use verilog.vl_types.all;
entity sao_edge_offset is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        edge_type       : in     vl_logic_vector(1 downto 0);
        offset          : in     vl_logic_vector(24 downto 0);
        in_valid        : in     vl_logic;
        in_ready        : out    vl_logic;
        pixel_in        : in     vl_logic_vector(9 downto 0);
        neigh0          : in     vl_logic_vector(9 downto 0);
        neigh1          : in     vl_logic_vector(9 downto 0);
        in_last         : in     vl_logic;
        out_valid       : out    vl_logic;
        out_ready       : in     vl_logic;
        pixel_out       : out    vl_logic_vector(9 downto 0);
        out_last        : out    vl_logic
    );
end sao_edge_offset;
