library verilog;
use verilog.vl_types.all;
entity address_generator is
    port(
        tu_size_log2    : in     vl_logic_vector(2 downto 0);
        scan_mode       : in     vl_logic_vector(1 downto 0);
        scan_idx        : in     vl_logic_vector(9 downto 0);
        addr_x          : out    vl_logic_vector(4 downto 0);
        addr_y          : out    vl_logic_vector(4 downto 0)
    );
end address_generator;
