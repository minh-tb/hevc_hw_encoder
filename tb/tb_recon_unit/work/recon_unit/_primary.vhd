library verilog;
use verilog.vl_types.all;
entity recon_unit is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        transform_skip  : in     vl_logic;
        comp            : in     vl_logic_vector(1 downto 0);
        pred_valid      : in     vl_logic;
        pred_ready      : out    vl_logic;
        pred_pixel      : in     vl_logic_vector(9 downto 0);
        pred_x          : in     vl_logic_vector(5 downto 0);
        pred_y          : in     vl_logic_vector(5 downto 0);
        pred_last       : in     vl_logic;
        res_valid       : in     vl_logic;
        res_ready       : out    vl_logic;
        res_coeff       : in     vl_logic_vector(15 downto 0);
        res_x           : in     vl_logic_vector(5 downto 0);
        res_y           : in     vl_logic_vector(5 downto 0);
        res_last        : in     vl_logic;
        out_valid       : out    vl_logic;
        out_ready       : in     vl_logic;
        out_pixel       : out    vl_logic_vector(9 downto 0);
        out_x           : out    vl_logic_vector(5 downto 0);
        out_y           : out    vl_logic_vector(5 downto 0);
        out_last        : out    vl_logic;
        out_comp        : out    vl_logic_vector(1 downto 0)
    );
end recon_unit;
