"""Prove a fixed EO capture window for the checked-in segment/angle ROMs.

Exhaust all 2,001 clamped roll centidegrees, both pitch-shift extrema, and both
endpoints of every affine segment. For a fixed roll, each endpoint coordinate
is monotone in pitch shift (floor preserves monotonicity); all intermediate
pitch shifts and all pixels along each affine segment are therefore bounded.
This uses the actual Q15=32768 renderer ROM and its per-step truncation, not the
separate Q15=32767 camera-orientation projection.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def signed(value, width):
    return value - (1 << width) if value & (1 << (width - 1)) else value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'docs/validation/gravity_capture_envelope.json')
    args = parser.parse_args()
    run_path = ROOT / 'assets/rowruns/eo_v19_render_runs.mem'
    angle_path = ROOT / 'assets/rollpitch/eo_rp_angle.mem'
    records = [int(word, 16) for word in run_path.read_text().split()]
    angles = [int(word, 16) for word in angle_path.read_text().split()]
    assert len(records) == 480 * 6 * 11 and len(angles) == 1001
    ax0 = np.array([signed((word >> 48) & 0xffffffff, 32) for word in records], dtype=np.int64)
    ay0 = np.array([signed((word >> 80) & 0xffffffff, 32) for word in records], dtype=np.int64)
    dx = np.array([signed((word >> 112) & 0xffff, 16) << 11 for word in records], dtype=np.int64)
    dy = np.array([signed((word >> 128) & 0xffff, 16) << 11 for word in records], dtype=np.int64)
    widths = (650, 655, 655, 655, 655, 655)
    last = np.array([min(64, widths[(i // 11) % 6] - (i % 11) * 64) - 1
                     for i in range(len(records))], dtype=np.int64)
    shifts = [(-1 if pitch < 0 else 1) * signed((angles[abs(pitch)] >> 33) & 255, 8)
              for pitch in range(-1000, 1001)]
    shift_limits = [min(shifts), max(shifts)]
    assert shift_limits == [-98, 98], 'Stable EO pitch factor/ROM changed; review the proof scope'
    cx, cy = 960 << 16, 540 << 16
    centered_x = ax0 - cx
    for values in (centered_x, ay0 + (shift_limits[0] << 16) - cy,
                   ay0 + (shift_limits[1] << 16) - cy, dx, dy):
        assert int(values.min()) >= -(1 << 26) and int(values.max()) < (1 << 26)
    extrema = {key: None for key in ('x_min', 'x_max', 'y_min', 'y_max')}
    witnesses = {}
    max_abs_step = [0, 0]
    for roll in range(-1000, 1001):
        word = angles[abs(roll)]
        c = word & 0x1ffff
        smag = (word >> 17) & 0xffff
        s = -smag if roll > 0 else smag if roll < 0 else 0
        step_x = (c * dx + s * dy) >> 15
        step_y = (-s * dx + c * dy) >> 15
        max_abs_step[0] = max(max_abs_step[0], int(np.abs(step_x).max()))
        max_abs_step[1] = max(max_abs_step[1], int(np.abs(step_y).max()))
        for shift in shift_limits:
            centered_y = ay0 + (shift << 16) - cy
            first_x = ((c * centered_x + s * centered_y) >> 15) + cx
            first_y = ((-s * centered_x + c * centered_y) >> 15) + cy
            for endpoint, xs, ys in ((0, first_x, first_y),
                                      (1, first_x + last * step_x, first_y + last * step_y)):
                for axis, values in (('x', xs), ('y', ys)):
                    assert int(values.min()) >= -(1 << 31) and int(values.max()) < (1 << 31)
                    for suffix, arg in (('min', np.argmin), ('max', np.argmax)):
                        index = int(arg(values))
                        value = int(values[index])
                        key = axis + '_' + suffix
                        if extrema[key] is None or (value < extrema[key] if suffix == 'min' else value > extrema[key]):
                            extrema[key] = value
                            witnesses[key] = {'roll_cd': roll, 'pitch_shift_rows': shift,
                                              'output_row': index // 66, 'camera': (index // 11) % 6,
                                              'segment': index % 11, 'pixel_in_segment': int(last[index]) if endpoint else 0}
    assert max(max_abs_step) < (1 << 23)
    col_lo = max(0, min(1918, extrema['x_min'] >> 16))
    # RpTables stores the maximum clamped endpoint column PLUS ONE. This
    # covers qx_phase's possible upward parity adjustment before batching.
    col_hi = max(0, min(1918, extrema['x_max'] >> 16)) + 1
    row_lo = max(0, min(1078, extrema['y_min'] >> 16))
    row_hi = max(0, min(1078, extrema['y_max'] >> 16)) + 1
    # Match RpRenderer's parity guard and eight-beat replay batch rounding.
    beat_lo = (max(0, col_lo - 1) // 128) * 8
    beat_hi = min(119, (col_hi // 128) * 8 + 7)
    beats = (beat_hi - beat_lo + 1) * (row_hi - row_lo + 1)
    report = {
        'scope': 'Stable EO optical segment geometry, renderer clamp +/-1000 cd, checked-in -9.8 pitch translation ROM',
        'sources': {str(path.relative_to(ROOT)).replace('\\', '/'): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in (run_path, angle_path)},
        'proof': {'roll_values_exhausted': 2001, 'pitch_cd_domain': [-1000, 1000],
                  'pitch_shift_limits_rows': shift_limits, 'segments': len(records), 'endpoints_per_segment': 2,
                  'endpoint_evaluations': 2001 * 2 * 2 * len(records),
                  'argument': 'For fixed roll, transformed segment endpoints are monotone in integer pitch shift. Pixels are affine between endpoints after exact step truncation. Endpoint bounds cover all pitches/pixels; eight-beat expansion also covers qx_phase parity and replay batches.',
                  'stage1_signed27_range_verified': True, 'accumulator_signed32_range_verified': True,
                  'step_signed24_range_verified': True, 'maximum_absolute_steps_q16': max_abs_step},
        'coordinate_extrema_q16': extrema, 'extrema_witnesses': witnesses,
        'clamped_endpoint_columns': [col_lo, col_hi - 1],
        'table_column_limits_including_upper_guard': [col_lo, col_hi],
        'fixed_capture': {'row_lo': row_lo, 'row_hi': row_hi, 'beat_lo': beat_lo, 'beat_hi': beat_hi,
                          'pixel_columns_inclusive': [beat_lo * 16, beat_hi * 16 + 15],
                          'beats_per_camera_frame': beats},
        'capture_write_budget': {'six_cameras_at_30fps_beats_per_second': beats * 6 * 30,
                                 'six_full_frames_at_30fps_beats_per_second': 120 * 1080 * 6 * 30,
                                 'historical_measured_write_beats_per_second': 22300000,
                                 'remaining_against_historical_write_rate': 22300000 - beats * 6 * 30,
                                 'limitation': 'Historical empirical write-path rate only; does not prove new whole-system DDR throughput, timing, frame rate, or burst-pressure margins.'},
        'source_bank_layout': {'frame_stride_app_addresses': 1036800,
                               'maximum_full_frame_beat_start_offset': 1036792,
                               'camera_stride_app_addresses': 4147208,
                               'banks_per_camera': 4,
                               'conclusion': 'Existing allocation already reserves complete 1920x1080 frames. Fixed window changes no bank stride/address or stagger.'}
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report['fixed_capture']))
    print(json.dumps(report['capture_write_budget']))
    print('PASS fixed EO capture envelope:', args.output)


if __name__ == '__main__':
    main()
