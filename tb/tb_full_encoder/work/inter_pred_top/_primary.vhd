library verilog;
use verilog.vl_types.all;
entity inter_pred_top is
    generic(
        PIXEL_WIDTH     : integer := 10;
        CU_COORD_W      : integer := 12;
        MV_W            : integer := 10;
        MV_QP_W         : integer := 14;
        AXI_DW          : integer := 256;
        AXI_AW          : integer := 33;
        PX_Y            : vl_notype;
        PX_C            : vl_notype
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        search_start    : in     vl_logic;
        search_ready    : out    vl_logic;
        cu_orig_flat    : in     vl_logic_vector;
        cu_x            : in     vl_logic_vector;
        cu_y            : in     vl_logic_vector;
        mvp_x           : in     vl_logic_vector;
        mvp_y           : in     vl_logic_vector;
        search_done     : out    vl_logic;
        best_mv_x       : out    vl_logic_vector;
        best_mv_y       : out    vl_logic_vector;
        best_sad        : out    vl_logic_vector(11 downto 0);
        mc_start        : in     vl_logic;
        mc_ready        : out    vl_logic;
        mc_mv_x         : in     vl_logic_vector;
        mc_mv_y         : in     vl_logic_vector;
        mc_done         : out    vl_logic;
        mc_pred_y_flat  : out    vl_logic_vector;
        mc_pred_cb_flat : out    vl_logic_vector;
        mc_pred_cr_flat : out    vl_logic_vector;
        axi_arvalid     : out    vl_logic;
        axi_arready     : in     vl_logic;
        axi_araddr      : out    vl_logic_vector;
        axi_arlen       : out    vl_logic_vector(7 downto 0);
        axi_arsize      : out    vl_logic_vector(2 downto 0);
        axi_arburst     : out    vl_logic_vector(1 downto 0);
        axi_rvalid      : in     vl_logic;
        axi_rready      : out    vl_logic;
        axi_rdata       : in     vl_logic_vector;
        axi_rlast       : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of PIXEL_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of CU_COORD_W : constant is 1;
    attribute mti_svvh_generic_type of MV_W : constant is 1;
    attribute mti_svvh_generic_type of MV_QP_W : constant is 1;
    attribute mti_svvh_generic_type of AXI_DW : constant is 1;
    attribute mti_svvh_generic_type of AXI_AW : constant is 1;
    attribute mti_svvh_generic_type of PX_Y : constant is 3;
    attribute mti_svvh_generic_type of PX_C : constant is 3;
end inter_pred_top;
