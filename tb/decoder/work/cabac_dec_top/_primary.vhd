library verilog;
use verilog.vl_types.all;
entity cabac_dec_top is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        rbsp_valid      : in     vl_logic;
        rbsp_ready      : out    vl_logic;
        rbsp_byte       : in     vl_logic_vector(7 downto 0);
        coeff_valid     : out    vl_logic;
        coeff_out       : out    vl_logic_vector(15 downto 0);
        tu_size_log2    : out    vl_logic_vector(2 downto 0);
        is_intra        : out    vl_logic;
        intra_mode      : out    vl_logic_vector(5 downto 0);
        inter_dir       : out    vl_logic_vector(1 downto 0);
        mv_l0_x         : out    vl_logic_vector(11 downto 0);
        mv_l0_y         : out    vl_logic_vector(11 downto 0);
        mv_l1_x         : out    vl_logic_vector(11 downto 0);
        mv_l1_y         : out    vl_logic_vector(11 downto 0)
    );
end cabac_dec_top;
