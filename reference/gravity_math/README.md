# Gravity math reference

`oracle.hpp` compiles exact numerical excerpts from the translation unit selected
by the original Visual Studio project. The original project is never edited or
executed by this test. `provenance.json` records the complete source SHA-256,
original path, exact line ranges, and excerpt hashes. The runner verifies the
checked-in excerpt bytes before compiling.

Source snapshot SHA-256:
`f4dea4cbfba60bfe686644081c7bcfb4744c9d8b14771c0d916dad6702839495`.

| Snapshot | Original lines | Purpose |
| --- | --- | --- |
| `source_functions.inc` | 157, 160–170, 1027–1031, 1062–1102, 1114–1127, 1386–1526 | C rounding helpers, full trig/atan LUT construction, fixed-point matrix multiplication, integer square root, atan/asin and sensor-to-camera conversion |
| `source_clamp.inc` | 3306–3331 | Original one-pass global angle limiting block |
| `source_camera_coefficients.inc` | 4302–4308 | Integer pitch shift and negative-roll trig coefficients |
| `source_projection.inc` | 2290–2327 | Inverse source-coordinate transform and bilinear bounds |

The harness supplies the original numerical inputs and innocuous stubs for
profiling and LUT file dumps. It suppresses the clamp's informational `printf`
while including that block. It does not replace the extracted math. Factor
normalization is a narrow wrapper around source line 1011, with the zero-resize
fallback from line 1009; both expressions are recorded in the provenance.

## Python API

`model/gravity_reference.py` requires Python 3.9 or later and only the standard
library. It never reads a calibration file implicitly.

```python
from model.gravity_reference import CameraMount, compute_frame, float_to_q16

# Explicit synthetic example; these values are not production defaults.
mounts = [CameraMount(yaw_centi=0, pitch_centi=0, roll_centi=0),
          CameraMount(yaw_centi=9000, pitch_centi=0, roll_centi=0)]
frame = compute_frame(
    roll_centi=300, pitch_centi=-500, mounts=mounts,
    pitch_factor_q16=float_to_q16(-10.0),
    resize_factor_q16=float_to_q16(1.0),
)
```

- Angles are signed integer centidegrees. Mount yaw, pitch and roll are explicit
  static inputs. `CameraMount` has no calibration defaults.
- `compute_frame` returns immutable `FramePose` and `CameraPose` dataclasses. The
  result includes applied sensor angles, before-limit maximum camera angle,
  whether limiting happened, effective pitch factor, camera Euler angles,
  `cos_q15`, `sin_q15`, integer `y_shift_px` and signed `y_shift_q16`.
- Optional `yaw_centi` is retained for exact original bookkeeping. It is not a
  heading-lock input. `enabled=False` zeroes all live angles while preserving
  static mounting corrections.
- `float_to_q16` and `degrees_to_centi` first round the supplied value to float32,
  matching the original C helper parameter type, then use C half-away-from-zero
  rounding. `pitch_factor_q16` is the configured factor **before** resize
  normalization. It must not already have been divided by resize.
- `convert_rpy_sensor_to_cam_centi` exposes the unclamped matrix conversion;
  `angle_tables` returns immutable full trig and atan tables.
- `project_base_coordinate` applies source-Y translation before rotation around
  `(width/2,height/2)`. It is a coordinate probe, not a RowRun renderer.

The source's 32767 unity, asymmetric matrix rounding, integer pitch shift and
one-pass limit are deliberately retained. Zero live orientation bypasses the
limit, even if static trims exceed ten degrees. Nonzero live yaw alone can
trigger limit bookkeeping but cannot change the camera geometry for zero live
roll/pitch. The final pose may still exceed ten degrees after one pass because
static trims are not scaled.

The original source shifts some negative signed integers left. Strict ISO C++
does not define those expressions, so the validation target is their observed
MSVC x64 behavior, including arithmetic right shifts. The Python reference
retains signed 32-bit narrowing at the corresponding output points. Another
compiler must pass this suite before being treated as equivalent.

## Run the comparison

From the repository root on this Windows workstation:

```powershell
python scripts/test_gravity_math.py --ini config/parameters_unified.ini
# Equivalent PowerShell entry point:
./scripts/test_gravity_math.ps1 -Ini config/parameters_unified.ini
```

Without `--ini`, only explicit synthetic fixtures are used. An INI supplied to
the test is evidence for numerical comparison, never a fixed startup attitude.
The runner locates the installed MSVC tools using `vswhere`, compiles with
`/O2 /fp:precise`, and writes all artifacts under `build/gravity_math/`. It does
not install dependencies or access camera/FPGA hardware. On non-Windows hosts it
can try an existing `c++`, `g++` or `clang++`; MSVC remains the verified target.

Default coverage includes all 36,000 trig entries, all 4,097 atan-ratio entries,
the entire signed Q15 asin domain plus saturation, integer-square-root and
signed-division edge cases, 2,000 deterministic random frame poses, direct
matrix cases around singularities, limit boundaries, 90/180/360/390-degree yaw,
mixed mount trims, disabled stabilization, and mapped coordinate checks.
The exact extracted C++ functions are the golden oracle, rather than a second
handwritten matrix implementation.

`results.json` records comparison counts, seed, compiler configuration, source
and binary hashes, and the explicit INI hash. `directed_results.json` includes
reviewable coefficient vectors. A failure records the request and first
different result token in `failure.json` and exits unsuccessfully.

Initial validated run with the confirmed production INI compared **245,237
integer values in 79,397 requests, with zero differences**. The compiler log
contained no warnings. The production INI SHA-256 was
`7106b1f1ad56d545c6b3eef5b29f9608fdb1cfb02ce364b1ca85ca096c3eea3c`.

For that INI the source's Q16 calculation yields an EO effective pitch factor
of **-1140855 / 65536 = approximately -17.408 pixels/degree** from configured
`-9.80` and resize `0.56296`. IR yields **-571474 / 65536**, approximately -8.72.
The existing RTL baseline's -9.8 table factor is a separate coordinate-path
contract; these tests do not retune it or claim end-to-end image equivalence.

## Real-time boundary

The desktop source computes a pose once before replaying static test images.
The Python API computes one frozen pose per explicit call. Neither implements
IMU transport, sample timestamps, exposure alignment, rolling shutter or latency
compensation. A real-time design must capture one coherent IMU sample and commit
the pose together with dependent row spans, reverse indexes and completion
bounds at a frame boundary. Coefficient equivalence alone does not validate
those scheduling updates, complete camera image quality or hardware timing.

## RTL ROMs and raw engine vectors

These checked-in assets are generated from the **compiled C++ oracle output**.
The generator does not use Python-computed LUT entries or expected camera angles.

| File | Format |
| --- | --- |
| `reference/gravity_math/angle_centi_q15.mem` | 36,000 hexadecimal 32-bit words; bits 31:16 = signed cosine, bits 15:0 = signed sine; address = centidegrees modulo 36,000 |
| `reference/gravity_math/atan_ratio_centi.mem` | 4,097 hexadecimal 16-bit words; address = rounded ratio index 0..4096; data = atan centidegrees 0..4500 |
| `sim/gravity_math/engine_vectors.txt` | 1,342 rows, eight signed decimal integers per row, no header |
| `sim/gravity_math/engine_vectors.json` | The same inputs/expected outputs with vector indices and coverage-group labels |
| `reference/gravity_math/rtl_assets_manifest.json` | Source/producer/response/asset hashes, ROM layout, vector field order and coverage counts |

Vector fields, all in centidegrees, are:

```text
sensor_roll sensor_pitch mount_yaw mount_pitch mount_roll camera_roll camera_pitch camera_yaw
```

They test the raw `convert_rpy_sensor_to_cam_centi` function; **no global limit is
applied**. Coverage includes zero input, 90/180-degree cameras, full-circle and
390-degree yaw, ±10-degree edges, sign changes, mixed static trims, near-singular
orientations and signed32 minimum/maximum in every input. The 1,000 deterministic
random vectors include 250 full signed32 inputs and 750 operating-range poses.
The remaining 342 vectors are directed. Live sensor yaw is absent because the
original conversion function has no such input.

```powershell
# Recompile the exact C++ oracle and verify every checked-in asset byte:
python reference/gravity_math/export_rtl_assets.py

# Deliberately regenerate golden assets (requires installed MSVC):
python reference/gravity_math/export_rtl_assets.py --write
```

Both commands write compiler/execution evidence only under
`build/gravity_math/rtl_export/`; only `--write` updates the checked-in assets.
The export and a fresh-compile verification passed with identical asset hashes.
The executable hash is recorded separately per run because PE build timestamps
can change it; numerical asset hashes and the checked-in manifest are stable.
Scoped `.gitattributes` preserve ROM/vector line endings and source-excerpt
bytes across checkouts.
