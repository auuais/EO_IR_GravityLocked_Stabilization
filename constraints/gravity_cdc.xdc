# Load AFTER camera_base.xdc and the MIG clock constraints. The former broad
# osc27-generated <-> mmcm_clkout0 clock group has deliberately been removed:
# clock groups outrank set_max_delay, regardless of file order (AMD UG903).
# Preserve the former exclusions for every other HD/UI destination, but leave
# these two handshaked mailboxes visible to the bundled-data timing constraints.
set gl_hd_clocks [get_clocks -include_generated_clocks osc27]
set gl_ui_clocks [get_clocks mmcm_clkout0]
set gl_ui_other [filter [all_registers -clock $gl_ui_clocks] {NAME !~ u_i2c/u_pose_cdc/* && NAME !~ u_i2c/u_control_cdc/*}]
set gl_hd_other [filter [all_registers -clock $gl_hd_clocks] {NAME !~ u_i2c/u_pose_cdc/* && NAME !~ u_i2c/u_control_cdc/*}]
set_false_path -from $gl_hd_clocks -to $gl_ui_other
set_false_path -from $gl_ui_clocks -to $gl_hd_other

# Only the first request/ack synchronizer stages cross asynchronously. Stage
# 0 -> stage 1 stays timed in its receiving domain; ASYNC_REG prevents retiming.
set_false_path -to [get_pins -hier -filter {NAME == u_i2c/u_pose_cdc/req_sync_reg[0]/D || NAME == u_i2c/u_pose_cdc/ack_sync_reg[0]/D || NAME == u_i2c/u_control_cdc/req_sync_reg[0]/D || NAME == u_i2c/u_control_cdc/ack_sync_reg[0]/D}]
# Common asynchronous assertion enters local two-clock release synchronizers.
# Only their asynchronous pins are excepted. The synchronized local reset's
# recovery/removal paths to mailbox state remain timed in their own domain.
set_false_path -to [get_pins -of_objects [get_cells -hier -filter {NAME =~ u_i2c/u_pose_cdc/src_reset_sync_reg* || NAME =~ u_i2c/u_pose_cdc/dst_reset_sync_reg* || NAME =~ u_i2c/u_control_cdc/src_reset_sync_reg* || NAME =~ u_i2c/u_control_cdc/dst_reset_sync_reg* || NAME =~ u_i2c/receipt_reset_sync_reg*}] -filter {REF_PIN_NAME == CLR || REF_PIN_NAME == PRE}]

# transfer_bus is held stable until the synchronized acknowledgment returns.
# Destination capture occurs after two request synchronization stages. Bound
# routing to 4.000 ns, below the current MIG UI period (~4.285 ns), and also
# constrain bit skew. The control mailbox synthesizes to its eight live bits.
set gl_pose_launch [get_cells -hier -filter {NAME =~ u_i2c/u_pose_cdc/transfer_bus_reg*}]
set gl_pose_capture [get_cells -hier -filter {NAME =~ u_i2c/u_pose_cdc/dst_roll_cd_reg* || NAME =~ u_i2c/u_pose_cdc/dst_pitch_cd_reg* || NAME =~ u_i2c/u_pose_cdc/dst_receipt_sequence_reg*}]
set gl_control_launch [get_cells -hier -filter {NAME =~ u_i2c/u_control_cdc/transfer_bus_reg*}]
set gl_control_capture [get_cells -hier -filter {NAME =~ u_i2c/u_control_cdc/dst_roll_cd_reg*}]
set_max_delay -datapath_only 4.000 -from $gl_pose_launch -to $gl_pose_capture
set_bus_skew 4.000 -from $gl_pose_launch -to $gl_pose_capture
set_max_delay -datapath_only 4.000 -from $gl_control_launch -to $gl_control_capture
set_bus_skew 4.000 -from $gl_control_launch -to $gl_control_capture
