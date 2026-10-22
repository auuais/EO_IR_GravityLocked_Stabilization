# Standalone construct/resource check only: no implementation or hardware I/O.
# Run with Vivado 2025.2, for example from builds/frame_pose:
#   vivado -mode batch -source ../../scripts/synth_gl_frame_pose.tcl
# Reports/checkpoint are written only beneath builds/frame_pose.
set task_root [file normalize [file join [file dirname [info script]] ..]]
set task_build [file join $task_root builds frame_pose]
file mkdir $task_build
cd $task_build

set task_projection [file join $task_root src GlCameraProjection.v]
set task_controller [file join $task_root src GlFramePose.v]
set task_angles [file join $task_root reference gravity_math angle_centi_q15.mem]
set task_atan [file join $task_root reference gravity_math atan_ratio_centi.mem]
foreach task_file [list $task_projection $task_controller $task_angles $task_atan] {
    if {![file isfile $task_file]} { error "Required file is missing: $task_file" }
}

read_verilog [list $task_projection $task_controller]
synth_design -top GlFramePose -part xcku15p-ffve1517-2-i \
    -mode out_of_context -flatten_hierarchy rebuilt \
    -generic [list "ANGLE_ROM_FILE=\"$task_angles\"" "ATAN_ROM_FILE=\"$task_atan\""]
create_clock -name ui_clk -period 4.292 [get_ports clk]
report_utilization -file [file join $task_build utilization_synth.rpt]
report_timing_summary -delay_type min_max -max_paths 10 \
    -file [file join $task_build timing_synth.rpt]
write_checkpoint -force [file join $task_build GlFramePose_synth.dcp]
puts "PASS GlFramePose standalone synthesis: $task_build"
puts "Post-synthesis estimates do not establish routed 233 MHz timing closure."
