library verilog;
use verilog.vl_types.all;
entity gop_controller is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        encode_start    : in     vl_logic;
        total_frames    : in     vl_logic_vector(15 downto 0);
        encode_done     : out    vl_logic;
        frame_start     : out    vl_logic;
        frame_done      : in     vl_logic;
        frame_poc       : out    vl_logic_vector(9 downto 0);
        frame_slice_type: out    vl_logic_vector(1 downto 0);
        temporal_id     : out    vl_logic_vector(2 downto 0);
        nal_type        : out    vl_logic_vector(5 downto 0);
        alloc_valid     : out    vl_logic;
        alloc_ready     : in     vl_logic;
        alloc_poc       : out    vl_logic_vector(9 downto 0);
        alloc_slot      : in     vl_logic_vector(2 downto 0);
        free_valid      : out    vl_logic;
        free_slot       : out    vl_logic_vector(2 downto 0);
        ref_l0          : out    vl_logic_vector(14 downto 0);
        ref_l1          : out    vl_logic_vector(14 downto 0);
        ref_l0_count    : out    vl_logic_vector(2 downto 0);
        ref_l1_count    : out    vl_logic_vector(2 downto 0)
    );
end gop_controller;
