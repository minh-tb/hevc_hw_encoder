library verilog;
use verilog.vl_types.all;
entity ctx_model_store is
    generic(
        N_CTX           : integer := 154;
        CTX_W           : integer := 7;
        CTX_ID_W        : integer := 8
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        slice_init      : in     vl_logic;
        slice_type      : in     vl_logic_vector(1 downto 0);
        qp_in           : in     vl_logic_vector(6 downto 0);
        rd_ctx_id       : in     vl_logic_vector;
        rd_state        : out    vl_logic_vector;
        upd_valid       : in     vl_logic;
        upd_ctx_id      : in     vl_logic_vector;
        upd_bin         : in     vl_logic;
        init_busy       : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of N_CTX : constant is 1;
    attribute mti_svvh_generic_type of CTX_W : constant is 1;
    attribute mti_svvh_generic_type of CTX_ID_W : constant is 1;
end ctx_model_store;
