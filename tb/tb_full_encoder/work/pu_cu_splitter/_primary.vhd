library verilog;
use verilog.vl_types.all;
entity pu_cu_splitter is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        cu_valid        : in     vl_logic;
        cu_ready        : out    vl_logic;
        cu_x            : in     vl_logic_vector(5 downto 0);
        cu_y            : in     vl_logic_vector(5 downto 0);
        cu_size         : in     vl_logic_vector(6 downto 0);
        cu_depth        : in     vl_logic_vector(1 downto 0);
        part_mode       : in     vl_logic_vector(2 downto 0);
        skip_flag       : in     vl_logic;
        pu_valid        : out    vl_logic;
        pu_ready        : in     vl_logic;
        pu_x            : out    vl_logic_vector(5 downto 0);
        pu_y            : out    vl_logic_vector(5 downto 0);
        tu_split_fb_valid: in     vl_logic;
        tu_split_fb_flag: in     vl_logic;
        tu_split_fb_ready: out    vl_logic;
        tu_valid        : out    vl_logic;
        tu_ready        : in     vl_logic;
        tu_x            : out    vl_logic_vector(5 downto 0);
        tu_y            : out    vl_logic_vector(5 downto 0);
        tu_size_log2    : out    vl_logic_vector(2 downto 0);
        tu_comp         : out    vl_logic_vector(1 downto 0);
        tu_is_last_in_cu: out    vl_logic
    );
end pu_cu_splitter;
