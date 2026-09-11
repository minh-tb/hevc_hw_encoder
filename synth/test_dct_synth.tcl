# Test synthesis of individual DCT sizes
load_package flow

set dct_mods [list "dct4" "dct8" "dct16"]

foreach mod $dct_mods {
    puts "================================================================="
    puts "Synthesizing $mod..."
    puts "================================================================="
    project_new $mod -overwrite
    set_global_assignment -name FAMILY "Cyclone V"
    set_global_assignment -name DEVICE "5CGXFC7C7F23C8"
    set_global_assignment -name TOP_LEVEL_ENTITY $mod
    set_global_assignment -name SEARCH_PATH "rtl/common"
    set_global_assignment -name SYSTEMVERILOG_FILE "rtl/transform/$mod.v"
    
    if [catch {execute_module -tool map} err] {
        puts "ERROR: $mod failed: $err"
    } else {
        puts "SUCCESS: $mod map passed"
    }
    project_close
}
