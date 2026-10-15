# Source with the synthesized/implemented full design open and XDC loaded.
# Fail on missing/renamed/optimized endpoints rather than silently losing CDC
# constraints. Reports are written only beneath the calling repository.
set gl_audit_root [file normalize [file join [file dirname [info script]] ..]]
set gl_audit_out [file join $gl_audit_root builds gravity_cdc_audit]
file mkdir $gl_audit_out
foreach mailbox {pose control} expected {64 8} {
    set launch [get_cells -hier -filter "NAME =~ u_i2c/u_${mailbox}_cdc/transfer_bus_reg*"]
    if {$mailbox eq "pose"} {
        set capture [get_cells -hier -filter {NAME =~ u_i2c/u_pose_cdc/dst_roll_cd_reg* || NAME =~ u_i2c/u_pose_cdc/dst_pitch_cd_reg* || NAME =~ u_i2c/u_pose_cdc/dst_receipt_sequence_reg*}]
    } else {
        set capture [get_cells -hier -filter {NAME =~ u_i2c/u_control_cdc/dst_roll_cd_reg*}]
    }
    if {[llength $launch] != $expected || [llength $capture] != $expected} {
        error "Gravity $mailbox endpoint mismatch: launch=[llength $launch] capture=[llength $capture], expected=$expected"
    }
    set paths [get_timing_paths -from $launch -to $capture -max_paths 100 -nworst 1]
    if {[llength $paths] != $expected} {
        error "Gravity $mailbox has [llength $paths]/$expected timed paths; check overridden/absent max_delay or endpoints"
    }
    foreach path $paths {
        set requirement [get_property REQUIREMENT $path]
        if {$requirement > 4.001 || $requirement < 3.999} {
            error "Gravity $mailbox path requirement $requirement is not the required 4 ns datapath bound"
        }
    }
    set ui_clock [get_clocks -of_objects [get_pins -of_objects $capture -filter {REF_PIN_NAME == C}]]
    foreach clock $ui_clock {
        if {[get_property PERIOD $clock] < 4.000} { error "Gravity bound exceeds UI period on $clock" }
    }
    report_timing -from $launch -to $capture -max_paths 100 -file [file join $gl_audit_out ${mailbox}_max_delay.rpt]
    puts "PASS gravity $mailbox endpoints=$expected effective_max_delay=4.000 ns"
}
set gl_toggle_pins [get_pins -hier -filter {NAME == u_i2c/u_pose_cdc/req_sync_reg[0]/D || NAME == u_i2c/u_pose_cdc/ack_sync_reg[0]/D || NAME == u_i2c/u_control_cdc/req_sync_reg[0]/D || NAME == u_i2c/u_control_cdc/ack_sync_reg[0]/D}]
if {[llength $gl_toggle_pins] != 4} { error "Gravity first-stage toggle endpoint count is [llength $gl_toggle_pins], expected 4" }
report_bus_skew -file [file join $gl_audit_out bus_skew.rpt]
set gl_bus_report [open [file join $gl_audit_out bus_skew.rpt] r]
set gl_bus_text [read $gl_bus_report]
close $gl_bus_report
foreach instance {u_pose_cdc u_control_cdc} {
    if {![string match *$instance* $gl_bus_text]} { error "Missing bus-skew assertion for $instance" }
}
report_exceptions -ignored -file [file join $gl_audit_out ignored_exceptions.rpt]
report_cdc -details -file [file join $gl_audit_out cdc.rpt]
puts "PASS gravity CDC constraint audit (routing slack and CDC report review still required): $gl_audit_out"
