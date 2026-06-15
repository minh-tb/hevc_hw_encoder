library verilog;
use verilog.vl_types.all;
entity range_coder is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        coder_init      : in     vl_logic;
        bin_valid       : in     vl_logic;
        bin_value       : in     vl_logic;
        bin_pstate      : in     vl_logic_vector(5 downto 0);
        bin_valmps      : in     vl_logic;
        bin_ready       : out    vl_logic;
        ep_valid        : in     vl_logic;
        trm_valid       : in     vl_logic;
        flush_valid     : in     vl_logic;
        flush_done      : out    vl_logic;
        byte_valid      : out    vl_logic;
        byte_out        : out    vl_logic_vector(7 downto 0);
        byte_ready      : in     vl_logic;
        coder_busy      : out    vl_logic
    );
end range_coder;
