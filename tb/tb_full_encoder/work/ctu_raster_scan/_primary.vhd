library verilog;
use verilog.vl_types.all;
entity ctu_raster_scan is
    generic(
        FRAME_WIDTH     : integer := 3840;
        FRAME_HEIGHT    : integer := 2160
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        frame_start     : in     vl_logic;
        frame_poc       : in     vl_logic_vector(9 downto 0);
        frame_slice_type: in     vl_logic_vector(1 downto 0);
        ctu_valid       : out    vl_logic;
        ctu_ready       : in     vl_logic;
        ctu_addr        : out    vl_logic_vector(15 downto 0);
        ctu_x           : out    vl_logic_vector(9 downto 0);
        ctu_y           : out    vl_logic_vector(9 downto 0);
        frame_width_px  : out    vl_logic_vector(13 downto 0);
        frame_height_px : out    vl_logic_vector(13 downto 0);
        poc             : out    vl_logic_vector(9 downto 0);
        slice_type      : out    vl_logic_vector(1 downto 0);
        qp              : out    vl_logic_vector(5 downto 0);
        is_first_in_row : out    vl_logic;
        is_last_in_row  : out    vl_logic;
        is_last_ctu     : out    vl_logic;
        frame_active    : out    vl_logic;
        frame_done      : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of FRAME_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of FRAME_HEIGHT : constant is 1;
end ctu_raster_scan;
