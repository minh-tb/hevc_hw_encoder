library verilog;
use verilog.vl_types.all;
entity clk_gate is
    port(
        clk_in          : in     vl_logic;
        enable          : in     vl_logic;
        test_en         : in     vl_logic;
        clk_out         : out    vl_logic
    );
end clk_gate;
