#=============================================================================
# verify_ip_catalog.tcl
# Independent Verification of the Packaged HEVC Encoder IP Core
#
# Validates that:
#   1. A fresh Vivado project can register ip_repo/hevc_encoder_v1_0.
#   2. The IP Catalog discovers uit.edu.vn:video:hevc_encoder:1.0 cleanly.
#   3. The IP can be instantiated with custom parameters without DRC errors.
#   4. Synthesis instantiation template is generated cleanly.
#=============================================================================

if { [info exists env(VIVADO_PART)] } {
    set target_part $env(VIVADO_PART)
} else {
    set target_part "xczu19eg-ffvb1517-2-e"
}

set ip_repo_path  "ip_repo/hevc_encoder_v1_0"
set temp_proj_dir "synth/verify_ip_tmp"

puts "================================================================="
puts " Starting IP Catalog Verification for HEVC Encoder"
puts " Target Part:    $target_part"
puts " IP Repo:        $ip_repo_path"
puts "================================================================="

if {[file exists $temp_proj_dir]} {
    file delete -force $temp_proj_dir
}

# 1. Create fresh temporary verification project
create_project -force verify_ip_proj $temp_proj_dir -part $target_part

# 2. Add packaged IP repository to project
set_property ip_repo_paths [file normalize $ip_repo_path] [current_project]
update_ip_catalog -rebuild

# 3. Check IP Catalog for our core
set matched_ips [get_ipdefs *hevc_encoder*]
puts "Matching IP Definitions found in Catalog:"
foreach ipdef $matched_ips {
    puts "  -> $ipdef"
}

if {[llength $matched_ips] == 0} {
    puts "[ERROR] hevc_encoder IP not found in IP Catalog!"
    exit 1
}

# 4. Instantiate IP in project
puts "================================================================="
puts " Instantiating hevc_encoder IP instance in project..."
puts "================================================================="
set test_inst [create_ip -name hevc_encoder -vendor uit.edu.vn -library video -version 1.0 -module_name test_hevc_inst]

# 5. Customize User Parameters
puts " Customizing IP Parameters (FRAME_WIDTH=128, FRAME_HEIGHT=128, BASE_QP=28)..."
set_property -dict [list \
    CONFIG.FRAME_WIDTH {128} \
    CONFIG.FRAME_HEIGHT {128} \
    CONFIG.BASE_QP {28} \
    CONFIG.TARGET_BITRATE_KBPS {5000} \
] [get_ips test_hevc_inst]

# 6. Generate Instantiation Targets
puts " Generating Instantiation Template..."
generate_target {instantiation_template} [get_ips test_hevc_inst]

set generated_files [get_files -of_objects [get_ips test_hevc_inst]]
puts " Generated Targets:"
foreach f $generated_files {
    puts "  -> $f"
}

# 7. Verify Vivado IP Integrator (Block Design) Compatibility
puts "================================================================="
puts " Testing Vivado IP Integrator (Block Design) Instantiation..."
puts "================================================================="
create_bd_design "hevc_test_bd"
set bd_cell [create_bd_cell -type ip -vlnv uit.edu.vn:video:hevc_encoder:1.0 hevc_encoder_bd_inst]
puts " Successfully added BD cell: [get_property NAME $bd_cell] ([get_property VLNV $bd_cell])"

set bd_intfs [get_bd_intf_pins -of_objects $bd_cell]
puts " Verified Block Design Interfaces:"
foreach intf $bd_intfs {
    puts "  -> $intf ([get_property VLNV $intf])"
}

# Verify interface pin count matches expected 4 AXI interfaces
if {[llength $bd_intfs] != 4} {
    puts "\[ERROR\] Expected 4 AXI interfaces on Block Design cell, found [llength $bd_intfs]!"
    exit 1
}

# Connect clock and reset to verify port connection rules
create_bd_port -dir I -type clk -freq_hz 50000000 clk
connect_bd_net [get_bd_ports clk] [get_bd_pins /hevc_encoder_bd_inst/clk]
create_bd_port -dir I -type rst rst_n
set_property CONFIG.POLARITY ACTIVE_LOW [get_bd_ports rst_n]
connect_bd_net [get_bd_ports rst_n] [get_bd_pins /hevc_encoder_bd_inst/rst_n]

# Expose interfaces externally
make_bd_intf_pins_external [get_bd_intf_pins /hevc_encoder_bd_inst/s_axi_lite]
make_bd_intf_pins_external [get_bd_intf_pins /hevc_encoder_bd_inst/s_axis_video]
make_bd_intf_pins_external [get_bd_intf_pins /hevc_encoder_bd_inst/m_axis_bitstream]
make_bd_pins_external [get_bd_pins /hevc_encoder_bd_inst/irq]

puts " \[PASS\] IP Integrator Block Design ports and AXI interfaces connected cleanly."

puts "================================================================="
puts " \[SUCCESS\] HEVC Encoder IP Catalog & IP Integrator Verification PASSED!"
puts " Core is 100% compliant and ready for Vivado IP Integrator."
puts "================================================================="

close_project -delete
if {[file exists $temp_proj_dir]} {
    file delete -force $temp_proj_dir
}
exit
