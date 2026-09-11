# profile_timing.tcl - Run fit and sta on modules with virtual pins enabled
load_package flow
load_package report

set mods [list \
    "rate_controller" \
    "lambda_calc" \
    "hadamard_satd_4x4" \
    "rate_estimator" \
    "mode_decision" \
    "cabac_enc_top" \
    "fwd_quant" \
    "inv_quant" \
    "ctu_partitioner" \
]

set sdc_file "synth/synth_subsystems.sdc"

foreach mod $mods {
    puts "================================================================="
    puts "Fitting and Timing: $mod"
    puts "================================================================="
    project_open $mod -current_revision
    set_global_assignment -name SDC_FILE $sdc_file
    set_instance_assignment -name VIRTUAL_PIN ON -to *
    set_instance_assignment -name VIRTUAL_PIN OFF -to clk
    set_instance_assignment -name VIRTUAL_PIN OFF -to rst_n
    export_assignments

    if [catch {execute_module -tool fit} err_fit] {
        puts "ERROR: Fit failed for $mod: $err_fit"
    } else {
        if [catch {execute_module -tool sta -args "--report_script=synth/report_timing.tcl"} err_sta] {
            puts "ERROR: STA failed for $mod: $err_sta"
        } else {
            puts "SUCCESS: STA completed for $mod"
        }
    }
    project_close
}
