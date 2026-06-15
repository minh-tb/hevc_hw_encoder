library verilog;
use verilog.vl_types.all;
entity syntax_dec_cu is
    generic(
        CTX_ID_W        : integer := 8
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        cu_req          : in     vl_logic;
        cu_done         : out    vl_logic;
        cu_depth        : in     vl_logic_vector(1 downto 0);
        slice_is_intra  : in     vl_logic;
        cu_skip_ctx     : in     vl_logic_vector(1 downto 0);
        cu_is_split     : out    vl_logic;
        cu_skip         : out    vl_logic;
        cu_merge        : out    vl_logic;
        cu_merge_idx    : out    vl_logic_vector(2 downto 0);
        cu_pred_intra   : out    vl_logic;
        cu_part_mode    : out    vl_logic_vector(1 downto 0);
        cu_cbf          : out    vl_logic;
        dec_req         : out    vl_logic;
        dec_ctx_id      : out    vl_logic_vector;
        is_ep           : out    vl_logic;
        dec_ready       : in     vl_logic;
        dec_valid       : in     vl_logic;
        dec_bin         : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CTX_ID_W : constant is 1;
end syntax_dec_cu;
