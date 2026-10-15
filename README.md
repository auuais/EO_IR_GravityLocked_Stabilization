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

This is **implementation in progress**, not a new hardware-qualified build.
The existing renderer has not yet been connected to live gravity coefficients.
No FPGA programming or MCU firmware change has been performed for this work.

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

See [`reference/gravity_math/README.md`](reference/gravity_math/README.md) for
the math API and evidence, and
[`docs/GRAVITY_IMPLEMENTATION.md`](docs/GRAVITY_IMPLEMENTATION.md) for remaining
integration work and the differences that must be resolved before hardware use.

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
python scripts/audit_gravity_geometry.py
```

The standalone test scripts create ignored `build/` or `builds/` products and
do not access the hardware. The inherited XPR and historical scripts are kept
for provenance; some contain old project paths. Use the dedicated gravity
project creation entry point documented in
[`docs/GRAVITY_VIVADO_PROJECT.md`](docs/GRAVITY_VIVADO_PROJECT.md), rather than
launching historical build/program scripts.
