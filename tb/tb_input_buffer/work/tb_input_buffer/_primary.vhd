library verilog;
use verilog.vl_types.all;
entity tb_input_buffer is
    generic(
        FRAME_WIDTH     : integer := 3840;
        FRAME_HEIGHT    : integer := 2160
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of FRAME_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of FRAME_HEIGHT : constant is 1;
end tb_input_buffer;
