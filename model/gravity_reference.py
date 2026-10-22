"""Integer gravity-lock reference for the compiled desktop C++ algorithm.

All public angles are signed integer centidegrees; a mount is an explicit static
calibration input, never a guessed production profile. The rotation order is
Rx(live roll) * Ry(live pitch) * Rz(mount yaw) * Ry(mount pitch) * Rx(mount roll).
Live yaw is retained only because the original one-pass limit bookkeeping uses
it; it does not provide heading stabilization. Disabled stabilization zeros the
live orientation but retains static camera mounting corrections.

This module computes a frozen pose for one explicitly captured frame. The source
program instead computes it once before replaying static images. Neither this
module nor the source associates an IMU sample with a sensor exposure, handles
rolling shutter, estimates latency, or updates row scheduling atomically. A live
implementation must capture a coherent sample and commit coefficients together
with all dependent spans/reverse indexes/row bounds at a frame boundary.

Numerical quirks are deliberate: unity is 32767, matrix products add 16384 even
when negative, pitch shift is integer pixels, translation precedes rotation,
and the 10-degree limiter scales live angles once without iterating static trims.
Source hashes and exact extracted functions live in reference/gravity_math/.
No external packages are required (Python 3.9+).
"""

from dataclasses import dataclass
from functools import lru_cache
import math
import struct
from typing import Optional, Sequence, Tuple


WFIX_SHIFT = 16
ATAN_RATIO_LUT_SIZE = 4096
DEFAULT_MAX_CAM_ANGLE_CENTI = 1000  # Source default, not a calibration value.


def _int32(value: int) -> int:
    """MSVC signed 32-bit narrowing; used only at original narrowing points."""
    return ((value + (1 << 31)) % (1 << 32)) - (1 << 31)


def _trunc_div(num: int, den: int) -> int:
    quotient = abs(num) // abs(den)
    return -quotient if (num < 0) != (den < 0) else quotient


def _lround(value: float) -> int:
    return math.floor(value + 0.5) if value >= 0 else math.ceil(value - 0.5)


def _float32(value: float) -> float:
    return struct.unpack("<f", struct.pack("<f", value))[0]


def degrees_to_centi(degrees: float) -> int:
    """Match source deg_to_centi(float), including the input float32 rounding."""
    return _int32(_lround(float(_float32(degrees)) * 100.0))


def float_to_q16(value: float) -> int:
    """Match source float_to_q16(float), not Python's ties-to-even round."""
    return _int32(_lround(float(_float32(value)) * 65536.0))


def div_round_i64(num: int, den: int) -> int:
    """Original C division, including its denominator-zero and sign quirks."""
    if den == 0:
        return 0
    half_den = _trunc_div(den, 2)
    return _int32(_trunc_div(num + half_den if num >= 0 else num - half_den, den))


@lru_cache(maxsize=1)
def angle_tables() -> Tuple[Tuple[Tuple[int, int], ...], Tuple[int, ...]]:
    """Full 0.01-degree Q15 table and inclusive Q0.12 atan-ratio table."""
    trig = []
    for index in range(36000):
        degrees = float(index) * 0.01
        radians = degrees * math.pi / 180.0
        trig.append((_lround(math.cos(radians) * 32767.0),
                     _lround(math.sin(radians) * 32767.0)))
    atan = tuple(_lround(math.atan(float(index) / 4096.0) * 18000.0 / math.pi)
                 for index in range(4097))
    return tuple(trig), atan


def get_cos_sin_q15_centi(centi: int) -> Tuple[int, int]:
    return angle_tables()[0][centi % 36000]


def clamp_q15_from_q30(value: int) -> int:
    return max(-32768, min(32767, (value + (1 << 14)) >> 15))


def matmul_q15(a: Sequence[Sequence[int]], b: Sequence[Sequence[int]]) -> Tuple[Tuple[int, ...], ...]:
    return tuple(tuple(clamp_q15_from_q30(sum(a[i][k] * b[k][j] for k in range(3)))
                       for j in range(3)) for i in range(3))


def isqrt_u64(value: int) -> int:
    """The source's restoring integer square root, kept explicit for review."""
    if not 0 <= value < (1 << 64):
        raise ValueError("isqrt_u64 requires an unsigned 64-bit value")
    result = 0
    bit = 1 << 62
    while bit > value:
        bit >>= 2
    while bit:
        if value >= result + bit:
            value -= result + bit
            result = (result >> 1) + bit
        else:
            result >>= 1
        bit >>= 2
    return result


def atan2_centi_q15(y_q15: int, x_q15: int) -> int:
    if y_q15 == 0 and x_q15 == 0:
        return 0
    ay, ax = abs(y_q15), abs(x_q15)
    if ax == 0:
        base = 9000
    elif ay <= ax:
        index = max(0, min(4096, (ay * 4096 + ax // 2) // ax))
        base = angle_tables()[1][index]
    else:
        index = max(0, min(4096, (ax * 4096 + ay // 2) // ay))
        base = 9000 - angle_tables()[1][index]
    if x_q15 >= 0:
        return base if y_q15 >= 0 else -base
    return 18000 - base if y_q15 >= 0 else base - 18000


def asin_centi_q15(value: int) -> int:
    value = max(-32767, min(32767, value))
    remainder = max(0, (1 << 30) - value * value)
    return atan2_centi_q15(value, isqrt_u64(remainder))


@dataclass(frozen=True)
class CameraMount:
    yaw_centi: int
    pitch_centi: int
    roll_centi: int


@dataclass(frozen=True)
class CameraAngles:
    roll_centi: int
    pitch_centi: int
    yaw_centi: int


def convert_rpy_sensor_to_cam_centi(roll_centi: int, pitch_centi: int,
                                  mount: CameraMount) -> CameraAngles:
    cr, sr = get_cos_sin_q15_centi(roll_centi)
    cp, sp = get_cos_sin_q15_centi(pitch_centi)
    cro, sro = get_cos_sin_q15_centi(mount.roll_centi)
    cpo, spo = get_cos_sin_q15_centi(mount.pitch_centi)
    cyo, syo = get_cos_sin_q15_centi(mount.yaw_centi)
    rx = ((32767, 0, 0), (0, cr, -sr), (0, sr, cr))
    ry = ((cp, 0, sp), (0, 32767, 0), (-sp, 0, cp))
    rr = ((32767, 0, 0), (0, cro, -sro), (0, sro, cro))
    rp = ((cpo, 0, spo), (0, 32767, 0), (-spo, 0, cpo))
    rz = ((cyo, -syo, 0), (syo, cyo, 0), (0, 0, 32767))
    rsys = matmul_q15(rx, ry)
    rt = matmul_q15(rz, rp)
    roff = matmul_q15(rt, rr)
    rotation = matmul_q15(rsys, roff)
    camera_pitch = asin_centi_q15(-rotation[2][0])
    cos_pitch, _ = get_cos_sin_q15_centi(camera_pitch)
    if abs(cos_pitch) > 8:
        camera_roll = atan2_centi_q15(rotation[2][1], rotation[2][2])
        camera_yaw = atan2_centi_q15(rotation[1][0], rotation[0][0])
    else:
        camera_roll = 0
        camera_yaw = atan2_centi_q15(-rotation[0][1], rotation[1][1])
    return CameraAngles(camera_roll, camera_pitch, camera_yaw)


@dataclass(frozen=True)
class CameraPose:
    roll_centi: int
    pitch_centi: int
    yaw_centi: int
    cos_q15: int
    sin_q15: int
    y_shift_px: int
    y_shift_q16: int


@dataclass(frozen=True)
class FramePose:
    requested_orientation: Tuple[int, int, int]
    applied_orientation: Tuple[int, int, int]
    enabled: bool
    max_camera_angle_before_limit: int
    limit_applied: bool
    effective_pitch_factor_q16: int
    cameras: Tuple[CameraPose, ...]


def compute_frame(roll_centi: int, pitch_centi: int, mounts: Sequence[CameraMount], *,
                  pitch_factor_q16: int, resize_factor_q16: int,
                  enabled: bool = True, yaw_centi: int = 0,
                  max_cam_angle_centi: int = DEFAULT_MAX_CAM_ANGLE_CENTI) -> FramePose:
    """Compute one immutable frame pose with the original one-pass global limit.

    pitch_factor_q16 is the INI factor before dividing by resize. Zero resize
    matches the source's fallback to Q16 unity. A zero live orientation skips
    the limit entirely, even when a static trim exceeds it. Scaling does not
    guarantee the final pose falls within the limit because trims remain fixed.
    """
    if not mounts:
        raise ValueError("At least one explicit camera mount is required")
    values = [roll_centi, pitch_centi, yaw_centi, pitch_factor_q16,
              resize_factor_q16, max_cam_angle_centi]
    values.extend(value for mount in mounts for value in
                  (mount.yaw_centi, mount.pitch_centi, mount.roll_centi))
    if any(not isinstance(value, int) or not -(1 << 31) <= value < (1 << 31) for value in values):
        raise ValueError("Angles and Q16 inputs must be signed 32-bit integers")
    if max_cam_angle_centi <= 0:
        raise ValueError("The camera angle limit must be positive")
    requested = (roll_centi, pitch_centi, yaw_centi)
    if not enabled:
        roll_centi = pitch_centi = yaw_centi = 0
    max_camera_angle = 0
    if roll_centi != 0 or pitch_centi != 0 or yaw_centi != 0:
        for mount in mounts:
            angles = convert_rpy_sensor_to_cam_centi(roll_centi, pitch_centi, mount)
            max_camera_angle = max(max_camera_angle, abs(angles.roll_centi), abs(angles.pitch_centi))
    limited = max_camera_angle > max_cam_angle_centi
    if limited:
        roll_centi = div_round_i64(roll_centi * max_cam_angle_centi, max_camera_angle)
        pitch_centi = div_round_i64(pitch_centi * max_cam_angle_centi, max_camera_angle)
        yaw_centi = div_round_i64(yaw_centi * max_cam_angle_centi, max_camera_angle)
    effective_factor = div_round_i64(pitch_factor_q16 << 16, resize_factor_q16 or 65536)
    cameras = []
    for mount in mounts:
        angles = convert_rpy_sensor_to_cam_centi(roll_centi, pitch_centi, mount)
        y_shift_px = div_round_i64(effective_factor * angles.pitch_centi, 100 * 65536)
        cosine, sine = get_cos_sin_q15_centi(-angles.roll_centi)
        cameras.append(CameraPose(angles.roll_centi, angles.pitch_centi, angles.yaw_centi,
                                  cosine, sine, y_shift_px, _int32(y_shift_px << 16)))
    return FramePose(requested, (roll_centi, pitch_centi, yaw_centi), bool(enabled),
                     max_camera_angle, limited, effective_factor, tuple(cameras))


@dataclass(frozen=True)
class SampleCoordinate:
    valid: bool
    x_q16: int
    y_q16: int
    source_row: Optional[int]


def project_base_coordinate(base_x_q16: int, base_y_q16: int, width: int, height: int,
                            pose: CameraPose) -> SampleCoordinate:
    """Original inverse sample map: translate source Y, then rotate about W/2,H/2."""
    if width < 2 or height < 2:
        raise ValueError("Bilinear source dimensions must be at least two pixels")
    cx, cy = width << 15, height << 15
    dx = _int32(base_x_q16 - cx)
    dy = _int32(_int32(base_y_q16 + pose.y_shift_q16) - cy)
    ax = _int32(((pose.cos_q15 * dx + pose.sin_q15 * dy) >> 15) + cx)
    ay = _int32(((-pose.sin_q15 * dx + pose.cos_q15 * dy) >> 15) + cy)
    valid = 0 <= ax <= ((width - 2) << 16) and 0 <= ay <= ((height - 2) << 16)
    row = (ay >> 16) if valid else None
    return SampleCoordinate(valid, ax, ay, row)
