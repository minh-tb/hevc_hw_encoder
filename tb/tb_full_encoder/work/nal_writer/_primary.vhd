library verilog;
use verilog.vl_types.all;
entity nal_writer is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        nal_start       : in     vl_logic;
        nal_type        : in     vl_logic_vector(5 downto 0);
        temporal_id     : in     vl_logic_vector(2 downto 0);
        nal_end         : in     vl_logic;
        rbsp_valid      : in     vl_logic;
        rbsp_ready      : out    vl_logic;
        rbsp_byte       : in     vl_logic_vector(7 downto 0);
        rbsp_last       : in     vl_logic;
        out_valid       : out    vl_logic;
        out_ready       : in     vl_logic;
        out_byte        : out    vl_logic_vector(7 downto 0);
        out_last_in_nal : out    vl_logic;
        nal_byte_count  : out    vl_logic_vector(31 downto 0);
        total_nal_count : out    vl_logic_vector(31 downto 0)
    );
end nal_writer;
