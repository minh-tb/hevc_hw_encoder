library verilog;
use verilog.vl_types.all;
entity syntax_pred is
    generic(
        CTX_ID_W        : integer := 8;
        MVD_W           : integer := 12;
        MAX_REF         : integer := 4
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        pred_valid      : in     vl_logic;
        pred_done       : out    vl_logic;
        slice_is_b      : in     vl_logic;
        cu_depth        : in     vl_logic_vector(1 downto 0);
        inter_dir       : in     vl_logic_vector(1 downto 0);
        cu_pred_intra   : in     vl_logic;
        prev_intra_luma_pred_flag: in     vl_logic;
        mpm_idx         : in     vl_logic_vector(1 downto 0);
        rem_intra_luma_pred_mode: in     vl_logic_vector(4 downto 0);
        intra_chroma_pred_mode: in     vl_logic_vector(2 downto 0);
        ref_idx_l0      : in     vl_logic_vector(2 downto 0);
        mvp_flag_l0     : in     vl_logic;
        mvd_l0_x        : in     vl_logic_vector;
        mvd_l0_y        : in     vl_logic_vector;
        ref_idx_l1      : in     vl_logic_vector(2 downto 0);
        mvp_flag_l1     : in     vl_logic;
        mvd_l1_x        : in     vl_logic_vector;
        mvd_l1_y        : in     vl_logic_vector;
        bin_valid       : out    vl_logic;
        bin_value       : out    vl_logic;
        bin_ctx_id      : out    vl_logic_vector;
        bin_is_ep       : out    vl_logic;
        bin_rdy         : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CTX_ID_W : constant is 1;
    attribute mti_svvh_generic_type of MVD_W : constant is 1;
    attribute mti_svvh_generic_type of MAX_REF : constant is 1;
end syntax_pred;
