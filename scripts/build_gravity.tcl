# Complete build of the relocated gravity project. Never opens the inherited
# XPR or programs hardware. Route/timing guards run BEFORE bitstream generation.
set root [file normalize [file join [file dirname [info script]] ..]]
set project_dir [file join $root builds vivado_project]
set project_name EO_IR_GravityLocked_Stabilization
set xpr [file join $project_dir ${project_name}.xpr]
if {[llength $argv] > 1} { error "Usage: build_gravity.tcl ?place_directive?" }
set place_directive Default
if {[llength $argv] == 1} { set place_directive [lindex $argv 0] }
if {![string match "2025.2*" [version -short]]} { error "Vivado 2025.2 required" }
if {![file exists $xpr]} { error "Run scripts/create_gravity_project.tcl first" }
set stamp [clock format [clock seconds] -format %Y%m%d_%H%M%S]
set output_dir [file join $root builds gravity_$stamp]
file mkdir $output_dir
set progress [file join $output_dir progress.txt]
proc phase {message} {
    global progress
    set line "[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] $message"
    puts $line
    flush stdout
    set f [open $progress a]; puts $f $line; close $f
}
proc read_bytes {path} {
    set f [open $path rb]; set data [read $f]; close $f; return $data
}
proc guard_timing {path} {
    set data [read_bytes $path]
    if {![regexp -line {^\s*(-?[0-9.]+)\s+(-?[0-9.]+)\s+\d+\s+\d+\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s+\d+\s+\d+\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s+\d+\s+\d+} $data -> wns tns whs ths wpws tpws]} {
        error "Missing Design Timing Summary in $path"
    }
    foreach name {WNS TNS WHS THS WPWS TPWS} value [list $wns $tns $whs $ths $wpws $tpws] {
        if {double($value) < 0.0} { error "Refusing bitstream: $name=$value ($path)" }
    }
    phase "Timing passed: WNS=$wns TNS=$tns WHS=$whs THS=$ths WPWS=$wpws TPWS=$tpws"
}
phase "Output directory: $output_dir"
open_project $xpr
set_param general.maxThreads 8
set top [get_property TOP [get_filesets sources_1]]
set part [get_property PART [current_project]]
if {$top ne "KintexTop_EO_IR_HD_SDI_panorama_base" || $part ne "xcku15p-ffve1517-2-i"} {
    error "Unexpected top/part: $top $part"
}
if {[get_property VERILOG_DEFINE [get_filesets sources_1]] ne ""} {
    error "Unexpected compilation defines; gravity build requires baseline debug configuration"
}
# Refuse an obsolete fileset. Creating the project is cheap and is the single
# entry point for registering new modules/constraints and checking relocation.
foreach pattern {src/*.v src/*.vh constraints/*.xdc} {
    foreach path [glob -nocomplain [file join $root $pattern]] {
        if {![llength [get_files -quiet [file normalize $path]]]} {
            error "Input missing from project; recreate it first: $path"
        }
    }
}
# Explicit relative readmem paths consume these staged copies. Refresh them
# even when the project was created before the latest checked-in ROM change.
set staged_roms [list]
foreach relative {assets/rowruns assets/rollpitch reference/gravity_math} {
    set destination [file join $project_dir $relative]
    file mkdir $destination
    foreach path [glob [file join $root $relative *.mem]] {
        set staged [file join $destination [file tail $path]]
        file copy -force $path $staged
        if {[read_bytes $path] ne [read_bytes $staged]} { error "ROM staging mismatch: $path" }
        lappend staged_roms $staged
    }
}
# Save exact user-source contents. If a registered source changes while Vivado
# is running, fail before publishing a bitstream with ambiguous provenance.
set source_bytes [dict create]
set manifest [open [file join $output_dir inputs.txt] w]
puts $manifest "Vivado: [version -short]\nTop: $top\nPart: $part\nPlace: $place_directive"
foreach path [get_files -quiet] {
    set normalized [string tolower [file normalize $path]]
    set root_lower [string tolower $root]
    set is_user_input 0
    foreach subdir {src sim constraints assets reference} {
        if {[string first "$root_lower/$subdir/" "$normalized/"] == 0} { set is_user_input 1 }
    }
    if {[string first "$root_lower/ip/" "$normalized/"] == 0 && [file extension $path] eq ".xci"} {
        set is_user_input 1
    }
    # Generated IP products may be regenerated during launch_runs. Guard their
    # checked-in XCI definitions, not mutable generated HDL/checkpoints.
    if {$is_user_input && [file exists $path] && ![file isdirectory $path]} {
        dict set source_bytes $path [read_bytes $path]
        puts $manifest $path
    }
}
close $manifest
foreach path $staged_roms { dict set source_bytes $path [read_bytes $path] }
set run [get_runs synth_1]
set_property AUTO_INCREMENTAL_CHECKPOINT 0 $run
set_property INCREMENTAL_CHECKPOINT {} $run
phase "Synthesis started"
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
set status [get_property STATUS $run]
if {![string match "*Complete*" $status]} { error "Synthesis failed: $status" }
phase "Synthesis complete"
open_run synth_1
source [file join $root scripts audit_gravity_cdc.tcl]
file copy [file join $root builds gravity_cdc_audit] [file join $output_dir cdc_synth]
source [file join $root scripts audit_gravity_logic_timing.tcl]
gl_audit_logic_timing $output_dir synth
report_utilization -file [file join $output_dir utilization_synth.rpt]
report_cdc -details -file [file join $output_dir cdc_synth.rpt]
write_checkpoint [file join $output_dir synthesized.dcp]
phase "Optimization started"
opt_design
write_checkpoint [file join $output_dir optimized.dcp]
phase "Placement started ($place_directive)"
place_design -directive $place_directive
write_checkpoint [file join $output_dir placed.dcp]
phase "Physical optimization started"
phys_opt_design
write_checkpoint [file join $output_dir physopt.dcp]
phase "Routing started"
route_design
write_checkpoint [file join $output_dir routed.dcp]
phase "Routing complete"
report_route_status -file [file join $output_dir route_status.rpt]
if {![report_route_status -boolean_check PLACED_FULLY] ||
    ![report_route_status -boolean_check ROUTED_FULLY] ||
    [report_route_status -boolean_check ERRORS_IN_ROUTES]} {
    error "Refusing bitstream: incomplete routing or routing errors"
}
report_utilization -file [file join $output_dir utilization_routed.rpt]
report_timing_summary -max_paths 20 -report_unconstrained -warn_on_violation \
    -file [file join $output_dir timing_routed.rpt]
report_bus_skew -file [file join $output_dir bus_skew_routed.rpt]
report_cdc -details -file [file join $output_dir cdc_routed.rpt]
report_drc -file [file join $output_dir drc_routed.rpt]
source [file join $root scripts audit_gravity_cdc.tcl]
file copy [file join $root builds gravity_cdc_audit] [file join $output_dir cdc_routed]
gl_audit_logic_timing $output_dir routed
guard_timing [file join $output_dir timing_routed.rpt]
if {[regexp {Slack \(VIOLATED\)} [read_bytes [file join $output_dir bus_skew_routed.rpt]]]} {
    error "Refusing bitstream: bus-skew violation"
}
if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]} {
    error "Refusing bitstream: DRC errors"
}
dict for {path bytes} $source_bytes {
    if {![file exists $path] || [read_bytes $path] ne $bytes} {
        error "Refusing bitstream: registered input changed during build: $path"
    }
}
write_debug_probes [file join $output_dir ${top}.ltx]
phase "Guards passed; writing bitstream"
write_bitstream [file join $output_dir ${top}.bit]
phase "BITSTREAM COMPLETE (not programmed): [file join $output_dir ${top}.bit]"
close_project
