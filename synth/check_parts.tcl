puts "Available parts sample:"
set parts [get_parts -filter {FAMILY == zynquplus || FAMILY == kintexu || FAMILY == kintex7 || FAMILY == artix7}]
if {[llength $parts] > 0} {
    puts "Found [llength $parts] parts."
    puts "First 5: [lrange $parts 0 4]"
    set zu [get_parts *xczu9eg*]
    puts "Matching xczu9eg: $zu"
    set k7 [get_parts *xc7k325t*]
    puts "Matching xc7k325t: $k7"
} else {
    puts "All parts count: [llength [get_parts *]]"
    puts "Sample parts: [lrange [get_parts *] 0 10]"
}
exit
