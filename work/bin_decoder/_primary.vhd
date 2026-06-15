library verilog;
use verilog.vl_types.all;
entity bin_decoder is
    generic(
        CTX_ID_W        : integer := 8;
        BIT_BUF_W       : integer := 16
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        coder_init      : in     vl_logic;
        rd_ctx_id       : out    vl_logic_vector;
        rd_state        : in     vl_logic_vector(6 downto 0);
        upd_valid       : out    vl_logic;
        upd_ctx_id      : out    vl_logic_vector;
        upd_bin         : out    vl_logic;
        byte_valid      : in     vl_logic;
        byte_in         : in     vl_logic_vector(7 downto 0);
        byte_ready      : out    vl_logic;
        dec_req         : in     vl_logic;
        dec_ctx_id      : in     vl_logic_vector;
        is_ep           : in     vl_logic;
        is_trm          : in     vl_logic;
        dec_ready       : out    vl_logic;
        dec_valid       : out    vl_logic;
        dec_bin         : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CTX_ID_W : constant is 1;
    attribute mti_svvh_generic_type of BIT_BUF_W : constant is 1;
end bin_decoder;
