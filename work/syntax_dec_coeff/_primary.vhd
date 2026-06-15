library verilog;
use verilog.vl_types.all;
entity syntax_dec_coeff is
    generic(
        CTX_ID_W        : integer := 8;
        COEFF_W         : integer := 16;
        BLK_SIZE        : integer := 4;
        N_COEFF         : integer := 16;
        MAX_RICE        : integer := 4
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        coeff_req       : in     vl_logic;
        coeff_done      : out    vl_logic;
        comp_id         : in     vl_logic_vector(1 downto 0);
        is_intra        : in     vl_logic;
        coeff_flat      : out    vl_logic_vector;
        dec_req         : out    vl_logic;
        dec_ctx_id      : out    vl_logic_vector;
        is_ep           : out    vl_logic;
        dec_ready       : in     vl_logic;
        dec_valid       : in     vl_logic;
        dec_bin         : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CTX_ID_W : constant is 1;
    attribute mti_svvh_generic_type of COEFF_W : constant is 1;
    attribute mti_svvh_generic_type of BLK_SIZE : constant is 1;
    attribute mti_svvh_generic_type of N_COEFF : constant is 1;
    attribute mti_svvh_generic_type of MAX_RICE : constant is 1;
end syntax_dec_coeff;
