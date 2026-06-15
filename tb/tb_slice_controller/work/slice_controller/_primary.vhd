library verilog;
use verilog.vl_types.all;
entity slice_controller is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        frame_start     : in     vl_logic;
        frame_poc       : in     vl_logic_vector(9 downto 0);
        frame_slice_type: in     vl_logic_vector(1 downto 0);
        temporal_id     : in     vl_logic_vector(2 downto 0);
        nal_type        : in     vl_logic_vector(5 downto 0);
        frame_done      : out    vl_logic;
        ctu_frame_start : out    vl_logic;
        ctu_frame_done  : in     vl_logic;
        nal_start       : out    vl_logic;
        out_nal_type    : out    vl_logic_vector(5 downto 0);
        out_temporal_id : out    vl_logic_vector(2 downto 0);
        nal_end         : out    vl_logic;
        rbsp_valid      : out    vl_logic;
        rbsp_ready      : in     vl_logic;
        rbsp_byte       : out    vl_logic_vector(7 downto 0);
        rbsp_last       : out    vl_logic
    );
end slice_controller;
