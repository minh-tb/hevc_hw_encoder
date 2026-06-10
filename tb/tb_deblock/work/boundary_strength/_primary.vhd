library verilog;
use verilog.vl_types.all;
entity boundary_strength is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        in_valid        : in     vl_logic;
        in_ready        : out    vl_logic;
        is_vertical     : in     vl_logic;
        is_ctu_boundary : in     vl_logic;
        p_is_intra      : in     vl_logic;
        p_qp            : in     vl_logic_vector(5 downto 0);
        p_cbf_luma      : in     vl_logic;
        p_cbf_chroma    : in     vl_logic;
        p_ref_idx_l0    : in     vl_logic_vector(2 downto 0);
        p_ref_idx_l1    : in     vl_logic_vector(2 downto 0);
        p_bi_pred       : in     vl_logic;
        p_mvx_l0        : in     vl_logic_vector(15 downto 0);
        p_mvy_l0        : in     vl_logic_vector(15 downto 0);
        p_mvx_l1        : in     vl_logic_vector(15 downto 0);
        p_mvy_l1        : in     vl_logic_vector(15 downto 0);
        q_is_intra      : in     vl_logic;
        q_qp            : in     vl_logic_vector(5 downto 0);
        q_cbf_luma      : in     vl_logic;
        q_cbf_chroma    : in     vl_logic;
        q_ref_idx_l0    : in     vl_logic_vector(2 downto 0);
        q_ref_idx_l1    : in     vl_logic_vector(2 downto 0);
        q_bi_pred       : in     vl_logic;
        q_mvx_l0        : in     vl_logic_vector(15 downto 0);
        q_mvy_l0        : in     vl_logic_vector(15 downto 0);
        q_mvx_l1        : in     vl_logic_vector(15 downto 0);
        q_mvy_l1        : in     vl_logic_vector(15 downto 0);
        edge_qp         : out    vl_logic_vector(5 downto 0);
        out_valid       : out    vl_logic;
        out_ready       : in     vl_logic;
        bs              : out    vl_logic_vector(1 downto 0)
    );
end boundary_strength;
