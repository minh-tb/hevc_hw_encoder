library verilog;
use verilog.vl_types.all;
entity syntax_dec_pred is
    generic(
        CTX_ID_W        : integer := 8;
        MVD_W           : integer := 12;
        MAX_REF         : integer := 4
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        pred_req        : in     vl_logic;
        pred_done       : out    vl_logic;
        slice_is_b      : in     vl_logic;
        cu_depth        : in     vl_logic_vector(1 downto 0);
        inter_dir       : out    vl_logic_vector(1 downto 0);
        ref_idx_l0      : out    vl_logic_vector(2 downto 0);
        mvp_flag_l0     : out    vl_logic;
        mvd_l0_x        : out    vl_logic_vector;
        mvd_l0_y        : out    vl_logic_vector;
        ref_idx_l1      : out    vl_logic_vector(2 downto 0);
        mvp_flag_l1     : out    vl_logic;
        mvd_l1_x        : out    vl_logic_vector;
        mvd_l1_y        : out    vl_logic_vector;
        dec_req         : out    vl_logic;
        dec_ctx_id      : out    vl_logic_vector;
        is_ep           : out    vl_logic;
        dec_ready       : in     vl_logic;
        dec_valid       : in     vl_logic;
        dec_bin         : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CTX_ID_W : constant is 1;
    attribute mti_svvh_generic_type of MVD_W : constant is 1;
    attribute mti_svvh_generic_type of MAX_REF : constant is 1;
end syntax_dec_pred;
