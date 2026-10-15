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
heading lock. Static mounting yaw affects the camera roll/pitch projection;
the extracted camera-yaw output is diagnostic and unused by the renderer.
INI yaw 390 degrees is valid and wraps; it does not fit signed
16-bit centidegrees before normalization.

The C limit is a **single global rescaling of sensor roll/pitch** based on the
largest resulting camera angle, followed by recalculation. It is not six
independent angle clamps. Static mounting trims remain unscaled; the single
pass does not guarantee every final angle is inside ten degrees. It also
rescales live yaw for bookkeeping and runs only when a live angle is nonzero.
Zero/disabled live stabilization retains static mounting correction without
this limit.

## Confirmed geometry choice

The user confirmed preservation of the stable panorama geometry, using the
selected INI for mounting angles. Therefore the new **camera-angle projection**
matches C, while the subsequent **pixel mapping** deliberately retains the
baseline maps, trig unity 32768 and EO/IR pitch factors. It is not a claim of
pixel-for-pixel equivalence to the newer C optical pipeline.

| Item | Selected stable RTL | Current C + selected INI |
| --- | --- | --- |
| Trig unity | 32768, exact zero-angle identity | 32767 |
| EO pitch factor used for source translation | -9.8 pixels/degree | Q16 -1140855, about -17.408 pixels/degree after resize normalization |
| IR pitch factor | -8.72 | Q16 -571474, about -8.72 |
| IR panorama geometry | 3576-pixel folded renderer | INI requests 3240; current C also has a newer IR map path |
| Angle limiting | Per-camera clamp to +/-10 degrees | One-pass global live-pose rescaling |

The coordinate-space audit confirms that the installed EO maps and segment
ROMs already describe original 1920x1080 source pixels. All 31,680 segment
origins match the installed base maps, without a resize conversion; the
transform rotates around source center (960,540). Therefore a hidden coordinate
resize does not explain the factor difference. Exact current-C translation
requires the effective Q16 factor above.

Changing only the factor would overflow another baseline interface: ten
degrees requires a 174-row translation, but the angle-ROM/table/segment
coefficient path stores a signed **8-bit** row shift. This path must be widened
and capture/RowWindow bounds revalidated before using the current-C factor.

The installed EO maps are byte-identical to the older `eo_20260806` package,
whose profile has resize 0.5, field of view 57.56/48.56, crop 0.888/1.0 and
overlap 50. The selected INI has resize 0.56296, field of view 77/54, crop
0.79/0.70 and overlap 60. Those optical settings are not applied. Consequently
the existing signed 8-bit pitch shift remains sufficient (+/-98 EO rows),
and the current change does not widen it or regenerate optical maps.

`GlFramePose` uses INI yaw angles EO 0/60/120/180/240/300 degrees and IR
90/150/210/270/330/390 degrees. The INI's mounting roll/pitch values are all
zero. Existing per-camera EO/IR UI trim banks supply those fixed mounting
roll/pitch values at runtime; changing them never alters an active render.
The copied MCU still has its older alternating -5/+5 degree EO pitch defaults
and can load saved banks from flash. The user has been asked whether to apply
the selected INI once on first startup and preserve later UI calibration, or
keep existing saved calibration. That migration is not implemented pending
the answer; do not treat the current firmware startup bank as the chosen INI.
See `validation/gravity_storage_migration_review.md` for the inherited storage
issues that must be addressed if a persistent migration is selected.

Keep the user-selected calibration snapshot immutable; generated assets need
their own source/profile hashes and validation results. The INI's IR image
paths currently refer to EO test BMPs, so it cannot serve unchanged as an IR
pixel-golden fixture. Run `python scripts/audit_gravity_geometry.py` to
reproduce the coordinate/profile/shift-width audit; the recorded result is
`validation/gravity_geometry_20261015.json`.

## IMU transport findings

Read-only audit source:
`EO_OSD_Remote_20260812/ST_Link-test/Core` within the original C project.
This is the compiled source tree; the installed MCU binary has not been
identified or verified. Audited source hashes are recorded in
`validation/firmware_source_audit_20261015.json`.

- MCU writes I2C address `0x36`, one four-byte transaction starting at register
  `0x10`: signed int16 roll then pitch, little-endian, in centidegrees.
- The rate/sequence registers at `0x14..0x17` and an APPLY command are declared
  but not sent by the current path. A local receipt counter must not be
  described as an IMU timestamp or camera exposure/frame identifier.
- The copied MCU source fixes panorama VSYNC gating to modes `0x14` and
  `0x15`; the older source checked `0x01` and `0x02` instead.
- The user confirmed the existing UI On/Off and Attitude Sensor controls.
  Previously unused register `0x04` now accepts exactly one byte: `0xA1`
  enables gravity stabilization, `0xA0` disables it. Reset and other values
  are invalid/disabled. MCU sends A1 only for On + Attitude Sensor; all other
  combinations send A0, with startup synchronization and failed-write retry.
- IMU processing uses the sensor axes directly. Physical rig-to-sensor sign
  mapping, PC4 VSYNC wiring and sensor-to-exposure latency require bench
  verification. Software inspection cannot prove those physical relationships.
- The source aggregates samples before fusion and uses a pending VSYNC flag;
  it provides no per-exposure timestamp. This stage can establish frame-coherent
  coefficients, but cannot yet establish exposure-time-correct compensation.

The production I2C slave feeds START, STOP and each completed data-byte ACK
to `GlPoseReceiver`. Pose and control commit only at STOP after the exact
transaction has been acknowledged. Wire-level simulation covers malformed,
partial, excess and repeated-start transactions. Both `GlPoseCdc` instances
share reset assertion with the UI destination. Physical bundled-data delay
and bus-skew constraints must be checked in the implemented netlist.

## Frame and capture contract

The baseline increments 16-bit `v19_global_epoch` at the common EO strobe,
associates source banks with epochs, and renders the selected frameset lease.
IR now has an independent counter driven by its existing genlock pulse; all
six IR writers use that counter's Gray epoch. The implementation binds
coefficients to the **leased source frameset and sensor family**. These are
trigger-association tags, not exposure timestamps.

Implemented production sequence:

1. Receive one coherent pose and receipt sequence in the UI clock domain.
2. At each family's trigger, save pose, age, enable and calibration revision
   against the next epoch assigned on that same edge. Separate EO and IR
   histories each hold 16 full-tag entries and reject overwritten entries.
   Both record continuously, including while another view is selected.
3. `GlLeasePose` looks up the selected family's lease epoch and freezes its inputs.
   The freshness policy defaults to 23,340,000 UI cycles (100 ms at 233.4 MHz),
   evaluated at epoch capture. Missing/stale/disabled data or calibration
   revision mismatch uses exact static offsets. No exposure-time alignment is
   inferred from this policy.
4. `GlFramePose` computes six angles and the original global limit, then
   publishes one atomic set. The renderer still clamps each final angle to
   +/-10 degrees; an explicit flag reports a C result beyond that range.
5. Copy start waits for this set. `RpRenderer` snapshots it and builds tables
   from the same frozen registers. Replay waits for valid source requirements;
   all coefficients and schedules remain unchanged through the pass.
6. The EO writer always captures rows 0..1079 and beats 8..111 (columns
   128..1791), proven to cover every allowed transformed source request.
   The camera selected for EO single output still writes its whole frame.
   IR keeps its existing full-frame capture.

The baseline table-build race is also fixed: `RpTables` receives the frozen
`built_*` values, not live offsets one cycle after the build request.

The fixed envelope needs 20,217,600 capture write beats/s for six cameras at
30 fps. The 1920x960 output adds 3,456,000, for **23,673,600 aggregate write
beats/s**. This exceeds the historical **aggregate** measured write rate of
22,300,000; that historical figure is not a capture-only budget or a measured
limit for the current writer. IR panorama needs 5,299,200 aggregate writes/s
at the same assumed rates. EO and IR DDR capture are mutually gated; IR single
nevertheless retains all six EO captures and the same output size, so it has
the EO panorama write demand. EO single needs 24,624,000 writes/s. The
exhaustive geometry proof remains in `validation/gravity_capture_envelope.json`;
the corrected accounting and deployment limits are in
`validation/gravity_bandwidth_review_20261016.md`. This build is an experimental
function/timing candidate, with no 30 fps whole-system throughput claim.
Current writer throughput, RowWindow occupancy, DDR burst pressure and unique
output rate require measurement; lower frame rates are not guaranteed by
average write arithmetic alone.

Calibration revision combines both EO and IR update counters. Updating either
bank can cause a static fallback for a source epoch captured under the old
revision. It cannot change an already accepted pass. Mode/lease changes outside
a pass cancel pending calculations; reset clears history and all valid state.

## Implementation and acceptance stages

Completed: exact baseline/profile/archive provenance; portable C oracle and
independent Python reference; atomic pose receiver and coherent clock transfer;
camera projection RTL matching all 1,342 exact-C vectors; standalone KU15P
synthesis; relocatable Vivado project setup with protected source/IP hashes.
The projection needs 531-601 cycles and synthesizes to 1,414 LUTs, 1,513 FFs,
67.5 BRAM tiles and two DSPs. Its positive post-synthesis slack is an estimate,
not routed timing closure. See `validation/camera_projection_20261015.json`.

The integrated six-camera controller passes 266 compiled-C/static-bypass
cases, including global limiting, signed extremes and atomic output checks.
The lease bridge passes directed frame association, active-pass freeze,
fallback, history overwrite, cancellation and reset tests. Wire-level I2C
tests pass, and the copied MCU project builds with the installed ARM compiler.

An integration review found that the first candidate incorrectly used EO
epochs for IR captures. That candidate's build was stopped during placement.
The corrected implementation has independent IR trigger tags and history;
21 lease cases and a trigger test covering all 65,536 counter increments,
phase, reset and capture/Gray alignment pass. Equal numeric EO/IR tags cannot
borrow the other family's pose. See `validation/ir_epoch_association_20261016.json`.
The corrected revision requires a fresh complete implementation run.

Renderer pixel/scheduling regression is complete: eight EO/IR table cases and
eight rasters in each legacy/gravity mode passed, with 14,112,000 bit-exact
pixels per mode. Gravity-mode assertions also cover pending-input changes,
ready gating and identical-pose table reuse. Focused capture/selection tests
pass 116 coverage checks, 19 selection checks and the original marker-ordering
regression; source/output hashes are recorded in
`validation/renderer_integration_20261016.json`. Remaining acceptance is
whole-top synthesis/place/route and physical CDC checks, followed by
instrumented bench tests and rig sign/latency verification. Bench tests must
include camera selection and panorama/single transitions at arbitrary raster
phases, delayed descriptor retirement, rapid mode changes, source-bank reuse
under DDR stalls, and sustained capture/FIFO pressure. No live gravity-lock
result is claimed.

## ILA observation

The existing 64-bit `v19_dbg_rows_word0`, connected to `dbg_ila_0` **probe22**,
has signature `0x474c` in bits
63:48, applied source epoch in 47:32, low 16 bits of applied receipt sequence
in 31:16, and flags in 15:8. Those flags, high to low, are ready, enabled,
static fallback, history miss, stale pose, calibration mismatch, global limit
and final angle out-of-range. Bits 7:0 retain renderer status. Logical `word1` holds
camera 0/1 roll in its upper 32 bits and pitch in its lower 32 bits, with camera
0 in each pair's low half; angles are signed centidegrees. `word2` retains
renderer progress. The old word0/word1 high-bit strobe-period overlay is disabled
for this page so it cannot corrupt the signature or signed angles. Sequence is
a local receipt count, not a sensor or exposure timestamp; this page cannot
reconstruct the complete 32-bit count. When ready is false, the applied fields
can retain the previous completed result.

**Logical `word1` is not connected to a current ILA probe.** Probe23 carries
capture telemetry and probe24 carries renderer/completion diagnostics. A later
reviewed probe-mux change could expose camera angles; it is not implemented in
this build. The word1 angles are before the renderer's +/-1000-centidegree clamp.

Decode a copied numeric probe22 value without hardware access:

```powershell
python scripts/decode_gravity_ila.py 0x474c1234abcdc35a
```

The tool accepts unsigned decimal or `0x` hexadecimal, rejects a wrong GL
signature or values wider than 64 bits, and emits JSON. An optional second word
decodes the logical angle signal from simulation or a future probe change:

```powershell
python scripts/decode_gravity_ila.py 0x474c1234abcdc35a 0xff3800640190fed4
```

That example gives camera0 roll/pitch `100/-300` and camera1 `-200/400`
centidegrees. Current bench captures can observe epoch, sequence-low16 and
flags; angle/pixel expectations remain available from the C oracle and renderer
regressions.

Bench acceptance must include stabilization disabled with static offsets,
zero live attitude, roll-only, pitch-only and combined motion at several yaw
positions, repeated updates during a render, stale/malformed input, mode
changes and EO/IR switching. Record the firmware/build/profile hashes and
actual camera format/rate for every run. Visual gravity lock and dynamic frame
integrity are required in addition to numerical angle agreement.
