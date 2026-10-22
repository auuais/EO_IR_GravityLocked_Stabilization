# Gravity-lock bench acceptance

This is a procedure for a completed candidate, not a record of a hardware run.
No board, programmer, camera clock, installed firmware or capture instrument is
assumed to have been identified. Mark each test **NOT RUN**, **PASS** or **FAIL**;
retain the evidence path and the reason for any skipped test. Programming and
physical motion are operator actions after the candidate is approved for bench
use. This document does not initiate them.

## 1. Preserve rollback and identify the candidate

Before changing the bench, run `python scripts/verify_gravity_baseline.py
--archive` from the repository root. Preserve the byte-verified rollback archive
at `builds/baseline_20260930_202000_eosingle_fullwrite_3479cac/`, including its
matched `.bit`/`.ltx`, `.mcs`/`.prm` and reports. The authoritative hashes and
baseline commit `3479cacf2e512a5bde9aa3e0243755826e071ef4` are in
[BASELINE_PROVENANCE.json](BASELINE_PROVENANCE.json). Do not overwrite that
directory with candidate outputs. Identify a recoverable MCU image/configuration
as well; the FPGA archive alone does not restore MCU firmware or saved trims.

Create a run record containing the following before programming:

| Record | Required evidence |
| --- | --- |
| FPGA candidate | Git commit, build directory, `.bit` and matched `.ltx` paths and SHA-256 hashes; routed timing, DRC and physical CDC reports |
| MCU candidate | Exact flashed artifact path/hash, source commit and build log; identify the previously installed image separately |
| Profile | SHA-256 of `config/parameters_unified.ini`; actual six-camera EO and IR mounting/trim banks read from the running system |
| Bench | Identified board/target, connected cameras and sector labels, actual input/output formats and measured rates, display/capture path, test instruments and their timebases |
| Camera timing | Per-camera free-run/trigger mode, external trigger/genlock rate, shutter/exposure, external-trigger delay and DNR settings, verified on the current rig |
| State | UI mode, On/Off, method selection, camera selection, calibration revision and all initial integrity/status flags |
| Evidence | Raw video/frames, ILA exports with matched probe file, bus traces if available, operator motion notes and analysis outputs |

Use SHA-256 of actual files, for example PowerShell `Get-FileHash -Algorithm
SHA256 -LiteralPath <file>` after replacing the placeholder with the verified
path. A source build or filename is not proof of the image currently programmed.
Record programming/readback evidence through the bench's established procedure.

Earlier camera experiments used differing free-run/trigger settings. Do not
assume that every camera exposes at the shared trigger, or infer exposure
synchronization from equal frame tags. Hold the recorded exposure/DNR/delay
settings fixed when comparing stabilization Off and On; repeat latency and
inter-camera spread measurements when those settings change. The implemented
EO and IR histories use their own trigger families, but neither provides a
per-camera exposure timestamp.

**Pass:** rollback hashes match; FPGA/MCU artifacts and calibration state are
identified; the candidate has passed its build and scoped gravity timing/CDC
audits, with the remaining full-design CDC findings recorded for bench review.
Otherwise do not label subsequent video as a qualified candidate result.

## 2. Resolve the calibration state explicitly

The user approved one-time INI mounting migration on 2026-10-19. The new MCU
firmware sets all mounting roll/pitch entries to zero once and retains later
UI edits. Identify the exact flashed MCU image: the earlier FPGA build bundle
contains an MCU candidate from before this migration. See
[GRAVITY_CALIBRATION_STORAGE.md](GRAVITY_CALIBRATION_STORAGE.md).

Read and save the actual banks before programming. Preserve journal pages when
updating firmware; a mass erase removes both saved calibration and the one-time
marker. Verify first-start mounting values, then change both banks through the
UI and verify persistence across repeated power cycles. Label each image test
with the actual current trims; after UI edits they need not remain zero. UI yaw
persists but does not change the current FPGA's fixed mounting yaw constants.
Keep the stable optical maps and pitch factors unchanged. Record these hardware
checks as NOT RUN until performed; host fault tests are separate evidence.

**Pass:** every angle/pixel comparison uses the actual recorded trim bank; no
result silently treats MCU defaults or saved data as the selected INI.

## 3. Decode observations before interpreting motion

With the candidate's matching `.ltx`, confirm the gravity status signature.
The current gravity RTL connects `dbg_ila_0` as follows; verify that the loaded
probe mapping matches this wiring before decoding a capture. The definitions
and connections are in `src/PanoramaBase_DdrBlackFrame.v` (word0/word1 at
lines2763–2769, probe connections at lines4422–4430).

| Current probe | Connected signal and observation |
| --- | --- |
| probe22 | `v19_dbg_rows_word0_strobe`: gravity word0 status below when `SRC_SEL == SRC_V19` |
| probe23 | `v19_capture_dbg`: EO FIFO capture telemetry; **not** the camera-angle word1 |
| probe24 | `ir_render_dbg` in IR panorama, otherwise `v19_eo_done_dbg`: renderer diagnostics; **not** the word2 integrity overlay |

| `v19_dbg_rows_word0` field | Meaning |
| --- | --- |
| 63:48 | `0x474c` signature |
| 47:32 | Applied source epoch, 16-bit trigger-association tag |
| 31:16 | Low 16 bits of FPGA receipt sequence |
| 15 / 14 / 13 | Prepared pose ready / applied enable / static fallback |
| 12 / 11 / 10 | History miss / stale-or-unusable pose / calibration mismatch |
| 9 / 8 | C global limiting / final camera angle outside renderer range |
| 7:0 | Renderer status |

The RTL defines an internal `v19_dbg_rows_word1`: `[63:48]` is camera1 roll,
`[47:32]` camera0 roll, `[31:16]` camera1 pitch and `[15:0]` camera0 pitch;
each is signed int16 centidegrees. **This word is not connected to the current
ILA, so the current probe map exposes no numerical camera-angle values.** It
cannot be enabled merely by choosing another GUI display or interpreting
probe23 differently. Observing it requires a separately built, validated
instrumented candidate and its matching `.ltx`; observing all six cameras
requires additional angle signals beyond word1. Unprobed internal wires may
also be optimized away.

The old word0/word1 strobe-period overlay is disabled for this gravity path.
Do not decode word0 bits as clock periods. The internal
`v19_dbg_rows_word2_strobe` defines start, bank-ready and integrity information,
but is also **unconnected to the current ILA**. Its bit53 combines capture
overflow, descriptor collision and no-common-epoch alarms; that decoding is
usable only if a future instrumented candidate actually probes this signal.
Current probe23 instead has signature `0xC` at bits63:60, EO cam5..cam0
overflow flags at bits59:54, and six nine-bit EO FIFO peaks in units of eight
entries (cam0 at bits8:0 through cam5 at bits53:45). These remain EO telemetry
in IR mode; they do not report IR capture FIFO peaks.

**Pass:** observed signatures, status fields and telemetry decode consistently
with the candidate's actual probe map. Check signed-angle extension only on an
instrumented candidate that exposes those angles. A missing probe is an
observability gap, not a zero-valued measurement; mark dependent hardware
checks NOT RUN rather than inferring them from image appearance or simulation.

## 4. Verify controls and receipt freshness on a stationary rig

Keep the rig stationary and start with stabilization disabled. Exercise the
existing UI combinations below in EO panorama and IR panorama.

| UI setting | Expected committed control |
| --- | --- |
| On + Attitude Sensor | Register `0x04 = 0xA1`, enabled |
| Off + Attitude Sensor | `0xA0`, disabled |
| On + Horizon Information, or other/N/A combinations | `0xA0`, disabled |

Confirm ACK-completed single-byte writes followed by STOP, using a bus trace if
available. Register readback confirms transport, not rendered application.
The applied enable flag changes on a subsequently captured/prepared source
lease; an already accepted render must keep its old control through completion.
Allow the pipeline to advance and correlate the change with the applied epoch.
Disabled output must use static trims, with static fallback asserted; fallback
alone while disabled is expected, not a failure.

With On + Attitude Sensor and valid pose traffic, verify receipt sequence
progress and eventual enabled, non-fallback renders. Each pose transaction is
exactly four acknowledged bytes starting at `0x10`: signed little-endian roll,
then pitch. The sequence counts accepted FPGA transactions. It is not an IMU
sample counter or a timestamp.

For a stale test, use an approved test method to stop **pose transactions**
while retaining enabled control and camera capture. Merely freezing the angle
while continuing transactions does not test receipt freshness. Wait beyond
`MAX_POSE_AGE_CYCLES` using the actual UI clock frequency:
`threshold_seconds = MAX_POSE_AGE_CYCLES / measured_ui_hz`. The source default
is 23,340,000 cycles; do not assume its nominal time equals the bench timebase.
Observe a newly captured epoch becoming unusable and selecting static fallback.
Restore valid traffic and verify recovery on a later eligible lease.

**Pass:** only On + Attitude enables; stopping pose traffic causes a documented
stale/fallback transition without torn output; valid traffic recovers; Off
retains static rendering. During normal fresh traffic there are no unexplained
miss/stale/calibration-mismatch flags. Receipt age does not establish the age
of the underlying physical IMU measurement. Malformed-burst/history-overwrite
tests require an approved injection method; retain their existing simulation
results separately if they cannot be exercised on the bench.

## 5. Establish static and zero-pose image baselines

Use a fixed detailed target with horizontal/vertical features visible across
camera sectors and seams. Record at least 120 output frames per configuration
with the rig stationary. Compare rollback and candidate with identical actual
trim banks, camera controls, input format and capture path, stabilization Off.
Exercise EO panorama, IR panorama and all available single-camera selections.

With reproducible identical source frames, require exact output pixels against
the stable optical model. Live camera captures contain noise and exposure
variation: compare geometry, seams, crops, black/absent-camera behavior and
stationary target-position statistics, rather than demanding identical hashes.
If approved zero trims and a verified zero live pose are available, also test
On + Attitude. Numerical angle comparison with the exact-C model requires an
instrumented candidate exposing the applied angles; mark that subtest NOT RUN
with the current ILA. Keep the image comparison as a separate result. Do not
replace the model's integer quantization with an ideal floating-point identity.

**Pass:** Off preserves baseline static geometry and offsets; no new missing
rows/columns, magenta diagnostics, seam jumps or corruption; the stationary
image remains stable. The separate numerical subtest passes only when observed
zero-pose angles match the reference. A zeroed UI trim does not by itself prove
the live sensor pose is zero.

## 6. Verify source-frame and coefficient coherence

Capture render intervals while pose updates continue. In the current ILA,
probe17 includes `copy_active`; probe22 exposes the applied epoch, low16 receipt
sequence and status flags. These support status/interval correlation, but do
not expose the prepared angles or table build count. Probe19 supplies EO lease
validity and cam0/cam4 low8 descriptor epochs, not the full leased epoch for
both sensor families.

The complete check below requires a future instrumented candidate exposing
accepted-copy/render-active, the full source lease epoch and receipt sequence,
all prepared angles, table readiness/build identity and source requirements.
Verify those probe connections before claiming complete coherence. With that
instrumentation, trigger an update during table build and active output, and
repeat an identical angle set with a new receipt sequence. With the current
ILA, retain the observed status subset and mark the unobservable subtests
NOT RUN; static word0 fields alone do not prove fixed coefficients or table reuse.

**Pass:** applied epoch identifies the leased source frameset; accepted angles,
sequence/control and table identity remain fixed throughout that pass. Replay
starts only after the corresponding tables are ready. New pose/control/trim
updates affect a later pass, and identical angles reuse the tables. A receipt
sequence may legitimately repeat across multiple source epochs or skip because
the CDC retains the latest pending update. Handle epoch/sequence wrap explicitly;
the low 16-bit debug field alone cannot identify an arbitrarily long run.

No probe in this contract supplies a camera exposure timestamp. Epoch/receipt
agreement proves association and coherence, not exposure-time alignment.

## 7. Operator motion: axes, gravity lock and latency

The operator must move the physical rig; software cannot perform this test.
Use a stationary distant reference and, when quantitative angle accuracy is
required, an independent orientation reference. First make small, slow positive
and negative roll movements, return to the same neutral position, then repeat
for pitch. Record which physical axis/direction produces each signed sensor
field. Do not infer rig-to-IMU signs from UI labels.

For each EO and IR panorama, perform at least five slow cycles of roll-only,
pitch-only and combined roll/pitch, including holds at neutral and both ends.
Suggested starting excursions are approximately +/-1 degree, then +/-3 degrees
if the rig permits; record actual measured angles. Remain below limiting during
the initial test. Repeat at several rig headings/target placements so features
are inspected in all six camera sectors, including different mounting yaw
positions. Pure yaw should still pan: this implementation does not lock heading.

For each direction compare Off and On traces of target position/horizon angle.
Check camera angles against the exact-C projection only with an instrumented
candidate that exposes them, using the recorded live pose and trim bank. The
current ILA does not numerically observe even cameras0/1; internal word1 is
unconnected. Mark numerical hardware angle checks NOT RUN until instrumented,
and do not claim six-camera angle agreement from a two-camera probe. Image
motion and the current word0 status flags remain separately observable.
Separate out-of-source black borders from an in-range image defect. Test global
limiting only after low-angle behavior is correct and the operator approves the
larger excursion; compare its single rescale/recalculate result with C.

**Pass for axis/coherence checks:** independently observed axis signs agree
with the intended mapping; correction opposes the imposed tilt, never amplifies
it; no within-frame pose changes, oscillation, seam discontinuity or unexplained
limit flags; the image returns to its stationary distribution after each return
to neutral. Before declaring visual gravity lock accepted, record an agreed
residual horizon/position tolerance and require every recorded direction/sector
to meet it. If no tolerance has been agreed, report measured residuals and
On/Off improvement as measurements, not a final stabilization PASS.

For latency, use a separately planned repeatable motion/event with a shared or
calibrated timebase connecting physical orientation, IMU processing, pose
receipt and camera exposure/output. Record lag and variation for EO and IR
separately. Host capture timestamps alone are not exposure timestamps. Do not
compensate signs or introduce an assumed frame delay to make a trace look good.
**Latency acceptance remains open** until the physical timing relationship and
allowed residual/delay are measured and agreed, even if the slow-motion test passes.

## 8. Distinguish output raster rate from new source content

Run a changing visible target or independently identifiable frame/event pattern;
an unchanged scene cannot reveal repeated source content reliably. Measure over
at least 10 seconds per mode using the instrument's actual timebase. Record
camera input rate, HD-SDI/capture raster rate, accepted source epochs, completed
output copies, unique content frames, repeated frames and the longest gap.
Compare with the rollback under the same conditions.

**Pass:** a stable output raster has no corruption or unexpected stalls; unique
content progress matches the observed accepted/finished frames and there is no
unexplained regression from the agreed baseline/rate requirement. Do not report
the display's raster rate as the stabilization update rate. Receipt sequence
progress also does not prove unique image content.

## 9. Capture pressure and EO single transitions

Exercise all connected cameras at the recorded production formats/rates, Off
and On, for at least 60 seconds per panorama mode. Include the low-angle motion
above. Record capture FIFO levels/peaks, soft drops, hard overflows, descriptor
collisions, no-common-epoch events, output FIFO alarms, displayed-bank write
conflicts, completed passes and unique content rate. Clear/record sticky flags
through the established reset procedure before each run so old alarms are not
misattributed.

Current probe23 provides the EO capture peaks/overflow subset, and probe19
provides EO descriptor-collision/no-common-epoch flags. IR capture peaks and
other requested quantities absent from the verified probe map require a future
instrumented candidate or an independently verified observation method. In
particular, do not decode current probe24 as the unconnected word2 integrity
overlay. Mark each unobservable hardware subtest NOT RUN and retain the measured
subset separately.

The fixed EO envelope is rows0..1079 and beats8..111. At six cameras x30fps its
capture-only arithmetic is 20,217,600 beats/s. At 30 output copies/s, the
1920x960 output adds 3,456,000, totaling 23,673,600. The historical 22,300,000
figure measured **aggregate DDR writes**, so it does not establish headroom:
the current EO panorama demand exceeds it by 1,373,600 beats/s. EO single
totals 24,624,000 including its 1920x1080 output. IR panorama totals 5,299,200;
IR single still captures six EO cameras in the background and therefore has
the EO panorama demand. No steady mode enables both EO and IR DDR capture.
These are conditional averages at the stated rates, not a measured limit of
the current writer or a burst-margin guarantee. Rapid selection can temporarily
widen more EO cameras. See `validation/gravity_bandwidth_review_20261016.md`.

Switch panorama to EO single and back at varied raster phases, then switch
through all EO single cameras. Repeat while changing pose, and with stopped
or returning cameras if that is part of the supported operating procedure.
Pay particular attention to the first displayed full-width frame and its outer
columns. Use an approved stall/injection setup to delay descriptor retirement
and stress source-bank reuse; if unavailable, mark that hardware subtest NOT RUN
and retain the focused simulation evidence.

**Pass:** an envelope-only in-flight bank never feeds the full-width single
reader. The accepted single copy retains its camera, bank and readiness despite
later UI/descriptor changes; newly selected output waits for a full-window
descriptor, with blank/held transition behavior recorded. No stale side columns,
mixed-camera rows, duplicate same-descriptor launch, active-bank overwrite or
display-bank write conflict occurs. Normal steady operation has no new hard
overflow/corruption alarms. Under deliberate overload, dropped/incomplete frames
must remain unpublished, the cause must be visible, and the pipeline must recover
after pressure is removed; a nonzero drop rate still needs rate acceptance.

The marker coverage flag proves the adopted window covers the configured source
dimensions; it does not independently count every received pixel/line. Verify
actual input raster completeness and format separately.

## 10. Retain the result and decide acceptance

For each test retain configuration, raw evidence, measurements, PASS/FAIL/NOT RUN
and any limitation. Preserve failed captures before reset or rollback. Stop the
acceptance run on corruption, wrong-axis amplification, unsafe bank reuse or
unexplained loss of progress; restore the identified rollback through the
established bench procedure if needed and record the reason.

Numerical simulation, routed timing, physical CDC, hardware control/coherence,
visual gravity lock, unique-content rate and physical latency are separate
acceptance items. A successful item must not silently stand in for another.
Record the calibration migration decision and residual/rate/latency criteria
alongside the final disposition; unresolved items remain open.
