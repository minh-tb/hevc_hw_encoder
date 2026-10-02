#=============================================================================
# synth_vivado.tcl
# Vivado ML / Enterprise Synthesis Script for HEVC Hardware Encoder
# Target Part: Zynq UltraScale+ (xczu9eg-ffvb1156-2-e)
# Mode: Out-of-Context (OOC) Synthesis & Timing Analysis
#=============================================================================

set top_module "hevc_encoder_top"
set output_dir "synth/vivado_output"

# Default part: Zynq UltraScale+ MPSoC
if { [info exists env(VIVADO_PART)] } {
    set target_part $env(VIVADO_PART)
} else {
    set target_part "xczu9eg-ffvb1156-2-e"
}

file mkdir $output_dir

puts "================================================================="
puts " Starting Vivado Synthesis for $top_module on $target_part"
puts "================================================================="

# Enable multi-threaded synthesis (up to 6 physical cores)
catch {set_param general.maxThreads 6}

# 1. Create in-memory project
create_project -in_memory -part $target_part

# 2. Add header files and RTL sources
set header_files [list \
    "rtl/common/parameter_pkg.vh" \
    "rtl/common/hevc_interfaces.vh" \
]
read_verilog -sv $header_files

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
read_verilog -sv $rtl_files

# 3. Read Timing Constraints
read_xdc "synth/hevc_encoder_top.xdc"

# 4. Run Out-of-Context Synthesis
puts "================================================================="
puts " Running synth_design on $top_module..."
puts "================================================================="
synth_design -top $top_module -part $target_part -mode out_of_context -verilog_define {SYNTHESIS=1}

# 5. Generate Reports
puts "================================================================="
puts " Generating Synthesis & Timing Reports..."
puts "================================================================="
report_utilization -file "$output_dir/utilization_synth.rpt" -pb "$output_dir/utilization_synth.pb"
report_timing_summary -file "$output_dir/timing_summary_synth.rpt" -delay_type max -max_paths 10
report_power -file "$output_dir/power_synth.rpt"

puts "================================================================="
puts " Vivado Synthesis Flow Completed Successfully!"
puts " Reports saved to: $output_dir"
puts "================================================================="
exit
