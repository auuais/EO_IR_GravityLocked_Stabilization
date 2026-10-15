# Gravity-lock implementation contract

## Objective and preserved baseline

Implement the original C gravity transformation using a coherent live sensor
pose plus fixed physical mounting calibration, then apply the resulting
per-camera roll/pitch in the stable EO/IR RTL rendering pipeline. The baseline
is user-selected commit `3479cacf2e512a5bde9aa3e0243755826e071ef4`, not the
later experimental HEAD. The selected INI is recorded in
`BASELINE_PROVENANCE.json` and copied to `config/parameters_unified.ini`.

No new production bitstream or live stabilization behavior is claimed yet.
The desktop C program calculates a test pose before replaying static images;
it is a numerical reference, not an existing real-time transport/scheduler.

## Numerical contract

The compiled reference translation unit is
`IMU_stabilize_GYRO/IMU_stabilize_GYRO.cpp`. Source SHA-256:
`f4dea4cbfba60bfe686644081c7bcfb4744c9d8b14771c0d916dad6702839495`.
The alternate `_V18.cpp` file is not the selected compiled implementation.

For each camera, retain the exact source order and quantization:

```
Rsys = Rx(sensor_roll) * Ry(sensor_pitch)
Roff = Rz(mount_yaw) * Ry(mount_pitch) * Rx(mount_roll)
Rcam = Rsys * Roff
camera_pitch = asin(-Rcam[2][0])
camera_roll  = atan2(Rcam[2][1], Rcam[2][2])
camera_yaw   = atan2(Rcam[1][0], Rcam[0][0])
```

The source has a near-gimbal special case, a 36,000-entry centidegree trig
table with unity 32767, a 4,097-entry atan-ratio table, integer square root,
and prescribed signed rounding. The exact excerpts and their hashes are in
`reference/gravity_math/`. Sensor yaw is not part of `Rsys`; this is not
heading lock. Camera yaw affects the roll/pitch projection and must not be
discarded. INI yaw 390 degrees is valid and wraps; it does not fit signed
16-bit centidegrees before normalization.

The C limit is a **single global rescaling of sensor roll/pitch** based on the
largest resulting camera angle, followed by recalculation. It is not six
independent angle clamps. Static mounting trims remain unscaled; the single
pass does not guarantee every final angle is inside ten degrees. Disabled
live stabilization retains static mounting correction.

## Stable-renderer differences requiring explicit validation

| Item | Selected stable RTL | Current C + selected INI |
| --- | --- | --- |
| Trig unity | 32768, exact zero-angle identity | 32767 |
| EO pitch factor used for source translation | -9.8 pixels/degree | Q16 -1140855, about -17.408 pixels/degree after resize normalization |
| IR pitch factor | -8.72 | Q16 -571474, about -8.72 |
| IR panorama geometry | 3576-pixel folded renderer | INI requests 3240; current C also has a newer IR map path |
| Angle limiting | Per-camera clamp to +/-10 degrees | One-pass global live-pose rescaling |

These are observed differences, not evidence that a blind constant change
will preserve the stable image. Trace the base-map coordinate spaces and
compare coordinate probes and rendered fixtures before selecting production
coefficients. Keep the user-selected calibration snapshot immutable; generated
assets need their own source/profile hashes and validation results. The INI's
IR image paths currently refer to EO test BMPs, so it cannot serve unchanged
as an IR pixel-golden fixture.

## IMU transport findings

Read-only audit source:
`EO_OSD_Remote_20260812/ST_Link-test/Core` within the original C project.
This is the compiled source tree; the installed MCU binary has not been
identified or verified.

- MCU writes I2C address `0x36`, one four-byte transaction starting at register
  `0x10`: signed int16 roll then pitch, little-endian, in centidegrees.
- The rate/sequence registers at `0x14..0x17` and an APPLY command are declared
  but not sent by the current path. A local receipt counter must not be
  described as an IMU timestamp or camera exposure/frame identifier.
- `mcu_fsm.c` forwards live orientation on VSYNC only for stored modes `0x01`
  and `0x02`, whereas the current panorama commands store/on-wire use `0x14`
  and `0x15`. This source needs correction for live panorama forwarding.
- The existing UI stabilization enable/method values remain MCU shadow state;
  no FPGA control register contract exists for them. User choice of control
  behavior is pending. Do not invent or reuse a register silently.
- IMU processing uses the sensor axes directly. Physical rig-to-sensor sign
  mapping, PC4 VSYNC wiring and sensor-to-exposure latency require bench
  verification. Software inspection cannot prove those physical relationships.
- The source aggregates samples before fusion and uses a pending VSYNC flag;
  it provides no per-exposure timestamp. This stage can establish frame-coherent
  coefficients, but cannot yet establish exposure-time-correct compensation.

`GlPoseReceiver` is a standalone synchronous transaction validator. Integration
must feed START, STOP and each completed data-byte ACK from the existing I2C
slave; emitting a write pulse before the ACK is complete weakens its contract.
`GlPoseCdc` uses common reset, a stable bundled bus and synchronized toggles.
Both clocks must share reset assertion; physical CDC constraints and review
remain necessary after connection.

## Frame and capture contract

The baseline increments 16-bit `v19_global_epoch` at the common EO strobe,
associates source banks with epochs, and renders the selected frameset lease.
The design must bind coefficients to the **leased source frameset**, rather
than read the newest IMU values whenever rendering happens.

Required production sequence:

1. Receive and transfer one complete pose sample. Record receipt validity,
   sequence and age; define the stale-data threshold and fallback behavior.
2. Capture a pose/calibration/enable snapshot for the source epoch. Retain
   full epoch tags so ring-history overwrites cannot return a different pose.
3. Select that snapshot with the renderer's frameset lease. Freeze it while
   all camera coefficients and dependent schedule tables are built and used.
4. Update table parameters, source row/column envelope, reverse indexes and
   row completion bounds atomically. Pending newer samples cannot invalidate
   an active pass or change `tables_match` mid-frame.
5. Guarantee the leased source banks actually contain every required pixel.
   Existing writers adopt capture windows at frame start: a table for a newer
   pose can otherwise request rows never captured in an older bank. Use a
   verified fixed capture envelope or per-bank coverage checks.
6. Check RowWindow/queue occupancy, bandwidth and pass deadline for dynamic
   poses, especially EO's 256-row window. Do not infer sustained 30/60 Hz
   performance from a standalone arithmetic simulation.

There is also a baseline table-build input race to remove during integration:
`RpRenderer` records `built_roll/pitch` when requesting a build, but `RpTables`
sees the live inputs on the following cycle. A frozen snapshot must supply
both the recorded identity and the builder's inputs.

## Implementation and acceptance stages

Completed: exact baseline/profile/archive provenance; portable C oracle and
independent Python reference; atomic pose receiver and coherent clock transfer.

In progress: standalone synthesizable camera projection against exact C
vectors; relocatable Vivado project setup.

Remaining: global multi-camera limiting/coefficient controller; explicit MCU
transport/control updates; frame/lease binding; capture coverage strategy;
renderer/table integration; pixel and scheduling regression; synthesis/place/
route timing; instrumented bench tests and rig sign/latency verification.

Bench acceptance must include stabilization disabled with static offsets,
zero live attitude, roll-only, pitch-only and combined motion at several yaw
positions, repeated updates during a render, stale/malformed input, mode
changes and EO/IR switching. Record the firmware/build/profile hashes and
actual camera format/rate for every run. Visual gravity lock and dynamic frame
integrity are required in addition to numerical angle agreement.
