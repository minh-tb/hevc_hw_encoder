library verilog;
use verilog.vl_types.all;
entity residual_sub is
    generic(
        PIXEL_WIDTH     : integer := 10;
        RESIDUAL_WIDTH  : integer := 11
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        is_intra        : in     vl_logic;
        orig_valid      : in     vl_logic;
        orig_pixel      : in     vl_logic_vector;
        intra_pred_valid: in     vl_logic;
        intra_pred_pixel: in     vl_logic_vector;
        intra_pred_x    : in     vl_logic_vector(5 downto 0);
        intra_pred_y    : in     vl_logic_vector(5 downto 0);
        inter_pred_valid: in     vl_logic;
        inter_pred_pixel: in     vl_logic_vector;
        inter_pred_x    : in     vl_logic_vector(5 downto 0);
        inter_pred_y    : in     vl_logic_vector(5 downto 0);
        res_valid       : out    vl_logic;
        residual        : out    vl_logic_vector;
        res_x           : out    vl_logic_vector(5 downto 0);
        res_y           : out    vl_logic_vector(5 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of PIXEL_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of RESIDUAL_WIDTH : constant is 1;
end residual_sub;
