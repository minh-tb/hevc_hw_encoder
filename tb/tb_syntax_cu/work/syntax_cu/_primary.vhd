library verilog;
use verilog.vl_types.all;
entity syntax_cu is
    generic(
        CTX_ID_W        : integer := 8
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        cu_valid        : in     vl_logic;
        cu_done         : out    vl_logic;
        cu_depth        : in     vl_logic_vector(1 downto 0);
        cu_is_split     : in     vl_logic;
        slice_is_intra  : in     vl_logic;
        cu_skip         : in     vl_logic;
        cu_merge        : in     vl_logic;
        cu_merge_idx    : in     vl_logic_vector(2 downto 0);
        cu_pred_intra   : in     vl_logic;
        cu_part_mode    : in     vl_logic_vector(1 downto 0);
        cu_cbf          : in     vl_logic;
        cu_skip_ctx     : in     vl_logic_vector(1 downto 0);
        bin_valid       : out    vl_logic;
        bin_value       : out    vl_logic;
        bin_ctx_id      : out    vl_logic_vector;
        bin_is_ep       : out    vl_logic;
        bin_rdy         : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CTX_ID_W : constant is 1;
end syntax_cu;
