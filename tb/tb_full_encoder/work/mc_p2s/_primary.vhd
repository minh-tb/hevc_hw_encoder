library verilog;
use verilog.vl_types.all;
entity mc_p2s is
    generic(
        PIXEL_WIDTH     : integer := 10
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        mc_done         : in     vl_logic;
        mc_pred_y_flat  : in     vl_logic_vector;
        pred_valid      : out    vl_logic;
        pred_pixel      : out    vl_logic_vector;
        out_x           : out    vl_logic_vector(9 downto 0);
        out_y           : out    vl_logic_vector(9 downto 0);
        out_last        : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of PIXEL_WIDTH : constant is 1;
end mc_p2s;
