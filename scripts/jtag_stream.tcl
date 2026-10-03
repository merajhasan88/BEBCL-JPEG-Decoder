# jtag_stream.tcl - stream a JPEG into fpga_jtag_top over the USB-Blaster and read the result.
#   quartus_stp -t jtag_stream.tcl <file.jpg> [chunk_bytes]
# Prints "RESULT frames=<n> clocks=<decoder clocks> checksum=0x<chk> err=0x<err> overflow=<0|1>
# bytes=<n> wall_ms=<ms>".  Protocol: see rtl/jtag_stream_core.sv (IR 1 = data, 2 = result,
# 3 = control/status; DR bits are shifted LSB first).
set file  [lindex $argv 0]
set chunk [expr {[llength $argv] > 1 ? [lindex $argv 1] : 256}]

set fh [open $file r]; fconfigure $fh -translation binary; set data [read $fh]; close $fh
set nbytes [string length $data]

# find the USB-Blaster and the device on it
set hw ""
foreach h [get_hardware_names] { if {[string match "*USB-Blaster*" $h]} { set hw $h; break } }
if {$hw eq ""} { puts "ERROR no USB-Blaster"; exit 1 }
set dev [lindex [get_device_names -hardware_name $hw] 0]
open_device -hardware_name $hw -device_name $dev
device_lock -timeout 10000

proc ir {v} { device_virtual_ir_shift -instance_index 0 -ir_value $v -no_captured_ir_value }
# 64-bit DR scan, value and result as 16 hex digits
proc dr64 {v} { return [device_virtual_dr_shift -instance_index 0 -length 64 -dr_value $v -value_in_hex] }
set st [ir 3; dr64 0000000000000000]
if {[string range $st 0 1] ne "A5"} { puts "ERROR bad status word $st"; device_unlock; close_device; exit 1 }
set frames0 [scan [string range $st 2 3] %x]

set t0 [clock milliseconds]
ir 3; dr64 0000000000000001; dr64 0000000000000000          ;# restart: rising edge of bit 0
ir 1
for {set p 0} {$p < $nbytes} {incr p $chunk} {
  set n [expr {min($chunk, $nbytes - $p)}]
  # wait while the FIFO is at least half full (status bit 1)
  if {$p > 0} {
    while {1} {
      ir 3; set st [dr64 0000000000000000]
      if {([scan [string index $st 15] %x] & 2) == 0} break
    }
    ir 1
  }
  # bytes p..p+n-1, first byte shifted first = least significant byte of the DR value
  binary scan [string range $data $p [expr {$p + $n - 1}]] H* hex
  set rev ""
  for {set i [expr {2 * $n - 2}]} {$i >= 0} {incr i -2} { append rev [string range $hex $i [expr {$i + 1}]] }
  # the 16-bit sync word A5C3 goes first (least significant): the core ignores the header bits the
  # virtual-JTAG hub shifts in before it
  device_virtual_dr_shift -instance_index 0 -length [expr {8 * $n + 16}] -dr_value ${rev}A5C3 -value_in_hex -no_captured_dr_value
}
ir 3; dr64 0000000000000002                               ;# end of stream
# wait for the frame counter to move
set frames $frames0
for {set t 0} {$t < 100000 && $frames == $frames0} {incr t} {
  set st [dr64 0000000000000002]
  set frames [scan [string range $st 2 3] %x]
}
set t1 [clock milliseconds]
ir 2; set res [dr64 0000000000000000]
ir 3; set st [dr64 0000000000000000]
device_unlock
close_device

set chk [string range $res 0 7]
set cyc [scan [string range $res 8 15] %x]
set err [expr {[scan [string range $st 4 7] %x] & 0x1FFF}]
set ovf [expr {[scan [string index $st 15] %x] & 1}]
puts "RESULT frames=[expr {($frames - $frames0) & 255}] clocks=$cyc checksum=0x$chk err=0x[format %04X $err] overflow=$ovf bytes=$nbytes wall_ms=[expr {$t1 - $t0}]"
