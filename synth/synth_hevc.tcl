#=============================================================================
# synth_hevc.tcl
# Quartus II Synthesis & Static Timing Analysis Script for HEVC Hardware Encoder
# Target Family: Cyclone V / Stratix V
#=============================================================================

load_package flow
load_package report

set project_name "hevc_encoder_top"

# 1. Create Project
if {[project_exists $project_name]} {
    project_open $project_name -current_revision
} else {
    project_new $project_name -family "Cyclone V" -part "5CGXFC7D6F31C6"
}

set_global_assignment -name TOP_LEVEL_ENTITY hevc_encoder_top
set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE "5CGXFC7D6F31C6"
set_global_assignment -name VERILOG_INPUT_VERSION SYSTEMVERILOG_2005
set_global_assignment -name NUM_PARALLEL_PROCESSORS ALL
set_global_assignment -name VERILOG_CONSTANT_LOOP_LIMIT 50000
set_global_assignment -name VERILOG_MACRO "SYNTHESIS=1"
set_global_assignment -name OPTIMIZATION_TECHNIQUE BALANCED
set_global_assignment -name PHYSICAL_SYNTHESIS_COMBO_LOGIC OFF
set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_RETIMING OFF
set_global_assignment -name SYNTH_TIMING_DRIVEN_SYNTHESIS OFF
set_global_assignment -name OPTIMIZE_HOLD_TIMING "ALL PATHS"
set_global_assignment -name OPTIMIZE_MULTI_CORNER_TIMING ON
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files

# Enable Virtual Pins for high-bandwidth internal bus interfaces (AXI 256-bit)
set_instance_assignment -name VIRTUAL_PIN ON -to *
set_instance_assignment -name VIRTUAL_PIN OFF -to clk
set_instance_assignment -name VIRTUAL_PIN OFF -to rst_n

# Include directories
set_global_assignment -name SEARCH_PATH "rtl/common"
set_global_assignment -name SEARCH_PATH "rtl/entropy"
set_global_assignment -name SEARCH_PATH "rtl/inloop_filters"
set_global_assignment -name SEARCH_PATH "rtl/input_output"
set_global_assignment -name SEARCH_PATH "rtl/inter"
set_global_assignment -name SEARCH_PATH "rtl/intra"
set_global_assignment -name SEARCH_PATH "rtl/partition"
set_global_assignment -name SEARCH_PATH "rtl/quant"
set_global_assignment -name SEARCH_PATH "rtl/rate_control"
set_global_assignment -name SEARCH_PATH "rtl/recon"
set_global_assignment -name SEARCH_PATH "rtl/top"
set_global_assignment -name SEARCH_PATH "rtl/transform"

# Add RTL source files
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
    "rtl/transform/dct16.v" \
    "rtl/transform/dct32.v" \
    "rtl/transform/dct4.v" \
    "rtl/transform/dct8.v" \
    "rtl/transform/dct_top.v" \
]

foreach file $rtl_files {
    set_global_assignment -name SYSTEMVERILOG_FILE $file
}

# Create SDC Timing Constraint
set sdc_file [open "synth/hevc_encoder_top.sdc" "w"]
puts $sdc_file "# SDC Timing Constraint for HEVC Hardware Encoder"
puts $sdc_file "# Target Clock: 200 MHz (Period: 5.000 ns)"
puts $sdc_file "create_clock -name clk -period 5.000 \[get_ports clk\]"
puts $sdc_file "derive_clock_uncertainty"
close $sdc_file
set_global_assignment -name SDC_FILE "synth/hevc_encoder_top.sdc"

export_assignments

# 2. Run Analysis & Synthesis (quartus_map)
puts "================================================================="
puts "Running Quartus Analysis & Synthesis (quartus_map)..."
puts "================================================================="
execute_module -tool map

# 3. Run Fitter / Place & Route (quartus_fit)
puts "================================================================="
puts "Running Quartus Fitter / Place & Route (quartus_fit)..."
puts "================================================================="
execute_module -tool fit

# 4. Run Static Timing Analysis (quartus_sta)
puts "================================================================="
puts "Running TimeQuest Static Timing Analysis (quartus_sta)..."
puts "================================================================="
execute_module -tool sta -args "--report_script=synth/report_timing.tcl"

project_close
puts "Synthesis and STA flow completed successfully."
