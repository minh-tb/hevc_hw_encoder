library verilog;
use verilog.vl_types.all;
entity bin_encoder is
    generic(
        CTX_ID_W        : integer := 8
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        init_busy       : in     vl_logic;
        bin_valid       : in     vl_logic;
        bin_value       : in     vl_logic;
        ctx_id          : in     vl_logic_vector;
        is_ep           : in     vl_logic;
        bin_rdy_out     : out    vl_logic;
        rd_ctx_id       : out    vl_logic_vector;
        rd_state        : in     vl_logic_vector(6 downto 0);
        upd_valid       : out    vl_logic;
        upd_ctx_id      : out    vl_logic_vector;
        upd_bin         : out    vl_logic;
        rc_bin_valid    : out    vl_logic;
        rc_bin_value    : out    vl_logic;
        rc_pstate       : out    vl_logic_vector(5 downto 0);
        rc_valmps       : out    vl_logic;
        rc_bin_ready    : in     vl_logic;
        rc_ep_valid     : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CTX_ID_W : constant is 1;
end bin_encoder;
