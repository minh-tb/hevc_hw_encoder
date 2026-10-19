#=============================================================================
# package_ip.tcl
# Vivado Automated IP Packaging Script for HEVC/H.265 Hardware Video Encoder
#
# Creates IEEE 1685-2009 / IP-XACT compliant component.xml in ip_repo/
# Configures AXI4-Lite, AXI4-Stream, and AXI4 Master interfaces and XGUI.
#=============================================================================

# 1. Configuration & Part Selection
if { [info exists env(VIVADO_PART)] } {
    set target_part $env(VIVADO_PART)
} else {
    set target_part "xczu19eg-ffvb1517-2-e"
}

set top_module    "hevc_encoder_axi_top"
set ip_root_dir   "ip_repo/hevc_encoder_v1_0"
set temp_proj_dir "synth/ip_pack_tmp"

puts "================================================================="
puts " Packaging HEVC Hardware Encoder IP for part: $target_part"
puts " Top Module:     $top_module"
puts " Target Output:  $ip_root_dir"
puts "================================================================="

# Clean any existing temporary project
if {[file exists $temp_proj_dir]} {
    file delete -force $temp_proj_dir
}

# 2. Create Temporary Packaging Project
create_project -force ip_pack_tmp $temp_proj_dir -part $target_part

# 3. Add Verilog Headers
set header_files [list \
    "rtl/common/parameter_pkg.vh" \
    "rtl/common/hevc_interfaces.vh" \
    "rtl/common/slice_cases.vh" \
    "rtl/common/init_tables.vh" \
]
add_files -norecurse $header_files
set_property file_type "Verilog Header" [get_files $header_files]
set_property is_global_include true [get_files $header_files]

# 4. Add Synthesizable RTL Sources
set rtl_files [list \
    "rtl/common/axi_read_arbiter.v" \
    "rtl/common/clk_gate.v" \
    "rtl/common/fifo_sync.v" \
    "rtl/common/hadamard_satd_4x4.v" \
    "rtl/common/pipeline_reg.v" \
    "rtl/common/ram_dp_10b.v" \
    "rtl/common/ram_sp_generic.v" \
    "rtl/common/radix2_div_signed.v" \
    "rtl/entropy/bin_decoder.v" \
    "rtl/entropy/bin_encoder.v" \
    "rtl/entropy/cabac_dec_top.v" \
    "rtl/entropy/cabac_enc_top.v" \
    "rtl/entropy/coeff_buffer.v" \
    "rtl/entropy/ctx_model_store.v" \
    "rtl/entropy/param_set_writer.v" \
    "rtl/entropy/range_coder.v" \
    "rtl/entropy/syntax_coeff.v" \
    "rtl/entropy/syntax_cu.v" \
    "rtl/entropy/syntax_dec_coeff.v" \
    "rtl/entropy/syntax_dec_cu.v" \
    "rtl/entropy/syntax_dec_pred.v" \
    "rtl/entropy/syntax_pred.v" \
    "rtl/entropy/syntax_sao.v" \
    "rtl/inloop_filters/boundary_strength.v" \
    "rtl/inloop_filters/db_filter_chroma.v" \
    "rtl/inloop_filters/db_filter_luma.v" \
    "rtl/inloop_filters/deblock_top.v" \
    "rtl/inloop_filters/sao_band_offset.v" \
    "rtl/inloop_filters/sao_edge_offset.v" \
    "rtl/inloop_filters/sao_stats.v" \
    "rtl/inloop_filters/sao_top.v" \
    "rtl/inloop_filters/sao_window_buffer.v" \
    "rtl/input_output/input_buffer.v" \
    "rtl/input_output/nal_parser.v" \
    "rtl/input_output/nal_writer.v" \
    "rtl/input_output/output_fifo.v" \
    "rtl/inter/fme_search.v" \
    "rtl/inter/hpel_filter_chroma.v" \
    "rtl/inter/hpel_filter_luma.v" \
    "rtl/inter/inter_pred_top.v" \
    "rtl/inter/mc_unit.v" \
    "rtl/inter/mvp_predictor.v" \
    "rtl/inter/ref_frame_buffer.v" \
    "rtl/inter/sad_4x4.v" \
    "rtl/inter/sad_8x8.v" \
    "rtl/inter/streaming_subpel_filter.v" \
    "rtl/inter/subpel_interpolation_core.v" \
    "rtl/inter/tz_search.v" \
    "rtl/intra/intra_angular.v" \
    "rtl/intra/intra_dc.v" \
    "rtl/intra/intra_planar.v" \
    "rtl/intra/intra_rmd.v" \
    "rtl/intra/intra_pred_top.v" \
    "rtl/intra/ref_sample_filter.v" \
    "rtl/partition/ctu_partitioner.v" \
    "rtl/partition/ctu_raster_scan.v" \
    "rtl/partition/mode_decision.v" \
    "rtl/partition/pu_cu_splitter.v" \
    "rtl/partition/rate_estimator.v" \
    "rtl/quant/fwd_quant.v" \
    "rtl/quant/inv_quant.v" \
    "rtl/rate_control/lambda_calc.v" \
    "rtl/rate_control/rate_controller.v" \
    "rtl/recon/frame_store.v" \
    "rtl/recon/recon_unit.v" \
    "rtl/recon/residual_sub.v" \
    "rtl/top/address_generator.v" \
    "rtl/top/decoder_inloop_filters.v" \
    "rtl/top/gop_controller.v" \
    "rtl/top/hevc_decoder_top.v" \
    "rtl/top/hevc_encoder_top.v" \
    "rtl/top/prediction_unit.v" \
    "rtl/top/slice_controller.v" \
    "rtl/transform/transform_1d_core.v" \
    "rtl/transform/transpose_ram_32x32.v" \
    "rtl/transform/dct_top.v" \
    "rtl/top/hevc_encoder_axi_top.v" \
]
add_files -norecurse $rtl_files
set_property file_type "SystemVerilog" [get_files $rtl_files]

# 5. Add Constraints
add_files -norecurse "synth/hevc_encoder_top.xdc"

# Set project top and include directories
set_property top $top_module [current_fileset]
set_property include_dirs [list "rtl/common"] [current_fileset]
update_compile_order -fileset sources_1

# 6. Package Project into Target IP Directory
if {[file exists $ip_root_dir]} {
    file delete -force $ip_root_dir
}
file mkdir $ip_root_dir

ipx::package_project -root_dir $ip_root_dir -vendor "uit.edu.vn" -library "video" -taxonomy "/Video_&_Image_Processing" -import_files -set_current true

set core [ipx::current_core]

# Ensure subpel_interpolation_core.v is imported and packaged
file copy -force "rtl/inter/subpel_interpolation_core.v" "$ip_root_dir/src/subpel_interpolation_core.v"
foreach fg_name {xilinx_anylanguagesynthesis xilinx_anylanguagebehavioralsimulation} {
    set fg [ipx::get_file_groups $fg_name -of_objects $core]
    if {$fg ne ""} {
        set existing [ipx::get_files "src/subpel_interpolation_core.v" -of_objects $fg]
        if {$existing eq ""} {
            set subpel_f [ipx::add_file "src/subpel_interpolation_core.v" $fg]
            set_property type systemVerilogSource $subpel_f
        }
    }
}

# Clean up any non-relative file references that might have been detected from root working directory
foreach fg [ipx::get_file_groups -of_objects $core] {
    foreach f [ipx::get_files -of_objects $fg] {
        set fn [get_property name $f]
        if {[string match "*hevc_hw_encoder/slice_cases.vh" $fn] || [string match "*hevc_hw_encoder/init_tables.vh" $fn]} {
            catch {ipx::remove_file $fn $fg}
        }
    }
}

# 7. Configure Core Metadata
set_property name "hevc_encoder" $core
set_property display_name "HEVC/H.265 Hardware Video Encoder" $core
set_property description "High-Performance HEVC/H.265 Hardware Video Encoder Core with AXI4-Lite CSR, AXI4-Stream Video/Bitstream, and AXI4 Master DRAM Interfaces" $core
set_property version "1.0" $core
set_property vendor_display_name "UIT" $core
set_property company_url "https://uit.edu.vn" $core

# 8. Configure Clock and Reset Bus Interfaces
set clk_intf [ipx::get_bus_interfaces clk -of_objects $core]
if {$clk_intf ne ""} {
    set busif_param [ipx::get_bus_parameters ASSOCIATED_BUSIF -of_objects $clk_intf]
    if {$busif_param eq ""} {
        set busif_param [ipx::add_bus_parameter ASSOCIATED_BUSIF $clk_intf]
    }
    set_property VALUE "s_axi_lite:s_axis_video:m_axis_bitstream:m_axi_mem" $busif_param

    set rst_param [ipx::get_bus_parameters ASSOCIATED_RESET -of_objects $clk_intf]
    if {$rst_param eq ""} {
        set rst_param [ipx::add_bus_parameter ASSOCIATED_RESET $clk_intf]
    }
    set_property VALUE "rst_n" $rst_param

    set freq_param [ipx::get_bus_parameters FREQ_HZ -of_objects $clk_intf]
    if {$freq_param eq ""} {
        set freq_param [ipx::add_bus_parameter FREQ_HZ $clk_intf]
    }
    set_property VALUE "50000000" $freq_param
}

set rst_intf [ipx::get_bus_interfaces rst_n -of_objects $core]
if {$rst_intf ne ""} {
    set pol_param [ipx::get_bus_parameters POLARITY -of_objects $rst_intf]
    if {$pol_param eq ""} {
        set pol_param [ipx::add_bus_parameter POLARITY $rst_intf]
    }
    set_property VALUE "ACTIVE_LOW" $pol_param
}

# 9. Configure Interrupt Interface
set irq_intf [ipx::get_bus_interfaces irq -of_objects $core]
if {$irq_intf ne ""} {
    set sens_param [ipx::get_bus_parameters SENSITIVITY -of_objects $irq_intf]
    if {$sens_param eq ""} {
        set sens_param [ipx::add_bus_parameter SENSITIVITY $irq_intf]
    }
    set_property VALUE "LEVEL_HIGH" $sens_param
}

# 10. Configure AXI4-Lite Slave Memory Map
set mem_map [ipx::get_memory_maps s_axi_lite -of_objects $core]
if {$mem_map eq ""} {
    set mem_map [ipx::add_memory_map "s_axi_lite" $core]
    set addr_block [ipx::add_address_block "reg0" $mem_map]
    set_property range "4096" $addr_block
    set_property width "32" $addr_block
    set_property slave_memory_map_ref "s_axi_lite" [ipx::get_bus_interfaces s_axi_lite -of_objects $core]
}

# 11. Configure User Configurable Parameters in Vivado GUI
foreach p {FRAME_WIDTH FRAME_HEIGHT GOP_STRUCTURE BASE_QP RC_ENABLE TARGET_BITRATE_KBPS} {
    set user_param [ipx::get_user_parameters $p -of_objects $core]
    if {$user_param ne ""} {
        set_property value_resolve_type "user" $user_param
    }
}

# Set parameter display names and descriptions
catch {
    set_property display_name "Frame Width" [ipx::get_user_parameters FRAME_WIDTH -of_objects $core]
    set_property description "Luma Frame Width in Pixels (e.g., 64, 128, 256, 1920, 3840)" [ipx::get_user_parameters FRAME_WIDTH -of_objects $core]
    set_property display_name "Frame Height" [ipx::get_user_parameters FRAME_HEIGHT -of_objects $core]
    set_property description "Luma Frame Height in Pixels (e.g., 64, 128, 256, 1080, 2160)" [ipx::get_user_parameters FRAME_HEIGHT -of_objects $core]
    set_property display_name "GOP Structure" [ipx::get_user_parameters GOP_STRUCTURE -of_objects $core]
    set_property description "0: IPP (Low Latency), 1: IPBB (Low-Delay B), 2: Hierarchical B" [ipx::get_user_parameters GOP_STRUCTURE -of_objects $core]
    set_property display_name "Base QP" [ipx::get_user_parameters BASE_QP -of_objects $core]
    set_property description "Default Quantization Parameter [0..51]" [ipx::get_user_parameters BASE_QP -of_objects $core]
    set_property display_name "Rate Control Enable" [ipx::get_user_parameters RC_ENABLE -of_objects $core]
    set_property description "1: Enable Rate Control, 0: Fixed QP" [ipx::get_user_parameters RC_ENABLE -of_objects $core]
    set_property display_name "Target Bitrate (kbps)" [ipx::get_user_parameters TARGET_BITRATE_KBPS -of_objects $core]
    set_property description "Target Bitrate in kbps" [ipx::get_user_parameters TARGET_BITRATE_KBPS -of_objects $core]
}

# 12. Generate XGUI Customization Script
ipx::create_xgui_files $core

# 13. Declare Supported FPGA Architectures
set fam_list [list \
    "zynquplus" "Production" \
    "virtex7"   "Production" \
    "kintex7"   "Production" \
    "zynq"      "Production" \
]
set_property supported_families $fam_list $core

# 14. Run IP Integrity DRC Check
puts "================================================================="
puts " Running IP Integrity Checks..."
puts "================================================================="
set check_status [ipx::check_integrity $core]
puts "ipx::check_integrity status: $check_status"

# 15. Save Core & Update Checksums
ipx::save_core $core

puts "================================================================="
puts " HEVC Encoder IP Successfully Packaged!"
puts " Location: [file normalize $ip_root_dir]"
puts " Manifest: [file normalize $ip_root_dir/component.xml]"
puts "================================================================="

close_project -delete
if {[file exists $temp_proj_dir]} {
    file delete -force $temp_proj_dir
}
exit 0
