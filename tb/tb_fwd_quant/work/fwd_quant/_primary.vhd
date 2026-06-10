library verilog;
use verilog.vl_types.all;
entity fwd_quant is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        qp              : in     vl_logic_vector(5 downto 0);
        tu_size_log2    : in     vl_logic_vector(2 downto 0);
        is_intra        : in     vl_logic;
        transform_skip  : in     vl_logic;
        in_valid        : in     vl_logic;
        in_ready        : out    vl_logic;
        in_coeff        : in     vl_logic_vector(15 downto 0);
        in_scan_idx     : in     vl_logic_vector(9 downto 0);
        in_last         : in     vl_logic;
        out_valid       : out    vl_logic;
        out_ready       : in     vl_logic;
        out_level       : out    vl_logic_vector(15 downto 0);
        out_scan_idx    : out    vl_logic_vector(9 downto 0);
        out_last        : out    vl_logic;
        out_cbf         : out    vl_logic
    );
end fwd_quant;
