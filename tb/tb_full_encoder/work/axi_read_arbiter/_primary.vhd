library verilog;
use verilog.vl_types.all;
entity axi_read_arbiter is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        p0_arvalid      : in     vl_logic;
        p0_arready      : out    vl_logic;
        p0_araddr       : in     vl_logic_vector(32 downto 0);
        p0_arlen        : in     vl_logic_vector(7 downto 0);
        p0_arsize       : in     vl_logic_vector(2 downto 0);
        p0_arburst      : in     vl_logic_vector(1 downto 0);
        p0_rvalid       : out    vl_logic;
        p0_rready       : in     vl_logic;
        p0_rdata        : out    vl_logic_vector(255 downto 0);
        p0_rlast        : out    vl_logic;
        p1_arvalid      : in     vl_logic;
        p1_arready      : out    vl_logic;
        p1_araddr       : in     vl_logic_vector(32 downto 0);
        p1_arlen        : in     vl_logic_vector(7 downto 0);
        p1_arsize       : in     vl_logic_vector(2 downto 0);
        p1_arburst      : in     vl_logic_vector(1 downto 0);
        p1_rvalid       : out    vl_logic;
        p1_rready       : in     vl_logic;
        p1_rdata        : out    vl_logic_vector(255 downto 0);
        p1_rlast        : out    vl_logic;
        m_arvalid       : out    vl_logic;
        m_arready       : in     vl_logic;
        m_araddr        : out    vl_logic_vector(32 downto 0);
        m_arlen         : out    vl_logic_vector(7 downto 0);
        m_arsize        : out    vl_logic_vector(2 downto 0);
        m_arburst       : out    vl_logic_vector(1 downto 0);
        m_rvalid        : in     vl_logic;
        m_rready        : out    vl_logic;
        m_rdata         : in     vl_logic_vector(255 downto 0);
        m_rlast         : in     vl_logic
    );
end axi_read_arbiter;
