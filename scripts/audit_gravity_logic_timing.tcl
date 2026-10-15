# Source after open_run/open_checkpoint, then call:
#   gl_audit_logic_timing $output_dir synth
#   gl_audit_logic_timing $output_dir routed
# Optional third argument selects a hierarchy for standalone smoke tests:
#   gl_audit_logic_timing $output_dir smoke u_projection
# Default NAME pattern matches the rebuilt GlLeasePose instance regardless of
# its parent prefix or Vivado's spelling of generated-block separators.
# This checks internal logic only. Baseline external I/O exceptions are outside
# the scope; routed setup/hold/pulse-width and bus-skew guards remain separate.
proc gl_audit_logic_timing {output_dir stage {hierarchy_pattern {*u_gravity_pose}}} {
    if {![regexp {^[A-Za-z0-9_-]+$} $stage]} { error "Invalid gravity audit stage: $stage" }
    set roots [get_cells -hierarchical -filter "NAME =~ $hierarchy_pattern && IS_PRIMITIVE == 0"]
    if {[llength $roots] == 0} { error "Gravity timing scope missing: $hierarchy_pattern" }
    set registers [list]
    foreach root_cell $roots {
        set root_name [get_property NAME $root_cell]
        foreach cell [get_cells -hierarchical -filter "IS_SEQUENTIAL && NAME =~ $root_name/*"] {
            lappend registers $cell
        }
    }
    set registers [lsort -unique $registers]
    if {[llength $registers] == 0} { error "No sequential cells in gravity timing scope: $roots" }
    file mkdir $output_dir
    set checks {no_clock constant_clock multiple_clock unconstrained_internal_endpoints loops latch_loops}
    set coverage [check_timing -cells $roots -override_defaults $checks -verbose -return_string]
    set coverage_path [file join $output_dir gravity_timing_${stage}.rpt]
    set stream [open $coverage_path w]
    puts $stream "Scope: $roots\nSequential cells: [llength $registers]\n$coverage"
    close $stream
    foreach check $checks {
        set expression [format {checking\s+%s\s+\(([0-9]+)\)} $check]
        if {![regexp $expression $coverage -> count]} {
            error "Missing gravity check_timing result for $check; inspect $coverage_path"
        }
        if {$count != 0} { error "Gravity timing coverage failed: $check=$count; inspect $coverage_path" }
    }

    # Within GlLeasePose all sequential paths use UI clock; there is no CDC.
    # A false path or asynchronous clock-group cut here is an accidental cut.
    # Do not use -quiet: it can convert an analysis error into an empty result.
    set ignored [get_timing_paths -user_ignored -from $registers -to $registers -max_paths 10]
    set ignored_path [file join $output_dir gravity_ignored_${stage}.rpt]
    if {[llength $ignored] != 0} {
        report_timing -of_objects $ignored -file $ignored_path
        error "Gravity internal paths are cut by false-path/clock-group exceptions; inspect $ignored_path"
    }
    set stream [open $ignored_path w]
    puts $stream "PASS: no internal user-ignored paths in $roots ([llength $registers] sequential cells)."
    close $stream
    # Reject an empty/fully unconstrained selection even when all summary
    # categories are zero. Timing closure itself is checked by the caller.
    set timed [get_timing_paths -no_report_unconstrained -from $registers -to $registers -max_paths 1]
    if {[llength $timed] == 0} { error "No constrained internal gravity timing path found: $roots" }
    set start_clock [get_property STARTPOINT_CLOCK $timed]
    set end_clock [get_property ENDPOINT_CLOCK $timed]
    if {$start_clock eq "" || $end_clock eq ""} { error "Gravity timing path has a missing endpoint clock" }
    puts "PASS gravity timing audit ($stage): [llength $registers] sequential cells; clocks $start_clock -> $end_clock; no missing clocks or internal cuts"
    return [dict create roots $roots sequential_cells [llength $registers] start_clock $start_clock end_clock $end_clock coverage_report $coverage_path ignored_report $ignored_path]
}
