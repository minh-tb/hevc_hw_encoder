library verilog;
use verilog.vl_types.all;
entity tb_ram_sp_generic is
    generic(
        DATA_WIDTH      : integer := 32;
        DEPTH           : integer := 16;
        ADDR_WIDTH      : integer := 4;
        INIT_VAL        : vl_logic_vector(31 downto 0) := (Hi1, Hi1, Hi0, Hi1, Hi1, Hi1, Hi1, Hi0, Hi1, Hi0, Hi1, Hi0, Hi1, Hi1, Hi0, Hi1, Hi1, Hi0, Hi1, Hi1, Hi1, Hi1, Hi1, Hi0, Hi1, Hi1, Hi1, Hi0, Hi1, Hi1, Hi1, Hi1)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of DATA_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of DEPTH : constant is 1;
    attribute mti_svvh_generic_type of ADDR_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of INIT_VAL : constant is 1;
end tb_ram_sp_generic;
