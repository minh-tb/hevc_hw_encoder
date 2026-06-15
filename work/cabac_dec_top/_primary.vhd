library verilog;
use verilog.vl_types.all;
entity cabac_dec_top is
    generic(
        CTX_ID_W        : integer := 8
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        rbsp_valid      : in     vl_logic;
        rbsp_byte       : in     vl_logic_vector(7 downto 0);
        rbsp_last       : in     vl_logic;
        rbsp_ready      : out    vl_logic;
        slice_init      : in     vl_logic;
        slice_type      : in     vl_logic_vector(1 downto 0);
        slice_qp        : in     vl_logic_vector(6 downto 0);
        coeff_valid     : out    vl_logic;
        coeff_out       : out    vl_logic_vector(15 downto 0);
        tu_size_log2    : out    vl_logic_vector(2 downto 0);
        is_intra        : out    vl_logic;
        intra_mode      : out    vl_logic_vector(5 downto 0);
        inter_dir       : out    vl_logic_vector(1 downto 0);
        ref_idx_l0      : out    vl_logic_vector(2 downto 0);
        ref_idx_l1      : out    vl_logic_vector(2 downto 0);
        mvd_l0_x        : out    vl_logic_vector(11 downto 0);
        mvd_l0_y        : out    vl_logic_vector(11 downto 0);
        mvd_l1_x        : out    vl_logic_vector(11 downto 0);
        mvd_l1_y        : out    vl_logic_vector(11 downto 0);
        slice_done      : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CTX_ID_W : constant is 1;
end cabac_dec_top;
