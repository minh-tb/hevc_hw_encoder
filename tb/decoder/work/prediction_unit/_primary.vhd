library verilog;
use verilog.vl_types.all;
entity prediction_unit is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        is_intra        : in     vl_logic;
        intra_mode      : in     vl_logic_vector(5 downto 0);
        inter_dir       : in     vl_logic_vector(1 downto 0);
        mv_l0_x         : in     vl_logic_vector(11 downto 0);
        mv_l0_y         : in     vl_logic_vector(11 downto 0);
        mv_l1_x         : in     vl_logic_vector(11 downto 0);
        mv_l1_y         : in     vl_logic_vector(11 downto 0);
        pred_valid      : out    vl_logic;
        pred_pixel      : out    vl_logic_vector(9 downto 0);
        pred_x          : out    vl_logic_vector(5 downto 0);
        pred_y          : out    vl_logic_vector(5 downto 0)
    );
end prediction_unit;
