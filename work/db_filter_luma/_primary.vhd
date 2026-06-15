library verilog;
use verilog.vl_types.all;
entity db_filter_luma is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        in_valid        : in     vl_logic;
        in_ready        : out    vl_logic;
        bs              : in     vl_logic_vector(1 downto 0);
        edge_qp         : in     vl_logic_vector(5 downto 0);
        p0              : in     vl_logic_vector(9 downto 0);
        p1              : in     vl_logic_vector(9 downto 0);
        p2              : in     vl_logic_vector(9 downto 0);
        p3              : in     vl_logic_vector(9 downto 0);
        q0              : in     vl_logic_vector(9 downto 0);
        q1              : in     vl_logic_vector(9 downto 0);
        q2              : in     vl_logic_vector(9 downto 0);
        q3              : in     vl_logic_vector(9 downto 0);
        out_valid       : out    vl_logic;
        out_ready       : in     vl_logic;
        p0_f            : out    vl_logic_vector(9 downto 0);
        p1_f            : out    vl_logic_vector(9 downto 0);
        p2_f            : out    vl_logic_vector(9 downto 0);
        q0_f            : out    vl_logic_vector(9 downto 0);
        q1_f            : out    vl_logic_vector(9 downto 0);
        q2_f            : out    vl_logic_vector(9 downto 0);
        modified_p      : out    vl_logic;
        modified_q      : out    vl_logic
    );
end db_filter_luma;
