# TimeQuest reporting script
report_timing -setup -npaths 5 -detail full_path -panel_name "Setup Summary"
report_timing -hold -npaths 5 -detail full_path -panel_name "Hold Summary"
report_clock_fmax_summary -panel_name "Fmax Summary"
