# Recreate a local, relocatable development project from baseline 3479cac.
# This entry point does not open the inherited XPR, generate/upgrade IP, launch
# synthesis/implementation, write a bitstream, or connect to hardware.
set project_root [file normalize [file join [file dirname [info script]] ..]]
set project_dir [file normalize [file join $project_root builds vivado_project]]
set project_name EO_IR_GravityLocked_Stabilization
set target_part xcku15p-ffve1517-2-i
set design_top KintexTop_EO_IR_HD_SDI_panorama_base
if {[llength $argv] != 0} { error "This entry point takes no Tcl arguments" }
if {![string match "2025.2*" [version -short]]} {
    error "Use Vivado 2025.2, matching the selected 3479cac baseline"
}

proc gl_read_file {path} {
    set fh [open $path rb]
    set contents [read $fh]
    close $fh
    return $contents
}
proc gl_under_root {path root} {
    set path [string tolower [file normalize $path]]
    set root [string tolower [file normalize $root]]
    return [expr {$path eq $root || [string first "${root}/" "${path}/"] == 0}]
}
if {![gl_under_root $project_dir $project_root]} { error "Generated project escaped repository" }

# Read the inherited metadata only to guard against silently applying settings
# from a different baseline. Its stale Utils checkpoint is deliberately omitted.
set inherited_xpr [file join $project_root EO_Panorama_V19_M1.xpr]
set inherited_text [gl_read_file $inherited_xpr]
foreach required [list \
    {Name="Part" Val="xcku15p-ffve1517-2-i"} \
    {Name="Vivado Synthesis Defaults" Flow="Vivado Synthesis 2025"} \
    {Name="Vivado Implementation Defaults" Flow="Vivado Implementation 2025"}] {
    if {[string first $required $inherited_text] < 0} {
        error "Inherited XPR does not match the selected baseline settings: $required"
    }
}
set ip_paths [list \
    [file join $project_root ip ddr4_sub64 ddr4_sub64.xci] \
    [file join $project_root ip dbg_ila_0 dbg_ila_0.xci] \
    [file join $project_root ip dbg_ila_1 dbg_ila_1.xci]]
set ip_originals [dict create]
foreach path $ip_paths { dict set ip_originals $path [gl_read_file $path] }

file mkdir $project_dir
create_project $project_name $project_dir -part $target_part -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property default_lib xil_defaultlib [current_project]
set_property ip_output_repo [file join $project_dir cache ip] [current_project]
set_property ip_cache_permissions {read write} [current_project]
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]

# This helper restores the full source tree, including newly added Gl*.v files.
# It does not open another project or call legacy absolute-path helpers.
source [file join $project_root scripts v19_fileset.tcl]
v19_refresh_fileset $project_root 0
set gravity_xdc [file join $project_root constraints gravity_cdc.xdc]
v19_add_if_missing $gravity_xdc constrs_1
set_property PROCESSING_ORDER LATE [get_files $gravity_xdc]
# The MIG UI clock and final mailbox register endpoints exist after the OOC
# IP checkpoints are linked. Loading this during RTL synthesis only generates
# unresolved-clock/endpoint warnings; open_run loads implementation XDC before
# the guarded netlist audit and physical build.
set_property USED_IN_SYNTHESIS false [get_files $gravity_xdc]
set_property USED_IN_IMPLEMENTATION true [get_files $gravity_xdc]
foreach path [lsort [glob -nocomplain [file join $project_root sim *.sv]]] {
    v19_add_if_missing $path sim_1
}

# The baseline helper names only EO row-run files. Register all checked-in
# row-run/rollpitch ROMs as well, including the IR ROMs used by RpRenderer.
# Preserve ../../assets/... in inherited RTL: normal synthesis run directories
# are <project_dir>/<project_name>.runs/synth_1, two levels below project_dir.
# These copies are refreshed on every entry-point invocation.
set memory_paths [list]
foreach subdir {rowruns rollpitch} {
    set destination [file join $project_dir assets $subdir]
    file mkdir $destination
    foreach path [lsort [glob -nocomplain [file join $project_root assets $subdir *.mem]]] {
        v19_add_if_missing $path
        lappend memory_paths $path
        file copy -force $path [file join $destination [file tail $path]]
        if {[gl_read_file $path] ne [gl_read_file [file join $destination [file tail $path]]]} {
            error "ROM staging mismatch: $path"
        }
    }
}
# GlLeasePose forwards these paths to the exact-C angle engine. Keep the same
# two-level relative layout used by synthesis runs, and verify staged bytes.
set gravity_destination [file join $project_dir reference gravity_math]
file mkdir $gravity_destination
foreach name {angle_centi_q15.mem atan_ratio_centi.mem} {
    set path [file join $project_root reference gravity_math $name]
    if {![file exists $path]} { error "Missing gravity ROM: $path" }
    v19_add_if_missing $path
    lappend memory_paths $path
    set staged [file join $gravity_destination $name]
    file copy -force $path $staged
    if {[gl_read_file $path] ne [gl_read_file $staged]} { error "ROM staging mismatch: $path" }
}

set_property top $design_top [get_filesets sources_1]
set_property top $design_top [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property strategy {Vivado Synthesis Defaults} [get_runs synth_1]
set_property strategy {Vivado Implementation Defaults} [get_runs impl_1]
foreach run_name {synth_1 impl_1} {
    set run [get_runs $run_name]
    set_property AUTO_INCREMENTAL_CHECKPOINT 0 $run
    set_property INCREMENTAL_CHECKPOINT {} $run
}
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
v19_assert_fileset_complete $project_root

# Audit registered source paths and required files without elaborating a design.
set expected_design [lsort [concat \
    [glob -nocomplain [file join $project_root src *.v]] \
    [glob -nocomplain [file join $project_root src *.vh]] $ip_paths $memory_paths]]
set expected_sim [lsort [concat \
    [glob -nocomplain [file join $project_root sim *.v]] \
    [glob -nocomplain [file join $project_root sim *.sv]]]]
set expected_constraints [list \
    [file join $project_root constraints camera_base.xdc] \
    [file join $project_root constraints ddr4_sub64_firstpass.xdc] $gravity_xdc]
foreach fileset {sources_1 sim_1 constrs_1} expected [list \
    $expected_design $expected_sim $expected_constraints] {
    set registered [get_files -quiet -of_objects [get_filesets $fileset]]
    foreach path $expected {
        if {![file exists $path] || [lsearch -exact $registered [file normalize $path]] < 0} {
            error "Required file absent from $fileset: $path"
        }
    }
    foreach path $registered {
        if {![gl_under_root $path $project_root]} { error "External file in $fileset: $path" }
    }
}
foreach ip_name {ddr4_sub64 dbg_ila_0 dbg_ila_1} {
    if {[llength [get_ips -quiet $ip_name]] != 1} { error "IP was not loaded: $ip_name" }
}
if {[get_property TOP [get_filesets sources_1]] ne $design_top} { error "Unexpected top" }
if {[get_property PART [current_project]] ne $target_part} { error "Unexpected FPGA part" }

report_ip_status -file [file join $project_dir ip_status.txt]
report_compile_order -fileset sources_1 -file [file join $project_dir compile_order.txt]
set manifest [open [file join $project_dir project_manifest.txt] w]
puts $manifest "Baseline: 3479cacf2e512a5bde9aa3e0243755826e071ef4"
puts $manifest "Vivado: [version -short]"
puts $manifest "Repository: $project_root"
puts $manifest "Project: [file join $project_dir ${project_name}.xpr]"
puts $manifest "Part: $target_part"
puts $manifest "Top: $design_top"
puts $manifest "RTL .v files: [llength [glob -nocomplain [file join $project_root src *.v]]]"
puts $manifest "Design inputs: [llength $expected_design]"
puts $manifest "Simulation inputs: [llength $expected_sim]"
puts $manifest "ROM files staged and byte-compared: [llength $memory_paths]"
foreach run_name {synth_1 impl_1} {
    puts $manifest "$run_name: [get_property FLOW [get_runs $run_name]] / [get_property STRATEGY [get_runs $run_name]]"
}
foreach path $expected_design { puts $manifest "DESIGN $path" }
foreach path $expected_sim { puts $manifest "SIM $path" }
foreach path $expected_constraints { puts $manifest "CONSTRAINT $path" }
close $manifest
close_project

if {[gl_read_file $inherited_xpr] ne $inherited_text} { error "Inherited XPR unexpectedly changed" }
dict for {path original} $ip_originals {
    if {[gl_read_file $path] ne $original} { error "IP definition unexpectedly changed: $path" }
}
puts "PASS gravity project: $design_top; [llength $expected_design] design inputs; [llength $expected_sim] simulation inputs"
puts "Created [file join $project_dir ${project_name}.xpr]"
puts "Creation/source audit only; no synthesis, implementation, bitstream, or hardware action."
