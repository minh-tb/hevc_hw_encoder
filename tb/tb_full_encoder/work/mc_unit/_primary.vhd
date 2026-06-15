library verilog;
use verilog.vl_types.all;
entity mc_unit is
    generic(
        PIXEL_WIDTH     : integer := 10;
        BLK_SIZE        : integer := 4;
        MV_QP_W         : integer := 14;
        CU_COORD_W      : integer := 12;
        BLK_C           : vl_notype;
        BLK_EXT_Y       : vl_notype;
        BLK_EXT_C       : vl_notype;
        PX_Y            : vl_notype;
        PX_C            : vl_notype;
        PX_EXT_Y        : vl_notype;
        PX_EXT_C        : vl_notype
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        mc_start        : in     vl_logic;
        mc_ready        : out    vl_logic;
        mc_ref_slot     : in     vl_logic_vector(2 downto 0);
        mc_cu_x         : in     vl_logic_vector;
        mc_cu_y         : in     vl_logic_vector;
        mc_mv_x         : in     vl_logic_vector;
        mc_mv_y         : in     vl_logic_vector;
        ref_req_valid   : out    vl_logic;
        ref_req_comp    : out    vl_logic_vector(1 downto 0);
        ref_req_slot    : out    vl_logic_vector(2 downto 0);
        ref_req_x       : out    vl_logic_vector;
        ref_req_y       : out    vl_logic_vector;
        ref_req_ready   : in     vl_logic;
        ref_resp_valid  : in     vl_logic;
        ref_resp_y_flat : in     vl_logic_vector;
        ref_resp_cb_flat: in     vl_logic_vector;
        ref_resp_cr_flat: in     vl_logic_vector;
        mc_done         : out    vl_logic;
        pred_y_flat     : out    vl_logic_vector;
        pred_cb_flat    : out    vl_logic_vector;
        pred_cr_flat    : out    vl_logic_vector
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of PIXEL_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of BLK_SIZE : constant is 1;
    attribute mti_svvh_generic_type of MV_QP_W : constant is 1;
    attribute mti_svvh_generic_type of CU_COORD_W : constant is 1;
    attribute mti_svvh_generic_type of BLK_C : constant is 3;
    attribute mti_svvh_generic_type of BLK_EXT_Y : constant is 3;
    attribute mti_svvh_generic_type of BLK_EXT_C : constant is 3;
    attribute mti_svvh_generic_type of PX_Y : constant is 3;
    attribute mti_svvh_generic_type of PX_C : constant is 3;
    attribute mti_svvh_generic_type of PX_EXT_Y : constant is 3;
    attribute mti_svvh_generic_type of PX_EXT_C : constant is 3;
end mc_unit;
