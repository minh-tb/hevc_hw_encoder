# TCL script to check Quartus device families
package require ::quartus::project
puts "Available device families:"
foreach family [get_device_families] {
    puts "  Family: $family"
}
