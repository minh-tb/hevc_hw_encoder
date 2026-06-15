library verilog;
use verilog.vl_types.all;
entity mode_decision is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        split_valid     : out    vl_logic;
        split_flag      : out    vl_logic;
        split_ready     : in     vl_logic;
        pu_valid        : in     vl_logic;
        pu_size         : in     vl_logic_vector(6 downto 0);
        pu_depth        : in     vl_logic_vector(1 downto 0);
        slice_type      : in     vl_logic_vector(1 downto 0);
        qp              : in     vl_logic_vector(5 downto 0);
        poc             : in     vl_logic_vector(9 downto 0);
        intra_cost_valid: in     vl_logic;
        intra_rd_cost   : in     vl_logic_vector(31 downto 0);
        intra_best_mode : in     vl_logic_vector(5 downto 0);
        inter_cost_valid: in     vl_logic;
        inter_rd_cost   : in     vl_logic_vector(31 downto 0);
        inter_best_mv_x : in     vl_logic_vector(11 downto 0);
        inter_best_mv_y : in     vl_logic_vector(11 downto 0);
        rate_cost_valid : in     vl_logic;
        est_bit_rate    : in     vl_logic_vector(31 downto 0);
        eval_intra_start: out    vl_logic;
        eval_inter_start: out    vl_logic;
        mode_valid      : out    vl_logic;
        best_rd_cost    : out    vl_logic_vector(31 downto 0);
        best_is_intra   : out    vl_logic;
        best_intra_mode : out    vl_logic_vector(5 downto 0);
        best_inter_mv_x : out    vl_logic_vector(11 downto 0);
        best_inter_mv_y : out    vl_logic_vector(11 downto 0)
    );
end mode_decision;
