# Standalone construct/resource check only: no implementation or hardware I/O.
# Run with Vivado 2025.2, for example from builds/camera_projection:
#   vivado -mode batch -source ../../scripts/synth_gl_camera_projection.tcl
# Reports/checkpoint are written only beneath builds/camera_projection.
set task_root [file normalize [file join [file dirname [info script]] ..]]
set task_build [file join $task_root builds camera_projection]
file mkdir $task_build
cd $task_build

set task_rtl [file join $task_root src GlCameraProjection.v]
set task_angles [file join $task_root reference gravity_math angle_centi_q15.mem]
set task_atan [file join $task_root reference gravity_math atan_ratio_centi.mem]
foreach task_file [list $task_rtl $task_angles $task_atan] {
    if {![file isfile $task_file]} { error "Required file is missing: $task_file" }
}

read_verilog $task_rtl
synth_design -top GlCameraProjection -part xcku15p-ffve1517-2-i \
    -mode out_of_context -flatten_hierarchy rebuilt \
    -generic [list "ANGLE_ROM_FILE=\"$task_angles\"" "ATAN_ROM_FILE=\"$task_atan\""]
create_clock -name ui_clk -period 4.291845 [get_ports clk]
report_utilization -file [file join $task_build utilization_synth.rpt]
report_timing_summary -delay_type min_max -max_paths 10 \
    -file [file join $task_build timing_synth.rpt]
write_checkpoint -force [file join $task_build GlCameraProjection_synth.dcp]
puts "GlCameraProjection standalone synthesis complete: $task_build"
puts "Post-synthesis estimates do not establish routed 233 MHz timing closure."
