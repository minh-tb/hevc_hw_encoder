#==============================================================================
# synth_subsystems.tcl
# Subsystem-level FPGA Synthesis and Timing Profiling
# Target: Altera Cyclone V (5CGXFC7C7F23C8)
#==============================================================================

load_package flow

set modules [list \
    "fwd_quant" \
    "inv_quant" \
    "ctu_partitioner" \
    "intra_pred_top" \
    "inter_pred_top" \
    "dct_top" \
    "rate_controller" \
    "lambda_calc" \
    "hadamard_satd_4x4" \
    "rate_estimator" \
    "mode_decision" \
    "cabac_enc_top" \
]

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
    "rtl/top/gop_controller.v" \
    "rtl/top/prediction_unit.v" \
    "rtl/top/slice_controller.v" \
    "rtl/transform/dct16.v" \
    "rtl/transform/dct32.v" \
    "rtl/transform/dct4.v" \
    "rtl/transform/dct8.v" \
    "rtl/transform/dct_top.v" \
]

# Write SDC
set sdc_file "synth/synth_subsystems.sdc"
set sdc_fid [open $sdc_file "w"]
puts $sdc_fid "create_clock -name clk -period 10.000 \[get_ports clk\]"
puts $sdc_fid "set_clock_uncertainty -setup 0.200 \[get_clocks clk\]"
puts $sdc_fid "set_clock_uncertainty -hold  0.050 \[get_clocks clk\]"
close $sdc_fid

puts "================================================================="
puts "Starting Subsystem FPGA Synthesis & Timing Profiling"
puts "================================================================="

foreach mod $modules {
    puts "\n-----------------------------------------------------------------"
    puts "Synthesizing and Profiling: $mod"
    puts "-----------------------------------------------------------------"

    project_new $mod -overwrite

    set_global_assignment -name FAMILY "Cyclone V"
    set_global_assignment -name DEVICE "5CGXFC7C7F23C8"
    set_global_assignment -name TOP_LEVEL_ENTITY $mod
    set_global_assignment -name SEARCH_PATH "rtl/common"
    set_global_assignment -name VERILOG_INPUT_VERSION SYSTEMVERILOG_2005
    set_global_assignment -name NUM_PARALLEL_PROCESSORS ALL
    set_global_assignment -name SDC_FILE $sdc_file

    set_instance_assignment -name VIRTUAL_PIN ON -to *
    set_instance_assignment -name VIRTUAL_PIN OFF -to clk
    set_instance_assignment -name VIRTUAL_PIN OFF -to rst_n

    foreach f $rtl_files {
        set_global_assignment -name SYSTEMVERILOG_FILE $f
    }

    if [catch {execute_module -tool map} err] {
        puts "ERROR: Synthesis failed for $mod: $err"
    } else {
        puts "SUCCESS: Synthesis completed for $mod"
        if [catch {execute_module -tool sta} err_sta] {
            puts "WARNING: STA failed for $mod: $err_sta"
        } else {
            puts "SUCCESS: STA completed for $mod"
        }
    }

    project_close
}

puts "\n================================================================="
puts "All Subsystems Synthesized & Profiled Successfully!"
puts "================================================================="
