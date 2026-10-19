# EO / IR gravity-locked stabilization

Development repository for adding live, gravity-referenced roll/pitch
stabilization to the proven EO/IR source-driven FPGA renderer.

## Selected baseline

The starting point is **3479cacf2e512a5bde9aa3e0243755826e071ef4**,
`Fix EO single: write the displayed camera's whole frame`, selected by the
user as the last stable correct-output build. Later camera/ILA experiments
are excluded. The original repository and its working files are untouched.

The selected calibration is copied exactly to
[`config/parameters_unified.ini`](config/parameters_unified.ini), from
`EO_IR_TestCases/EO_Test4C_R_0.75_P_-5/480_test` in the original C project.
Its `[eo_orientation]` and `[ir_orientation]` values are test poses, not a
replacement for live IMU data.

[`docs/BASELINE_PROVENANCE.json`](docs/BASELINE_PROVENANCE.json) records the
commit/tree, calibration hash and stable archive hashes. A byte-identical
copy of the stable `.bit`, `.ltx`, `.mcs` and reports is retained locally under
`builds/baseline_20260930_202000_eosingle_fullwrite_3479cac/`. Generated binaries
are excluded from Git. `main` preserves the selected baseline; development
is on `codex/gravity-lock`.

## Current status

This is **implementation in progress**, not a hardware-qualified build.
The live gravity path is connected to the EO/IR panorama renderer and the MCU
source is updated. Hardware has not been programmed for this work.

The first corrected full FPGA candidate completed on 2026-10-16 at 02:54 KST
from RTL commit `cbb95ad`. Routed setup/hold/pulse-width slack is
**+0.075 / +0.010 / +0.064 ns**, with zero failing endpoints. All 143,118
routable nets are routed; bus-skew, DRC-error and scoped gravity timing/CDC
guards pass. The matched `.bit` and `.ltx`, routed checkpoint, reports and MCU
candidate are retained locally under `builds/gravity_20261016_020605/`.
The committed [build record](docs/validation/full_build_20261016_020605.json)
contains their hashes. These files are build candidates, not bench results.
The [full CDC review](docs/validation/gravity_full_cdc_review_20261016.md)
retains inherited open findings. Sustained DDR throughput, source-bank ownership
under long stalls, rig axis signs and physical stabilization remain unqualified.

The user selected the existing UI **On + Attitude Sensor** controls and
preservation of the stable optical maps/pixel geometry. The selected INI supplies
the camera mounting yaw angles; the existing EO/IR static roll/pitch banks remain
the mounting trims. Its test orientation and differing optical-map settings are
not applied. Disabling stabilization preserves static-offset rendering exactly.
The user approved one-time INI mounting migration on 2026-10-19. The MCU now
replaces the mounting arrays once, preserves unrelated settings, and retains
later UI calibration across boots using a two-page journal. Calibration
Get/Apply works alongside ICD operation and accepts both supported feather
encodings. See [calibration storage](docs/GRAVITY_CALIBRATION_STORAGE.md).
Firmware has not been flashed; the earlier archived MCU candidate predates
this migration and must not be mistaken for the new firmware.

Implemented and simulated:

- Exact extracted C++ numerical oracle and independently implemented Python
  model, including per-camera mounting rotation, fixed-point rounding and the
  original one-pass global angle limit.
- `GlPoseReceiver`: commits the four IMU angle bytes only after the complete
  acknowledged I2C transaction ends; rejects partial or malformed updates.
- `GlPoseCdc`: transfers the coherent angle pair and receipt sequence between
  clocks, retaining the latest pending update under load.
- `GlCameraProjection`: synthesizable, sequential camera-angle computation
  using the exact C lookup tables; matches all 1,342 C-generated vectors.
- `GlPoseEpochHistory`: saves a coherent pose with a complete frame-epoch tag,
  calibration revision, enable state and freshness; rejects overwritten tags.
- `GlFramePose`: computes all six cameras and the C global limit, publishing
  one atomic result; 266 reference/bypass cases pass.
- `GlLeasePose`: chooses the historical pose for the actual source lease and
  sensor family, with separate EO-strobe and IR-genlock histories, and freezes
  coefficients through the render. Missing/stale/disabled data selects
  static offsets. The default freshness threshold is 100 ms at 233.4 MHz.
- `RpRenderer`: accepts the frozen set, builds from that same snapshot, and
  holds it throughout the frame. The EO writer uses a proven fixed capture
  region so old source banks contain every pixel needed by any allowed angle.
- MCU firmware under `firmware/eo_osd_remote`: sends acknowledged/retryable
  stabilization control at register `0x04` and forwards poses in panorama modes.

See [`reference/gravity_math/README.md`](reference/gravity_math/README.md) for
the math API and evidence, and
[`docs/GRAVITY_IMPLEMENTATION.md`](docs/GRAVITY_IMPLEMENTATION.md) for
implementation details, validation limits and remaining hardware checks.

## Verification

Run from this repository root with Python 3.9+ and the installed Vivado 2025.2
tools. The C++ comparison locates the installed MSVC toolchain.

```powershell
python scripts/verify_gravity_baseline.py
python scripts/verify_gravity_baseline.py --archive  # local preserved build
python scripts/test_gravity_math.py --ini config/parameters_unified.ini
./scripts/test_gl_pose_receiver.ps1
./scripts/test_gl_pose_cdc.ps1
./scripts/test_gl_camera_projection.ps1
./scripts/test_gl_pose_epoch_history.ps1
./scripts/test_gl_frame_pose.ps1
./scripts/test_gl_lease_pose.ps1
./scripts/test_gl_i2c_input.ps1
./scripts/test_rp_renderer.ps1
python scripts/audit_gravity_geometry.py
```

The standalone test scripts create ignored `build/` or `builds/` products and
do not access the hardware. The inherited XPR and historical scripts are kept
for provenance; some contain old project paths. Use the dedicated gravity
project creation entry point documented in
[`docs/GRAVITY_VIVADO_PROJECT.md`](docs/GRAVITY_VIVADO_PROJECT.md), rather than
launching historical build/program scripts.
