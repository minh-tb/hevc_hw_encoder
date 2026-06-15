library verilog;
use verilog.vl_types.all;
entity output_fifo is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        wr_valid        : in     vl_logic;
        wr_ready        : out    vl_logic;
        wr_byte         : in     vl_logic_vector(7 downto 0);
        wr_last_in_au   : in     vl_logic;
        rd_valid        : out    vl_logic;
        rd_ready        : in     vl_logic;
        rd_byte         : out    vl_logic_vector(7 downto 0);
        rd_last_in_au   : out    vl_logic;
        empty           : out    vl_logic;
        full            : out    vl_logic;
        count           : out    vl_logic_vector(12 downto 0);
        wr_overflow     : out    vl_logic;
        total_bytes     : out    vl_logic_vector(31 downto 0)
    );
end output_fifo;
