# Integrated gravity capture and frame association review

Read-only review of production RTL at `ea3286e`, while full build
`builds/gravity_20261016_012049` is running. The current build is a timing and
experimental function candidate; this review does not establish dual-family
pose association or 30 unique frames/s. No hardware was accessed.

## Correct aggregate write accounting

`HANDOFF_EO_PANORAMA_30FPS_20260903.md:804-829` explicitly reports **22.3 million
aggregate DDR write beats/s**, counts output-frame writes as well as camera
capture, and associates insufficient descriptor supply with lower unique
frame rate. Earlier gravity documentation incorrectly treated that number as
a capture-only budget. It is a historical observation, not a measured maximum
for the current writer. The older handoff's rounded 27.2M total used a full
1080-row output; the integrated panorama below writes 960 rows.

All rates below assume 30 captured frames/s per enabled camera and 30 completed
output copies/s. They count DDR application writes, exclude reads/refresh and
burst contention, and do not infer actual bench clocks or frame rates.

| Mode | EO capture beats/s | IR capture beats/s | Output beats/frame | Output beats/s | Total writes/s | Margin vs historical 22.3M |
|---|---:|---:|---:|---:|---:|---:|
| EO panorama | 20,217,600 | 0 | 115,200 | 3,456,000 | **23,673,600** | **-1,373,600** |
| EO single, one full camera | 20,736,000 | 0 | 129,600 | 3,888,000 | **24,624,000** | **-2,324,000** |
| IR panorama | 0 | 1,843,200 | 115,200 | 3,456,000 | **5,299,200** | +17,000,800 |
| IR single | 20,217,600 | 0 | 115,200 | 3,456,000 | **23,673,600** | **-1,373,600** |

Sources in `src/PanoramaBase_DdrBlackFrame.v`:

- Lines 201-223: 16 output pixels/beat; 1920x960 panorama and IR-single output,
  1920x1080 EO-single output. Lines 793-794 select the active beat count.
- Lines 1850-1877: six EO envelopes contain 104x1080 beats per camera; the
  selected EO single camera instead contains 120x1080. EO capture is enabled
  by `running && !ir_stack_ui`.
- Lines 2027-2034 and the five following IR writers: each IR capture is
  640x512 at 32 pixels/beat, enabled only by `running && ir_stack_ui`.
- Lines 2495-2570: IR single reads its BRAM source but emits a padded full
  1920x960 output. Six EO DDR captures continue in this mode.
- Lines 4052-4059 and 4117-4213: output and capture writes share the command
  path. There are no additional steady concurrent EO+IR DDR camera writes;
  mode-transition drain traffic and bursts still need measurement.

The historical fixed EO window (88 beats x1008 rows) plus the current 960-row
output totals **19,422,720 writes/s** at 30 fps. The new fixed envelope adds
4,250,880 writes/s (21.89%). Its EO panorama total is 6.16% above the historical
aggregate observation. If that observation still applies, the current EO
30-fps demand cannot be sustained. It does **not** prove the newer implementation
cannot exceed that observation, nor establish a guaranteed lower frame rate:
frame drops, bank availability, all-camera epoch matching, replay reads and
burst arbitration can reduce the achieved rate further. The old measurement
must not be used to promise a new rate in either direction.

Two temporarily full EO cameras plus four envelopes and a 1080-row output
would total **25,142,400 writes/s**; six full cameras plus that output would
total **27,216,000**. Arbitrary rapid selection is not bounded to two full
frames in flight because each writer adopts a new window at its own next
frame boundary.

## Why a capture-only row interval ROM does not cover the present fetch contract

The current `RpTables` produces one global `col_lo/col_hi` envelope; the
renderer rounds it to eight-beat batches (`RpRenderer.v:325-334`). Replay
uses those same horizontal bounds for every requested source row and camera
(`EoV19DdrDesync.v:933-941,1220-1237`). A direct calculation from the checked-in
segment and angle ROMs gives these allowed uniform final-camera poses:

| Final camera roll/pitch (cd) | Raw source column extrema | Raw source row extrema | Clamped replay rows | Replay beat interval |
|---|---|---|---|---|
| -1000 / 0 | 204..1681 | -58..1161 | 0..1079 | 8..111 |
| +1000 / 0 | 200..1677 | -64..1155 | 0..1079 | 8..111 |

Thus a row-dependent **capture-only** interval preserving coverage of every
current replay fetch cannot reduce this full rectangular worst-case union.
This is a small witness calculation, not another exhaustive proof run. The
existing exhaustive proof remains unchanged. Avoiding capture of unused pixels
inside fetched batches would require a different proof of every actual sampler
access; changing replay to row/camera-specific bounds would require coordinated
fetch and coverage changes and new pixel regressions.

## Feasible next choices, preserving source pose association

1. Measure the present writer, including output writes and replay reads, before
   deciding whether a performance change is necessary. Record unique content
   rate, descriptor starvation, capture drops and hard overflows separately.
2. Improve DDR command efficiency or safely group writes while preserving
   marker ordering and existing leases. Average rate alone cannot validate
   burst tolerance; test with the full capture/read/output workload.
3. Use a deliberately tighter supported angle envelope only with an explicit
   product decision and a regenerated proof. It changes the supported range.
   A 96-beat full-height envelope would total22,118,400 writes/s at30fps, leaving
   only181,600 against the old observation; this is an arithmetic example,
   **not** proof that a chosen range maps into that envelope or has burst margin.
4. Compute a capture window from the same pose epoch **before** capture and
   attach that pose/window identity to the descriptor. This preserves lease
   lookup but needs a scheduling proof: a result arriving after frame start
   cannot be used for that frame, and static/enable/calibration changes need
   the same epoch treatment. Applying a lease-time pose to an older narrow
   capture remains invalid. Prediction alone is insufficient without a proved
   motion bound and explicit fallback coverage.
5. Direct output streaming/bypass could remove the3.456M panorama output writes,
   but the current display buffering/clock/backpressure contract depends on
   those buffers. This is a larger architectural change requiring independent
   proof of stall handling and stable HD raster timing.

## Additional concrete deployment gaps

**IR pose association was incorrect in the reviewed candidate.** The IR cameras
are driven by independent `IrGenlockGenerator` (module default29.97Hz;
`KintexTop_EO_IR_HD_SDI_panorama_base.v:645-657`), but the six IR DDR writers
currently receive the EO `v19_global_epoch_gray` (`PanoramaBase_DdrBlackFrame.v:2042`
and following instances). `GlLeasePose` history captures only
`eo_strobe_edge_ui` (line1829). Equal integer tags therefore do not identify
the IR genlock that exposed a frame. Independent phase/drift can change the
pose-to-image delay without stale/history flags detecting it. Fix requires an
IR-trigger epoch shared by IR writer tagging and a separate IR pose history;
the existing IR pulse already enters the compositor, so no new hardware signal
is required. Current lease tests with a single abstract epoch source do not
prove this physical dual-family association. Do not label this only a bench
throughput limitation or claim dual EO/IR association from the current build.

Correction status: that build was subsequently stopped during placement.
Independent IR trigger tags and two continuously captured family histories
have been implemented and passed 21 lease cases plus trigger alignment/reset/
full-wrap tests. See `ir_epoch_association_20261016.json` for source hashes.
The corrected source needs a fresh full implementation/CDC result; it still
does not establish physical genlock-to-exposure or IMU latency.

**EO single freezes a bank number, not ownership.** The selector fixes camera,
bank and readiness for a copy, but `v19_consumer_done` is always asserted in
EO single (lines1184-1188). The frame-set manager may return that same bank
token through its release sweep (`EoV19FrameSetManager.v:663-746`) while a
single-reader copy is stalled. There is no per-bank single-reader hold input.
This is an inherited structural risk, not an observed failure in the normal
bench rate. The focused selector test does not include full manager/writer
bank reuse. A source-bank pin/refcount or a proved bounded-read retention
contract is needed before claiming safety under arbitrary DDR stalls.

Full-top synthesis finds no unconstrained internal endpoints or ignored paths
inside the gravity controller. That is construct/constraint evidence only;
routed timing, physical mailbox/reset checks and the above functional/runtime
requirements remain separate acceptance items.

## Correction provenance

Only bandwidth metadata and documentation changed in this review. The command
`python scripts/gravity_capture_envelope.py --budget-only` verifies both ROM
hashes, preserves the previously recorded geometry proof, and recomputes the
traffic fields. It does not rerun the253,566,720 endpoint evaluations or any
completed RTL simulation. Renderer test status remains PASS within its recorded
unit/pixel scope; system throughput and dual-family epoch association do not.
