proc audit {path label} {
 puts "AUDIT_BEGIN $label $path"
 open_checkpoint $path
 puts "AUDIT_PART [get_property PART [current_design]]"
 foreach prop [list_property [current_design]] {
  if {[regexp -nocase {DCI|MATCH_CYCLE} $prop]} {puts "AUDIT_DESIGN $prop=[get_property $prop [current_design]]"}
 }
 foreach bn {66 67 68} {
  set b [get_iobanks $bn]
  foreach prop [list_property $b] {
   if {[regexp -nocase {DCI|MASTER|VREF|VCCO|BANK_TYPE} $prop]} {puts "AUDIT_BANK $bn $prop=[get_property $prop $b]"}
  }
 }
 puts "AUDIT_DCIRESET [llength [get_cells -hier -quiet -filter {REF_NAME == DCIRESET}]]"
 foreach port [get_ports -quiet {*ddr4*}] {
  set pin [get_property PACKAGE_PIN $port]
  set pn [get_package_pins -quiet $pin]
  set bank [get_property BANK $pn]
  puts "AUDIT_PORT $port PIN=$pin BANK=$bank STD=[get_property IOSTANDARD $port]"
 }
 foreach p [get_package_pins -quiet {AU27 AR29 AP30}] {puts "AUDIT_VRP $p [get_property PIN_FUNC $p] BANK=[get_property BANK $p]"}
 foreach p [get_pins -hier -quiet -filter {REF_PIN_NAME == DCITERMDISABLE}] {
  set net [get_nets -quiet -of_objects $p]
  set driver [get_pins -quiet -of_objects $net -filter {DIRECTION == OUT}]
  puts "AUDIT_DCITERMDISABLE $p NET=$net DRIVER=$driver"
 }
 close_design
 puts "AUDIT_END $label"
}
audit {E:/Xylinx/EO_IR_GravityLocked_Stabilization/builds/gravity_20261022_235934/routed.dcp} latest
audit {E:/Xylinx/EO_Panorama_V19_RollPitch/EO_Panorama_V19_M1.runs/impl_1/KintexTop_EO_IR_HD_SDI_panorama_base_routed.dcp} stable
exit
